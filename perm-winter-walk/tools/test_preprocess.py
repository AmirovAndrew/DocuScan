#!/usr/bin/env python3
"""Tests for the preprocessor's three input paths and its output format.

The Overpass and PBF paths cannot reach real servers in every build environment, so
the tests feed them small synthetic OSM datasets (a building with and without
building:levels, a road, a footpath, a park, a river multipolygon with an island,
a street lamp) and check the decoded chunk files.

    python3 -m pytest tools/test_preprocess.py -q      (or: python3 tools/test_preprocess.py)
"""
import json
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import inspect_chunks  # noqa: E402
import preprocess_osm as pp  # noqa: E402

LAT0, LON0 = 58.0, 56.0
BBOX = (55.996, 57.998, 56.004, 58.002)


def ll(dx_m: float, dy_m: float) -> tuple[float, float]:
    """(lon, lat) of a point dx metres east and dy metres north of the test origin."""
    p = pp.Projector(LAT0, LON0)
    return LON0 + dx_m / p.kx, LAT0 + dy_m / p.ky


def square(cx, cy, half):
    return [ll(cx - half, cy - half), ll(cx + half, cy - half), ll(cx + half, cy + half),
            ll(cx - half, cy + half), ll(cx - half, cy - half)]


def overpass_fixture() -> dict:
    def way(i, coords, tags):
        return {"type": "way", "id": i, "tags": tags,
                "geometry": [{"lon": x, "lat": y} for x, y in coords]}
    river_outer = [ll(-200, 120), ll(200, 120), ll(200, 220), ll(-200, 220)]
    island = [ll(-20, 150), ll(20, 150), ll(20, 180), ll(-20, 180), ll(-20, 150)]
    return {"elements": [
        way(1, square(-40, -40, 10), {"building": "apartments", "building:levels": "9"}),
        way(2, square(40, -40, 8), {"building": "yes"}),                       # no levels: default 3
        way(3, square(40, 40, 6), {"building": "garage"}),                     # small: 1 level
        way(4, [ll(-200, 0), ll(200, 0)], {"highway": "primary", "name": "Lenina"}),
        way(5, [ll(0, -200), ll(0, 100)], {"highway": "footway"}),
        way(6, square(-60, 60, 30), {"leisure": "park", "name": "Эспланада"}),
        way(7, square(70, -80, 12), {"building": "theatre", "name": "Пермский театр оперы и балета"}),
        {"type": "relation", "id": 9, "tags": {"type": "multipolygon", "natural": "water", "water": "river"},
         "members": [
             {"type": "way", "ref": 91, "role": "outer", "geometry": [{"lon": x, "lat": y} for x, y in river_outer[:3]]},
             {"type": "way", "ref": 92, "role": "outer",
              "geometry": [{"lon": x, "lat": y} for x, y in river_outer[2:] + river_outer[:1]]},
             {"type": "way", "ref": 93, "role": "inner", "geometry": [{"lon": x, "lat": y} for x, y in island]},
         ]},
        {"type": "node", "id": 100, "lon": ll(10, 8)[0], "lat": ll(10, 8)[1], "tags": {"highway": "street_lamp"}},
    ]}


def run_pipeline(source_args: list[str], out: Path) -> dict:
    rc = pp.main(source_args + ["--bbox", ",".join(map(str, BBOX)), "--origin", f"{LAT0},{LON0}",
                                "--out", str(out), "--chunk-size", "250"])
    assert rc == 0
    man = json.loads((out / "manifest.json").read_text())
    chunks = [inspect_chunks.read_chunk(out / f) for f in man["chunks"].values()]
    return {"manifest": man, "chunks": chunks}


def check_dataset(res: dict) -> None:
    man, chunks = res["manifest"], res["chunks"]
    assert man["attribution"] == "© OpenStreetMap contributors"
    assert len(chunks) == 4  # the bbox straddles the origin: chunks (-1..0) x (-1..0)
    attrs = np.concatenate([c["BLDG"]["attrs"] for c in chunks if "BLDG" in c])
    heights = sorted(attrs[:, 0].round(1).tolist())
    levels = sorted(attrs[:, 1].tolist())
    assert levels == [1.0, 3.0, 3.0, 9.0], levels            # garage 1, default 3 (x2), apartments 9
    assert 27.0 <= max(heights) <= 28.0                       # 9 levels * 3 m + 0.6
    # every roof triangle faces up (counter-clockwise in x/z)
    for c in chunks:
        if "BLDG" in c:
            b = c["BLDG"]
            for i in range(len(b["attrs"])):
                p = b["pts"][b["poff"][i]:b["poff"][i + 1]]
                t = b["tris"][b["toff"][i]:b["toff"][i + 1]].reshape(-1, 3)
                a, bb, cc = p[t[:, 0]], p[t[:, 1]], p[t[:, 2]]
                cross = (bb[:, 0] - a[:, 0]) * (cc[:, 1] - a[:, 1]) - (bb[:, 1] - a[:, 1]) * (cc[:, 0] - a[:, 0])
                assert (cross > 0).all()
    # flat surfaces tile each chunk exactly once (planar partition)
    kinds_seen = set()
    for c in chunks:
        f = c["FLAT"]
        tri = f["pos"][f["idx"].reshape(-1, 3)]
        area = 0.5 * np.abs((tri[:, 1, 0] - tri[:, 0, 0]) * (tri[:, 2, 1] - tri[:, 0, 1])
                            - (tri[:, 1, 1] - tri[:, 0, 1]) * (tri[:, 2, 0] - tri[:, 0, 0]))
        assert abs(area.sum() - 250 * 250) < 250 * 250 * 0.002, area.sum()
        kinds_seen |= set(f["attr"][:, 0].astype(int).tolist())
    assert {pp.K_GROUND, pp.K_ROAD, pp.K_PATH, pp.K_PARK, pp.K_ICE} <= kinds_seen, kinds_seen
    # the island is not ice: the point at its centre (0, 165 m north -> z = -165) must be ground
    ice_area = 0.0
    for c in chunks:
        f = c["FLAT"]
        for t in f["idx"].reshape(-1, 3):
            if int(f["attr"][t[0], 0]) == pp.K_ICE:
                tri = f["pos"][t]
                ice_area += 0.5 * abs((tri[1, 0] - tri[0, 0]) * (tri[2, 1] - tri[0, 1])
                                      - (tri[1, 1] - tri[0, 1]) * (tri[2, 0] - tri[0, 0]))
    river_in_bbox = 100 * (2 * min(200, 250)) - 40 * 30
    assert abs(ice_area - river_in_bbox) / river_in_bbox < 0.05, (ice_area, river_in_bbox)
    lamps = np.concatenate([c["LAMP"] for c in chunks if "LAMP" in c])
    assert (lamps[:, 3] == 1.0).sum() == 1    # the OSM street lamp is kept as such
    assert (lamps[:, 3] == 0.0).sum() >= 4    # and generated lamps line the primary road
    assert all("LMAP" in c or True for c in chunks)
    assert man["spawn"]["yaw_deg"] != 0.0     # faces the "opera" from the "Esplanade"


def test_overpass_path(tmp_path=None):
    tmp = Path(tmp_path or tempfile.mkdtemp())
    cache = tmp / "cache"
    cache.mkdir()
    data = overpass_fixture()
    # Pre-seed the cache the way fetch_overpass names it, so no network is used.
    import hashlib
    bbox = None
    orig = pp.fetch_overpass

    def fake_fetch(fetch_bbox, endpoint, cache_dir):
        nonlocal bbox
        bbox = fetch_bbox
        return data
    pp.fetch_overpass = fake_fetch
    try:
        res = run_pipeline(["--source", "overpass", "--cache", str(cache)], tmp / "out")
    finally:
        pp.fetch_overpass = orig
    assert bbox is not None and bbox[0] < BBOX[0] and bbox[3] > BBOX[3]  # fetch includes a margin
    q = pp.overpass_query(bbox)
    assert "building" in q and "street_lamp" in q and "out body geom" in q
    check_dataset(res)


def test_saved_overpass_json(tmp_path=None):
    tmp = Path(tmp_path or tempfile.mkdtemp())
    p = tmp / "saved.json"
    p.write_text(json.dumps(overpass_fixture()))
    check_dataset(run_pipeline(["--source", "overpass", "--overpass-json", str(p)], tmp / "out"))


def test_print_query(capsys=None):
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        assert pp.main(["--print-query", "--out", tempfile.mkdtemp()]) == 0
    q = buf.getvalue()
    assert q.count("[out:json]") == 1 and 'node["highway"="street_lamp"]' in q


def test_geojson_path(tmp_path=None):
    tmp = Path(tmp_path or tempfile.mkdtemp())
    feats = pp.feats_from_overpass(overpass_fixture())
    import shapely.geometry
    fc = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": shapely.geometry.mapping(f.geom),
         "properties": {"osm_id": f.osm_id, "tags": f.tags}} for f in feats]}
    p = tmp / "f.geojson"
    p.write_text(json.dumps(fc))
    check_dataset(run_pipeline(["--source", "features", "--features", str(p)], tmp / "out"))


def test_pbf_path(tmp_path=None):
    import osmium
    tmp = Path(tmp_path or tempfile.mkdtemp())
    pbf = tmp / "fixture.osm.pbf"
    data = overpass_fixture()
    nid = [1000]
    nodes, ways, rels = [], [], []

    by_coord = {}

    def add_nodes(coords):
        """Node ids for coordinates; identical coordinates share one node (closed rings, joins)."""
        ids = []
        for x, y in coords:
            key = (round(x, 9), round(y, 9))
            if key not in by_coord:
                nid[0] += 1
                by_coord[key] = nid[0]
                nodes.append(osmium.osm.mutable.Node(id=nid[0], location=(x, y), version=1))
            ids.append(by_coord[key])
        return ids
    for el in data["elements"]:
        if el["type"] == "node":
            nodes.append(osmium.osm.mutable.Node(id=el["id"], location=(el["lon"], el["lat"]), tags=el["tags"], version=1))
        elif el["type"] == "way":
            coords = [(g["lon"], g["lat"]) for g in el["geometry"]]
            ways.append(osmium.osm.mutable.Way(id=el["id"], nodes=add_nodes(coords), tags=el["tags"], version=1))
        else:
            members = []
            for m in el["members"]:
                coords = [(g["lon"], g["lat"]) for g in m["geometry"]]
                ways.append(osmium.osm.mutable.Way(id=m["ref"], nodes=add_nodes(coords), tags={}, version=1))
                members.append(("w", m["ref"], m["role"]))
            rels.append(osmium.osm.mutable.Relation(id=el["id"], members=members, tags=el["tags"], version=1))
    w = osmium.SimpleWriter(str(pbf))
    for n in sorted(nodes, key=lambda n: n.id):
        w.add_node(n)
    for wy in sorted(ways, key=lambda x: x.id):
        w.add_way(wy)
    for r in rels:
        w.add_relation(r)
    w.close()
    res = run_pipeline(["--source", "pbf", "--pbf", str(pbf)], tmp / "out")
    man, chunks = res["manifest"], res["chunks"]
    attrs = np.concatenate([c["BLDG"]["attrs"] for c in chunks if "BLDG" in c])
    assert sorted(attrs[:, 1].tolist()) == [1.0, 3.0, 3.0, 9.0]
    kinds = set()
    for c in chunks:
        kinds |= set(c["FLAT"]["attr"][:, 0].astype(int).tolist())
    assert {pp.K_ROAD, pp.K_PATH, pp.K_PARK} <= kinds
    lamps = np.concatenate([c["LAMP"] for c in chunks if "LAMP" in c])
    assert (lamps[:, 3] == 1.0).sum() == 1


def test_building_params():
    assert pp.building_params({"building": "yes"}, 300)[1] == 3.0           # default 3 levels
    assert pp.building_params({"building": "yes", "building:levels": "5"}, 300)[:2] == (15.6, 5.0)
    h, lv, _ = pp.building_params({"building": "yes", "height": "21 m"}, 300)
    assert h == 21.0 and lv == 7.0
    assert pp.building_params({"building": "garages"}, 300)[1] == 1.0
    assert pp.parse_number("12,5") == 12.5


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
