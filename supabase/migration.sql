-- =====================================================================
-- Campus Bathroom Rater — schema, RLS, storage, seed
-- Paste into the Supabase SQL editor and run once.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables
create table if not exists public.schools (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  name         text not null,
  email_domain text not null default 'purdue.edu',
  created_at   timestamptz not null default now()
);

create table if not exists public.buildings (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  code       text not null,
  name       text not null,
  created_at timestamptz not null default now(),
  unique (school_id, code)
);

create table if not exists public.floors (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  building_id uuid not null references public.buildings(id) on delete cascade,
  name        text not null,
  sort_order  integer not null default 0,     -- 0 = bottom floor
  created_at  timestamptz not null default now(),
  unique (building_id, sort_order)
);

create table if not exists public.bathrooms (
  id                uuid primary key default gen_random_uuid(),
  school_id         uuid not null references public.schools(id) on delete cascade,
  building_id       uuid not null references public.buildings(id) on delete cascade,
  floor_id          uuid not null references public.floors(id) on delete cascade,
  label             text not null check (char_length(label) between 1 and 60),
  note              text check (char_length(note) <= 300),
  photo_url         text,
  submitted_by_hash text check (submitted_by_hash is null or submitted_by_hash ~ '^[0-9a-f]{64}$'),
  status            text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at        timestamptz not null default now(),
  unique (floor_id, label)
);

create table if not exists public.votes (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  bathroom_id uuid not null references public.bathrooms(id) on delete cascade,
  voter_hash  text not null check (voter_hash ~ '^[0-9a-f]{64}$'),   -- sha256 hex of the email
  period      text not null default to_char(now(), 'YYYY-MM'),      -- server clock, never the client
  cleanliness smallint not null check (cleanliness between 1 and 5),
  privacy     smallint not null check (privacy     between 1 and 5),
  smell       smallint not null check (smell       between 1 and 5),
  vibes       smallint not null check (vibes       between 1 and 5),
  review_text text check (review_text is null or char_length(review_text) <= 500),
  photo_url   text,
  created_at  timestamptz not null default now()
);

-- one vote per bathroom per voter per calendar month
create unique index if not exists votes_one_per_month on public.votes (bathroom_id, voter_hash, period);
create index if not exists votes_school_period_idx on public.votes (school_id, period);
create index if not exists votes_bathroom_idx      on public.votes (bathroom_id, created_at desc);
create index if not exists bathrooms_school_status_idx on public.bathrooms (school_id, status);
create index if not exists floors_building_idx     on public.floors (building_id);

-- ---------------------------------------------------------------- triggers
-- Never trust client-supplied period / school_id on a vote.
create or replace function public.votes_before_insert()
returns trigger language plpgsql as $$
declare target record;
begin
  select school_id, status into target from public.bathrooms where id = new.bathroom_id;
  if target is null or target.status <> 'approved' then
    raise exception 'bathroom not found or not approved' using errcode = '23503';
  end if;
  new.school_id   := target.school_id;
  new.period      := to_char(now(), 'YYYY-MM');
  new.review_text := nullif(btrim(new.review_text), '');
  return new;
end $$;
drop trigger if exists votes_before_insert on public.votes;
create trigger votes_before_insert before insert on public.votes
  for each row execute function public.votes_before_insert();

-- Keep school_id consistent with the building; make sure the floor belongs to it.
create or replace function public.bathrooms_before_insert()
returns trigger language plpgsql as $$
declare b_school uuid; f_building uuid;
begin
  select school_id into b_school from public.buildings where id = new.building_id;
  select building_id into f_building from public.floors where id = new.floor_id;
  if b_school is null or f_building is distinct from new.building_id then
    raise exception 'floor does not belong to building' using errcode = '23503';
  end if;
  new.school_id := b_school;
  new.label     := btrim(new.label);
  new.note      := nullif(btrim(new.note), '');
  return new;
end $$;
drop trigger if exists bathrooms_before_insert on public.bathrooms;
create trigger bathrooms_before_insert before insert on public.bathrooms
  for each row execute function public.bathrooms_before_insert();

-- ---------------------------------------------------------------- row level security
alter table public.schools   enable row level security;
alter table public.buildings enable row level security;
alter table public.floors    enable row level security;
alter table public.bathrooms enable row level security;
alter table public.votes     enable row level security;

-- No update/delete policies exist for anon anywhere, so anon can't change or remove rows.
drop policy if exists "anon read schools"            on public.schools;
drop policy if exists "anon read buildings"          on public.buildings;
drop policy if exists "anon read floors"             on public.floors;
drop policy if exists "anon read approved bathrooms" on public.bathrooms;
drop policy if exists "anon submit pending bathroom" on public.bathrooms;
drop policy if exists "anon read votes"              on public.votes;
drop policy if exists "anon insert votes"            on public.votes;

create policy "anon read schools"            on public.schools   for select to anon using (true);
create policy "anon read buildings"          on public.buildings for select to anon using (true);
create policy "anon read floors"             on public.floors    for select to anon using (true);
create policy "anon read approved bathrooms" on public.bathrooms for select to anon using (status = 'approved');
create policy "anon submit pending bathroom" on public.bathrooms for insert to anon with check (status = 'pending');
create policy "anon read votes"              on public.votes     for select to anon using (true);
create policy "anon insert votes"            on public.votes     for insert to anon with check (true);

-- ---------------------------------------------------------------- storage
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bathroom-photos', 'bathroom-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true;

drop policy if exists "public read bathroom photos" on storage.objects;
drop policy if exists "anon upload bathroom photos" on storage.objects;
create policy "public read bathroom photos" on storage.objects for select to anon, authenticated using (bucket_id = 'bathroom-photos');
create policy "anon upload bathroom photos" on storage.objects for insert to anon with check (bucket_id = 'bathroom-photos');
-- (Host the campus map image in this bucket too; public read covers it.)

-- ---------------------------------------------------------------- seed: Purdue
insert into public.schools (slug, name, email_domain)
values ('purdue', 'Purdue University', 'purdue.edu')
on conflict (slug) do update set name = excluded.name, email_domain = excluded.email_domain;

do $$
declare
  sid   uuid;
  bid   uuid;
  fid   uuid;
  i     int;
  j     int;
  k     int;
  nfl   int;
  fname text;
  labels text[];
  -- code, name, floor count. Counts marked VERIFY in CONFIG are placeholders;
  -- fix them here or in the dashboard.
  specs text[][] := array[
    ['WALC', 'Wilmeth Active Learning Center',                '5'],
    ['PMU',  'Purdue Memorial Union',                         '4'],
    ['DSCB', 'Hall of Data Science and AI',                   '4'],
    ['PHYS', 'Physics Building',                              '4'],
    ['CL50', 'Class of 1950 Lecture Hall',                    '2'],
    ['BRNG', 'Beering Hall of Liberal Arts and Education',    '7'],
    ['MATH', 'Mathematical Sciences Building',                '9'],
    ['CHAS', 'Chaney-Hale Hall of Science',                   '3'],
    ['HIKS', 'Hicks Undergraduate Library',                   '2'],
    ['LWSN', 'Lawson Computer Science Building',              '3']
  ];
  pmu_floors text[] := array['Basement', 'Ground Floor', 'First Floor', 'Second Floor'];
begin
  select id into sid from public.schools where slug = 'purdue';

  for i in 1 .. array_length(specs, 1) loop
    insert into public.buildings (school_id, code, name)
    values (sid, specs[i][1], specs[i][2])
    on conflict (school_id, code) do update set name = excluded.name
    returning id into bid;

    nfl := specs[i][3]::int;

    for j in 1 .. nfl loop
      if specs[i][1] = 'PMU' then
        fname := pmu_floors[j];
        -- from the Union's wayfinding plans: basement has no gender-neutral room
        labels := case when j = 1 then array['Men''s', 'Women''s'] else array['Men''s', 'Women''s', 'Gender Neutral'] end;
      else
        fname := 'Floor ' || j;
        labels := array['Men''s', 'Women''s'];   -- placeholders until real data comes in
      end if;

      insert into public.floors (school_id, building_id, name, sort_order)
      values (sid, bid, fname, j - 1)
      on conflict (building_id, sort_order) do update set name = excluded.name
      returning id into fid;

      for k in 1 .. array_length(labels, 1) loop
        insert into public.bathrooms (school_id, building_id, floor_id, label, status)
        values (sid, bid, fid, labels[k], 'approved')
        on conflict (floor_id, label) do nothing;
      end loop;
    end loop;
  end loop;
end $$;
