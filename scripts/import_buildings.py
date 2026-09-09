#!/usr/bin/env python3
"""Import Purdue campus buildings from OpenStreetMap onto the campus map image.

OSM gives us building names, codes and lat/lon. The app places pins as a
percentage of the map image, and that map is an illustrated plan rather than a
true projection -- so we fit an affine transform from lat/lon to image pixels
using buildings whose position on the image was verified by hand, then apply it
to everything else.

Outputs:
  assets/buildings.json        consumed by the app at boot (and by the seed)
  supabase/seed-buildings.sql  idempotent upsert into public.buildings

Usage:
  python3 scripts/import_buildings.py            # query Overpass
  python3 scripts/import_buildings.py --cache q.json   # reuse a saved response
"""
import argparse, json, pathlib, re, sys, urllib.parse, urllib.request

import numpy as np

# Campus bounding box (south, west, north, east).
BBOX = (40.417, -86.930, 40.436, -86.900)
OVERPASS = "https://overpass-api.de/api/interpreter"
QUERY = f'[out:json][timeout:60];(way["building"]["name"]{BBOX};);out center tags;'

MAP_W, MAP_H = 950, 1200          # assets/campus-map.png

# Buildings whose pin was placed by reading the map image directly, in image
# pixels. These train the transform and always win over a computed position.
ANCHORS = {
    "WALC": (700, 580), "DSCB": (647, 516), "PHYS": (684, 463), "CL50": (640, 624),
    "BRNG": (604, 658), "MATH": (620, 629), "CHAS": (625, 528), "LWSN": (581, 562),
}
# Positioned by hand but deliberately kept out of the fit: Hicks is underground
# and unlabelled on the map, and PMU/DSCB are not tagged with a code in OSM.
MANUAL = {"HIKS": (696, 673), "PMU": (757, 677), "DSCB": (647, 516)}

# Names for buildings OSM has no coded entry for, so a hand-placed pin still
# gets a real label.
FALLBACK_NAMES = {
    "HIKS": "Hicks Undergraduate Library",
    "PMU":  "Purdue Memorial Union",
    "DSCB": "Hall of Data Science and AI",
}

ROOT = pathlib.Path(__file__).resolve().parent.parent


def fetch(cache=None):
    if cache and pathlib.Path(cache).exists():
        return json.loads(pathlib.Path(cache).read_text())
    body = urllib.parse.urlencode({"data": QUERY}).encode()
    with urllib.request.urlopen(urllib.request.Request(OVERPASS, data=body), timeout=90) as r:
        data = json.loads(r.read())
    if cache:
        pathlib.Path(cache).write_text(json.dumps(data))
    return data


def extract(data):
    """-> {CODE: {code, name, lat, lon, levels}}, preferring the larger footprint."""
    out = {}
    for el in data.get("elements", []):
        tags, centre = el.get("tags", {}), el.get("center")
        name = tags.get("name")
        if not name or not centre:
            continue
        m = re.search(r"\((\w{2,6})\)\s*$", name)
        code = (tags.get("ref") or (m.group(1) if m else "")).upper().strip()
        if not re.fullmatch(r"[A-Z0-9]{2,6}", code):
            continue
        levels = tags.get("building:levels")
        out.setdefault(code, {
            "code": code,
            "name": re.sub(r"\s*\(\w{2,6}\)\s*$", "", name).strip(),
            "lat": centre["lat"], "lon": centre["lon"],
            "levels": int(levels) if levels and levels.isdigit() else None,
        })
    return out


def fit_affine(buildings):
    """Least-squares lat/lon -> image px, trained on ANCHORS. Reports LOO error."""
    codes = sorted(c for c in ANCHORS if c in buildings)
    if len(codes) < 4:
        sys.exit(f"only {len(codes)} anchors found in OSM data; need 4+")
    L = np.array([[buildings[c]["lon"], buildings[c]["lat"], 1.0] for c in codes])
    P = np.array([ANCHORS[c] for c in codes], float)
    errs = []
    for i in range(len(codes)):
        keep = [j for j in range(len(codes)) if j != i]
        M, *_ = np.linalg.lstsq(L[keep], P[keep], rcond=None)
        errs.append(float(np.linalg.norm(L[i] @ M - P[i])))
    M, *_ = np.linalg.lstsq(L, P, rcond=None)
    return M, codes, errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", help="path to a saved Overpass response")
    args = ap.parse_args()

    buildings = extract(fetch(args.cache))
    print(f"OSM: {len(buildings)} buildings with a usable code")

    M, anchor_codes, errs = fit_affine(buildings)
    print(f"transform trained on {len(anchor_codes)} anchors — "
          f"leave-one-out median {np.median(errs):.1f}px, max {max(errs):.1f}px "
          f"(map is {MAP_W}x{MAP_H})")

    rows, off_map = [], 0
    for code, b in sorted(buildings.items()):
        if code in ANCHORS:
            px, py = ANCHORS[code]; source = "verified"
        elif code in MANUAL:
            px, py = MANUAL[code]; source = "manual"
        else:
            px, py = np.array([b["lon"], b["lat"], 1.0]) @ M; source = "computed"
        x, y = px / MAP_W * 100, py / MAP_H * 100
        if not (0 <= x <= 100 and 0 <= y <= 100):
            off_map += 1
            continue
        rows.append({"code": code, "name": b["name"], "x": round(x, 2), "y": round(y, 2),
                     "lat": b["lat"], "lon": b["lon"], "levels": b["levels"], "source": source})
    # Hand-placed buildings that OSM had no coded entry for.
    for code, (px, py) in MANUAL.items():
        if not any(r["code"] == code for r in rows):
            rows.append({"code": code, "name": FALLBACK_NAMES.get(code, code),
                         "x": round(px / MAP_W * 100, 2), "y": round(py / MAP_H * 100, 2),
                         "lat": None, "lon": None, "levels": None, "source": "manual"})
    rows.sort(key=lambda r: r["code"])

    print(f"placed {len(rows)} buildings ({off_map} fell outside the map image)")

    (ROOT / "assets/buildings.json").write_text(json.dumps(rows, indent=2) + "\n")

    def sql(v):
        return "null" if v is None else "'" + str(v).replace("'", "''") + "'"
    values = ",\n  ".join(
        f"({sql(r['code'])}, {sql(r['name'])}, {r['x']}, {r['y']}, "
        f"{r['lat'] if r['lat'] is not None else 'null'}, "
        f"{r['lon'] if r['lon'] is not None else 'null'})" for r in rows)
    (ROOT / "supabase/seed-buildings.sql").write_text(f"""\
-- Generated by scripts/import_buildings.py -- do not edit by hand.
-- Building data (c) OpenStreetMap contributors, ODbL.
-- Requires the x/y/lat/lon columns from migration.sql.
insert into public.buildings (school_id, code, name, x, y, lat, lon)
select s.id, v.code, v.name, v.x, v.y, v.lat, v.lon
from public.schools s
cross join (values
  {values}
) as v(code, name, x, y, lat, lon)
where s.slug = 'purdue'
on conflict (school_id, code) do update
  set name = excluded.name, x = excluded.x, y = excluded.y,
      lat = excluded.lat, lon = excluded.lon;
""")
    print("wrote assets/buildings.json and supabase/seed-buildings.sql")


if __name__ == "__main__":
    main()
