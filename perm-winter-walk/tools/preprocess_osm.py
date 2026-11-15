#!/usr/bin/env python3
"""Turn OpenStreetMap data into compact, chunked map files for the Godot game.

SOURCES (all OpenStreetMap, ODbL - (c) OpenStreetMap contributors)
  --source overpass   (default) query the Overpass API for the bbox
  --source pbf        read a local .osm.pbf extract (e.g. from Geofabrik); see README
  --source features   read a GeoJSON FeatureCollection whose properties are
                      {"osm_id": ..., "tags": {...OSM tags...}} (fetch_overture_osm.py writes this)

EXAMPLES
  python3 tools/preprocess_osm.py --out game/data/perm
  python3 tools/preprocess_osm.py --source pbf --pbf tools/cache/perm.osm.pbf --out game/data/perm
  # add another area later; chunks share the existing origin and grid:
  python3 tools/preprocess_osm.py --bbox 56.250,58.005,56.290,58.022 --merge --out game/data/perm

OUTPUT (see game/data/FORMAT.md)
  manifest.json        origin, chunk grid, spawn point, landmarks, attribution
  chunk_<cx>_<cz>.bin  one file per 250 m x 250 m chunk (buildings, flat surfaces, road
                       decals, snow banks, lamps, trees), little-endian, 4-byte aligned

Coordinates in the files are Godot world metres: x = east, z = south (z = -north),
relative to the dataset origin, using a local equirectangular projection (error well
under 0.1 % across a city).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
import time
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import mapbox_earcut as earcut
import numpy as np
import shapely
from shapely import STRtree
from shapely.geometry import LineString, MultiLineString, MultiPolygon, Point, Polygon, box, shape
from shapely.geometry.polygon import orient
from shapely.ops import linemerge, polygonize, unary_union
from shapely.prepared import prep

# Esplanade (west) .. Opera and Ballet Theatre (east), up to the Kama bank (north).
DEFAULT_BBOX = (56.2120, 58.0050, 56.2500, 58.0215)  # min_lon, min_lat, max_lon, max_lat
CHUNK_SIZE = 250.0
FLOOR_HEIGHT = 3.0
DEFAULT_LEVELS = 3          # the brief: building:levels, default 3 when missing
FETCH_MARGIN_M = 120.0      # fetch a little beyond the chunks so edge features are complete
EARTH_R = 6371008.8
FORMAT_VERSION = 1

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

# Carriageway widths in metres when the way has no width / lanes tag.
ROAD_WIDTH = {
    "motorway": 14, "trunk": 13, "primary": 12, "secondary": 10, "tertiary": 8.5,
    "unclassified": 6.5, "residential": 6.5, "living_street": 5.5, "service": 4.5,
    "road": 6, "busway": 7, "motorway_link": 6, "trunk_link": 6, "primary_link": 6,
    "secondary_link": 6, "tertiary_link": 6, "track": 3.5,
}
PATH_WIDTH = {"footway": 2.4, "path": 1.6, "cycleway": 2.2, "steps": 2.6, "bridleway": 2.0,
              "pedestrian": 7.0, "corridor": 2.0}
MAJOR_ROADS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
               "residential", "busway", "primary_link", "secondary_link", "tertiary_link", "trunk_link"}

# Flat surface kinds (must match snow_surface.gdshader).
K_GROUND, K_PARK, K_SQUARE, K_ROAD, K_PATH, K_ICE, K_PAVED = range(7)

# Building kinds (must match city_builder.gd / facade.gdshader).
B_RESIDENTIAL, B_COMMERCIAL, B_PUBLIC, B_UTILITY, B_RELIGIOUS = range(5)
SMALL_STRUCTURES = {"garage", "garages", "shed", "kiosk", "hut", "shelter", "service", "carport",
                    "transformer_tower", "toilets", "cabin", "booth", "container", "bunker", "gatehouse"}
BUILDING_KIND = {
    **{k: B_RESIDENTIAL for k in ("apartments", "residential", "house", "detached", "dormitory",
                                  "terrace", "semidetached_house", "yes")},
    **{k: B_COMMERCIAL for k in ("commercial", "retail", "office", "hotel", "supermarket", "mall")},
    **{k: B_PUBLIC for k in ("public", "government", "civic", "school", "university", "college",
                             "kindergarten", "hospital", "theatre", "museum", "train_station",
                             "transportation", "library", "sports_hall", "stadium", "bank", "courthouse")},
    **{k: B_UTILITY for k in ("industrial", "warehouse", "construction", "manufacture", "storage_tank",
                              "parking", "ruins", "greenhouse", "boathouse") + tuple(SMALL_STRUCTURES)},
    **{k: B_RELIGIOUS for k in ("church", "cathedral", "chapel", "mosque", "synagogue", "temple",
                                "religious", "monastery", "shrine")},
}
SKIP_BUILDINGS = {"no", "roof", "canopy", "bridge", "ruins:no"}
LANDMARK_NAMES = ("театр оперы", "opera", "театр-театр", "законодательное собрание", "собор")


@dataclass
class Feat:
    kind: str
    geom: object  # shapely geometry, lon/lat until projected
    tags: dict
    osm_id: str
    extra: dict = field(default_factory=dict)


# ----------------------------------------------------------------------------- utils
def parse_number(v) -> float | None:
    if v is None:
        return None
    s = str(v).strip().replace(",", ".").split(";")[0]
    num = ""
    for ch in s:
        if ch.isdigit() or ch in ".-" and not num.endswith("."):
            num += ch
        elif num:
            break
    try:
        val = float(num)
    except ValueError:
        return None
    if "'" in s or "ft" in s:
        val *= 0.3048
    return val


def seed_of(osm_id: str) -> float:
    return (zlib.crc32(str(osm_id).encode()) & 0xFFFFFF) / float(0xFFFFFF)


def is_area_tags(tags: dict) -> bool:
    if tags.get("area") == "no":
        return False
    if tags.get("area") == "yes":
        return True
    return any(k in tags for k in ("building", "landuse", "leisure", "amenity", "place", "area:highway",
                                   "water")) or tags.get("natural") in (
        "water", "wood", "scrub", "grassland", "heath", "wetland") or tags.get("waterway") == "riverbank"


def classify(tags: dict, geom) -> str | None:
    gt = geom.geom_type
    poly = gt in ("Polygon", "MultiPolygon")
    line = gt in ("LineString", "MultiLineString")
    pt = gt == "Point"
    hw = tags.get("highway")
    if pt:
        if hw == "street_lamp":
            return "lamp"
        if tags.get("natural") == "tree":
            return "tree"
        return None
    b = tags.get("building")
    if poly and b and b not in SKIP_BUILDINGS and tags.get("location") != "underground":
        return "building"
    if line and hw:
        if tags.get("tunnel") in ("yes", "culvert") or str(tags.get("layer", "0")).startswith("-"):
            return None
        if tags.get("area") == "yes":
            return None
        if hw in ROAD_WIDTH:
            return "road"
        if hw in PATH_WIDTH:
            return "path"
        return None
    if not poly:
        return None
    if tags.get("natural") == "water" or tags.get("waterway") == "riverbank" or "water" in tags \
            or tags.get("landuse") in ("reservoir", "basin"):
        return "water"
    if hw in ("pedestrian", "footway") or tags.get("place") == "square" or "area:highway" in tags:
        return "square"
    if tags.get("amenity") == "parking" or tags.get("landuse") in ("railway",):
        return "paved"
    if tags.get("landuse") in ("forest",) or tags.get("natural") in ("wood", "scrub"):
        return "wood"
    if tags.get("leisure") in ("park", "garden", "playground", "pitch", "dog_park", "common") \
            or tags.get("landuse") in ("grass", "meadow", "recreation_ground", "village_green", "cemetery",
                                       "flowerbed", "allotments") or tags.get("natural") in ("grassland", "heath"):
        return "park"
    return None


# ----------------------------------------------------------------------------- sources
def overpass_query(bbox) -> str:
    s, w, n, e = bbox[1], bbox[0], bbox[3], bbox[2]
    bb = f"({s},{w},{n},{e})"
    return f"""[out:json][timeout:240];
(
  way["building"]{bb};
  relation["building"]["type"="multipolygon"]{bb};
  way["highway"]{bb};
  way["area:highway"]{bb};
  way["landuse"]{bb};
  relation["landuse"]["type"="multipolygon"]{bb};
  way["leisure"]{bb};
  relation["leisure"]["type"="multipolygon"]{bb};
  way["natural"~"^(water|wood|scrub|grassland|heath|wetland)$"]{bb};
  relation["natural"~"^(water|wood|scrub)$"]["type"="multipolygon"]{bb};
  way["waterway"="riverbank"]{bb};
  relation["waterway"="riverbank"]{bb};
  way["place"="square"]{bb};
  relation["place"="square"]{bb};
  way["amenity"="parking"]{bb};
  node["highway"="street_lamp"]{bb};
  node["natural"="tree"]{bb};
);
out body geom;
"""


def fetch_overpass(bbox, endpoint: str | None, cache_dir: Path) -> dict:
    import requests
    q = overpass_query(bbox)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache = cache_dir / f"overpass_{hashlib.sha1(q.encode()).hexdigest()[:12]}.json"
    if cache.exists():
        print("using cached Overpass response", cache)
        return json.loads(cache.read_text())
    endpoints = [endpoint] if endpoint else OVERPASS_ENDPOINTS
    last = None
    for ep in endpoints:
        try:
            print("querying", ep, "...")
            r = requests.post(ep, data={"data": q}, timeout=300,
                              headers={"User-Agent": "perm-winter-walk-preprocessor/1.0"})
            r.raise_for_status()
            data = r.json()
            cache.write_text(json.dumps(data))
            print(f"  {len(data.get('elements', []))} elements, cached in {cache}")
            return data
        except Exception as ex:  # noqa: BLE001 - try the next mirror
            print("  failed:", ex)
            last = ex
    raise SystemExit(
        f"Overpass is unreachable ({last}).\n"
        "Download an extract instead and use --source pbf (see README: 'Map data without Overpass').")


def _ring_polys(lines: list[LineString]) -> list[Polygon]:
    if not lines:
        return []
    noded = lines_of(unary_union(lines))  # splits at crossings, joins shared endpoints
    return [p for p in polygonize(noded) if p.is_valid and p.area > 0]


def assemble_multipolygon(members: list[dict]) -> MultiPolygon | Polygon | None:
    outers, inners = [], []
    for m in members:
        if m.get("type") != "way" or "geometry" not in m:
            continue
        pts = [(g["lon"], g["lat"]) for g in m["geometry"] if g]
        if len(pts) < 2:
            continue
        (inners if m.get("role") == "inner" else outers).append(LineString(pts))
    outer_polys = _ring_polys(outers)
    if not outer_polys:
        return None
    geom = unary_union(outer_polys)
    inner_polys = _ring_polys(inners)
    if inner_polys:
        geom = geom.difference(unary_union(inner_polys))
    return geom if not geom.is_empty else None


def feats_from_overpass(data: dict) -> list[Feat]:
    feats = []
    for el in data.get("elements", []):
        tags = el.get("tags", {})
        if not tags:
            continue
        t = el["type"]
        oid = f"{t[0]}{el['id']}"
        if t == "node":
            geom = Point(el["lon"], el["lat"])
        elif t == "way":
            pts = [(g["lon"], g["lat"]) for g in el.get("geometry", []) if g]
            if len(pts) < 2:
                continue
            closed = len(pts) >= 4 and pts[0] == pts[-1]
            if closed and is_area_tags(tags) and not (tags.get("highway") and tags.get("area") != "yes"
                                                      and "building" not in tags):
                geom = Polygon(pts)
                if not geom.is_valid:
                    geom = shapely.make_valid(geom)
            else:
                geom = LineString(pts)
        elif t == "relation":
            if tags.get("type") not in ("multipolygon", "boundary"):
                continue
            geom = assemble_multipolygon(el.get("members", []))
            if geom is None:
                continue
        else:
            continue
        kind = classify(tags, geom)
        if kind:
            feats.append(Feat(kind, geom, tags, oid))
    return feats


def feats_from_pbf(path: Path, bbox) -> list[Feat]:
    import osmium
    from shapely import wkb
    fab = osmium.geom.WKBFactory()
    env = box(*bbox).buffer(0.002)
    keys = ("building", "highway", "landuse", "leisure", "natural", "waterway", "place", "amenity",
            "area:highway", "water")
    fp = osmium.FileProcessor(str(path)).with_locations().with_areas() \
        .with_filter(osmium.filter.KeyFilter(*keys))
    feats = []
    n = 0
    for obj in fp:
        n += 1
        tags = {t.k: t.v for t in obj.tags}
        try:
            if obj.is_node():
                loc = obj.location
                if not loc.valid():
                    continue
                geom = Point(loc.lon, loc.lat)
                oid = f"n{obj.id}"
            elif obj.is_area():
                geom = wkb.loads(fab.create_multipolygon(obj), hex=True)
                if len(geom.geoms) == 1:
                    geom = geom.geoms[0]
                oid = f"{'w' if obj.from_way() else 'r'}{obj.orig_id()}"
            elif obj.is_way():
                closed = obj.is_closed()
                if closed and is_area_tags(tags) and not (tags.get("highway") and tags.get("area") != "yes"
                                                          and "building" not in tags):
                    continue  # handled as an area
                geom = wkb.loads(fab.create_linestring(obj), hex=True)
                oid = f"w{obj.id}"
            else:
                continue
        except Exception:  # noqa: BLE001 - broken geometry in the extract: skip it
            continue
        if not env.intersects(geom):
            continue
        kind = classify(tags, geom)
        if kind:
            feats.append(Feat(kind, geom, tags, oid))
    print(f"  read {n} tagged objects from {path.name}")
    return feats


def feats_from_geojson(path: Path) -> list[Feat]:
    fc = json.loads(Path(path).read_text())
    feats = []
    for f in fc["features"]:
        props = f.get("properties") or {}
        tags = props.get("tags") or {k: v for k, v in props.items() if isinstance(v, str)}
        geom = shape(f["geometry"])
        kind = classify(tags, geom)
        if kind:
            feats.append(Feat(kind, geom, tags, str(props.get("osm_id", props.get("id", "")))))
    meta = fc.get("metadata", {})
    if meta:
        print("  source:", meta.get("source", "?"))
    return feats


# ----------------------------------------------------------------------------- geometry
class Projector:
    """lon/lat <-> Godot metres (x east, z south) around an origin."""

    def __init__(self, lat0: float, lon0: float):
        self.lat0, self.lon0 = lat0, lon0
        self.kx = math.cos(math.radians(lat0)) * math.pi / 180.0 * EARTH_R
        self.ky = math.pi / 180.0 * EARTH_R

    def fwd(self, geom):
        def f(c):
            return np.column_stack(((c[:, 0] - self.lon0) * self.kx, -(c[:, 1] - self.lat0) * self.ky))
        return shapely.transform(geom, f)

    def xz(self, lon: float, lat: float) -> tuple[float, float]:
        return (lon - self.lon0) * self.kx, -(lat - self.lat0) * self.ky

    def lonlat(self, x: float, z: float) -> tuple[float, float]:
        return self.lon0 + x / self.kx, self.lat0 - z / self.ky


def polygons_of(geom) -> list[Polygon]:
    if geom is None or geom.is_empty:
        return []
    if geom.geom_type == "Polygon":
        return [geom]
    if hasattr(geom, "geoms"):
        out = []
        for g in geom.geoms:
            out.extend(polygons_of(g))
        return out
    return []


def lines_of(geom) -> list[LineString]:
    if geom is None or geom.is_empty:
        return []
    if geom.geom_type == "LineString":
        return [geom]
    if geom.geom_type == "LinearRing":
        return [LineString(geom.coords)]
    if hasattr(geom, "geoms"):
        out = []
        for g in geom.geoms:
            out.extend(lines_of(g))
        return out
    return []


def merge_lines(geom) -> list[LineString]:
    """linemerge() that also accepts a single line, an empty geometry or a collection."""
    lines = lines_of(geom)
    if len(lines) < 2:
        return lines
    return lines_of(linemerge(MultiLineString(lines)))


def triangulate(poly: Polygon) -> tuple[np.ndarray, np.ndarray]:
    """Earcut a polygon with holes -> (vertices Nx2, triangle indices)."""
    rings = [np.asarray(poly.exterior.coords)[:-1]] + [np.asarray(r.coords)[:-1] for r in poly.interiors]
    rings = [r for r in rings if len(r) >= 3]
    if not rings:
        return np.zeros((0, 2)), np.zeros(0, dtype=np.uint32)
    verts = np.concatenate(rings).astype(np.float64)
    ends = np.cumsum([len(r) for r in rings]).astype(np.uint32)
    idx = earcut.triangulate_float64(verts, ends)
    return verts, np.asarray(idx, dtype=np.uint32)


def road_width(tags: dict, kind: str) -> float:
    w = parse_number(tags.get("width"))
    if w and 1.0 <= w <= 40:
        return w
    hw = tags.get("highway", "")
    if kind == "road":
        lanes = parse_number(tags.get("lanes"))
        if lanes and 1 <= lanes <= 10:
            return max(lanes * 3.3, 4.0)
        if hw == "service" and tags.get("service") in ("parking_aisle", "driveway", "alley"):
            return 3.5
        return float(ROAD_WIDTH.get(hw, 6.0))
    return float(PATH_WIDTH.get(hw, 2.0))


def building_params(tags: dict, area_m2: float) -> tuple[float, float, int]:
    b = tags.get("building", "yes")
    kind = BUILDING_KIND.get(b, B_RESIDENTIAL)
    small = b in SMALL_STRUCTURES or (b == "yes" and area_m2 < 40)
    levels = parse_number(tags.get("building:levels"))
    height = parse_number(tags.get("height"))
    if levels is not None and not (0 < levels < 100):
        levels = None
    if height is not None and not (1.5 < height < 400):
        height = None
    if small and levels is None and height is None:
        levels = 1
        kind = B_UTILITY
    if levels is None:
        levels = round(height / FLOOR_HEIGHT) if height else DEFAULT_LEVELS
    levels = max(1, int(levels))
    if height is None:
        roof_levels = parse_number(tags.get("roof:levels")) or 0
        height = (levels + 0.5 * roof_levels) * FLOOR_HEIGHT + 0.6
    return float(height), float(levels), kind


# ----------------------------------------------------------------------------- chunks
class Writer:
    def __init__(self):
        self.sections = []

    def section(self, tag: bytes, payload: bytes):
        pad = (-len(payload)) % 4
        self.sections.append(struct.pack("<4sI", tag, len(payload) + pad) + payload + b"\0" * pad)

    def finish(self, cx: int, cz: int, size: float) -> bytes:
        head = struct.pack("<4sIiifI", b"PWC1", FORMAT_VERSION, cx, cz, size, len(self.sections))
        return head + b"".join(self.sections)


def f32(a) -> bytes:
    return np.asarray(a, dtype="<f4").tobytes()


def u32(a) -> bytes:
    return np.asarray(a, dtype="<u4").tobytes()


def fix_winding(verts, idx) -> np.ndarray:
    """Make every triangle face up (+Y) in Godot: counter-clockwise in (x, z) maths coordinates,
    which is clockwise on screen seen from above, Godot's front-face winding."""
    v = np.asarray(verts, dtype=np.float64).reshape(-1, 2)
    t = np.asarray(idx, dtype=np.int64).reshape(-1, 3).copy()
    if len(t) == 0:
        return t.reshape(-1).astype(np.uint32)
    a, b, c = v[t[:, 0]], v[t[:, 1]], v[t[:, 2]]
    cross = (b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0])
    flip = cross < 0
    t[flip, 1], t[flip, 2] = t[flip, 2].copy(), t[flip, 1].copy()
    return t.reshape(-1).astype(np.uint32)


def lit_ratio(kind: int, seed: float) -> float:
    """Share of windows lit at about 21:30 on a January evening."""
    r = (seed * 7.31) % 1.0  # decorrelated from the facade colour, which also uses the seed
    if kind == B_RESIDENTIAL:
        return 0.3 + 0.4 * r
    if kind == B_COMMERCIAL:
        return 0.12 + 0.3 * r
    if kind == B_PUBLIC:
        return 0.08 + 0.3 * r
    return 0.0


LMAP_RES = 128      # light map texels per chunk side (~2 m each)
LMAP_SCALE = 2.0    # stored value = sqrt(light / LMAP_SCALE); the shader squares and rescales
LAMP_STREET, LAMP_OSM, LAMP_PARK = 0.0, 1.0, 2.0


def lamp_head(l) -> tuple[float, float, float]:
    """Ground point under the luminaire and its mounting height."""
    x, z, yaw, typ = l
    if typ == LAMP_PARK:
        return x, z, 4.2
    return x - math.sin(yaw) * 1.4, z - math.cos(yaw) * 1.4, 7.0


def bake_light_map(cx: int, cz: int, size: float, lamps: list, buildings: list) -> bytes:
    """Warm light on the snow: lamp pools (cos^3 law) plus a faint spill from lit windows.

    Lamps and buildings from neighbouring chunks are included so pools continue across
    chunk borders. Returns PNG bytes (RGB, sqrt-encoded)."""
    import io
    from PIL import Image, ImageDraw
    from scipy import ndimage
    res = LMAP_RES
    texel = size / res
    x0, z0 = cx * size, cz * size
    xs = x0 + (np.arange(res) + 0.5) * texel
    zs = z0 + (np.arange(res) + 0.5) * texel
    acc = np.zeros((res, res, 3))
    warm = np.array([1.0, 0.66, 0.34])
    for lamp in lamps:
        hx, hz, h = lamp_head(lamp)
        r_max = 18.0 if h > 5 else 12.0
        ci0, ci1 = np.searchsorted(xs, hx - r_max), np.searchsorted(xs, hx + r_max)
        ri0, ri1 = np.searchsorted(zs, hz - r_max), np.searchsorted(zs, hz + r_max)
        if ci0 >= ci1 or ri0 >= ri1:
            continue
        X, Z = np.meshgrid(xs[ci0:ci1], zs[ri0:ri1])
        d2 = (X - hx) ** 2 + (Z - hz) ** 2
        e = h ** 3 / (h * h + d2) ** 1.5
        r = np.sqrt(d2)
        e *= np.clip((r_max - r) / (r_max * 0.3), 0.0, 1.0)
        acc[ri0:ri1, ci0:ci1] += e[..., None] * warm * (0.8 if lamp[3] == LAMP_PARK else 1.0)

    # Window spill at 1 m resolution, including buildings just outside the chunk.
    margin = 12
    n = int(size) + 2 * margin
    img = Image.new("L", (n, n), 0)
    draw = ImageDraw.Draw(img)
    any_lit = False
    for poly, lit in buildings:
        if lit <= 0:
            continue
        pts = [(x - x0 + margin, z - z0 + margin) for x, z in poly.exterior.coords]
        if max(p[0] for p in pts) < 0 or min(p[0] for p in pts) > n or \
                max(p[1] for p in pts) < 0 or min(p[1] for p in pts) > n:
            continue
        draw.polygon(pts, fill=max(1, int(lit * 255)))
        any_lit = True
    if any_lit:
        m = np.asarray(img, dtype=np.float64) / 255.0
        d, (iy, ix) = ndimage.distance_transform_edt(m == 0, return_indices=True)
        spill = m[iy, ix] * 0.22 * np.exp(-d / 2.2) * (d > 0)
        spill = spill[margin:margin + int(size), margin:margin + int(size)]
        zoom = res / spill.shape[0]
        spill = ndimage.zoom(spill, zoom, order=1)[:res, :res]
        acc += spill[..., None] * np.array([1.0, 0.75, 0.45])

    enc = np.sqrt(np.clip(acc / LMAP_SCALE, 0.0, 1.0))
    buf = io.BytesIO()
    Image.fromarray((enc * 255 + 0.5).astype(np.uint8), "RGB").save(buf, "PNG", optimize=True)
    return buf.getvalue()


def ribbon(line: LineString, half_w: float, kind: int, pos: list, attr: list, idx: list) -> None:
    c = np.asarray(line.coords, dtype=np.float64)
    if len(c) < 2:
        return
    seg = np.diff(c, axis=0)
    sl = np.hypot(seg[:, 0], seg[:, 1])
    keep = np.concatenate([[True], sl > 1e-3])
    c = c[keep]
    if len(c) < 2:
        return
    seg = np.diff(c, axis=0)
    sl = np.hypot(seg[:, 0], seg[:, 1])
    d = seg / sl[:, None]
    along = np.concatenate([[0.0], np.cumsum(sl)])
    t = np.empty_like(c)
    t[0], t[-1] = d[0], d[-1]
    if len(c) > 2:
        t[1:-1] = d[:-1] + d[1:]
    tl = np.hypot(t[:, 0], t[:, 1])
    bad = tl < 1e-6
    t[bad] = np.vstack([d, d[-1:]])[bad]
    t /= np.hypot(t[:, 0], t[:, 1])[:, None]
    n = np.column_stack([-t[:, 1], t[:, 0]])
    segn = np.column_stack([-d[:, 1], d[:, 0]])
    cosang = np.ones(len(c))
    cosang[1:] = np.abs(np.sum(n[1:] * segn, axis=1))
    scale = 1.0 / np.clip(cosang, 0.5, 1.0)
    base = len(pos)
    for i in range(len(c)):
        off = n[i] * half_w * scale[i]
        pos.append((c[i, 0] - off[0], c[i, 1] - off[1]))
        pos.append((c[i, 0] + off[0], c[i, 1] + off[1]))
        attr.append((-half_w, along[i], half_w, kind))
        attr.append((half_w, along[i], half_w, kind))
    for i in range(len(c) - 1):
        a = base + 2 * i
        idx.extend((a, a + 1, a + 2, a + 1, a + 3, a + 2))


def poisson_points(region, spacing: float, rng: np.random.Generator, limit: int) -> list[tuple[float, float]]:
    """Dart-throwing Poisson-disk sampling inside a (multi)polygon."""
    if region.is_empty or region.area < spacing * spacing * 0.5:
        return []
    minx, miny, maxx, maxy = region.bounds
    target = min(limit, int(region.area / (spacing * spacing) * 0.9) + 1)
    pts: list[tuple[float, float]] = []
    grid: dict[tuple[int, int], tuple[float, float]] = {}
    cell = spacing / math.sqrt(2)
    prepared = prep(region)
    tries = target * 30
    for _ in range(tries):
        if len(pts) >= target:
            break
        x, y = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
        gx, gy = int(x // cell), int(y // cell)
        ok = True
        for ix in range(gx - 2, gx + 3):
            for iy in range(gy - 2, gy + 3):
                q = grid.get((ix, iy))
                if q and (q[0] - x) ** 2 + (q[1] - y) ** 2 < spacing * spacing:
                    ok = False
                    break
            if not ok:
                break
        if ok and prepared.contains(Point(x, y)):
            pts.append((x, y))
            grid[(gx, gy)] = (x, y)
    return pts


class World:
    """All projected features plus spatial indexes."""

    def __init__(self, feats: list[Feat], proj: Projector):
        self.proj = proj
        by = {}
        for f in feats:
            f.geom = proj.fwd(f.geom)
            if not f.geom.is_valid:
                f.geom = shapely.make_valid(f.geom)
            by.setdefault(f.kind, []).append(f)
        self.by = by
        self.trees = {}
        for k, lst in by.items():
            self.trees[k] = STRtree([f.geom for f in lst])
        # Road / path buffers are reused by several steps.
        self.road_polys = []
        for f in by.get("road", []):
            w = road_width(f.tags, "road")
            f.extra["width"] = w
            self.road_polys.append(f.geom.buffer(w / 2, cap_style="round", join_style="round", quad_segs=3))
        self.path_polys = []
        for f in by.get("path", []):
            w = road_width(f.tags, "path")
            f.extra["width"] = w
            self.path_polys.append(f.geom.buffer(w / 2, cap_style="round", join_style="round", quad_segs=2))
        self.road_tree = STRtree(self.road_polys) if self.road_polys else None
        self.path_tree = STRtree(self.path_polys) if self.path_polys else None
        self.bld_polys = [p for f in by.get("building", []) for p in polygons_of(f.geom)]
        self.bld_tree = STRtree(self.bld_polys) if self.bld_polys else None

    def query(self, kind: str, geom) -> list[Feat]:
        if kind not in self.trees:
            return []
        return [self.by[kind][i] for i in self.trees[kind].query(geom)]

    def union_of(self, polys: list, tree: STRtree | None, rect) -> object:
        if tree is None:
            return Polygon()
        sel = [polys[i] for i in tree.query(rect)]
        if not sel:
            return Polygon()
        return unary_union(sel).intersection(rect)


def build_chunk(world: World, cx: int, cz: int, size: float, stats: dict, keep_clear=None):
    """Build all sections of one chunk except the light map (needs neighbours, see main).

    keep_clear: optional geometry (e.g. a disc around the spawn point) where no trees or
    generated lamps are placed."""
    x0, z0 = cx * size, cz * size
    rect = box(x0, z0, x0 + size, z0 + size)
    grown = rect.buffer(30)
    rng = np.random.default_rng(abs(hash((cx, cz))) % (2**32))
    w = Writer()

    # ---- buildings (assigned to the chunk containing their centroid; not clipped)
    battrs, pts, tris, poff, toff = [], [], [], [0], [0]
    light_buildings = []
    for f in world.query("building", rect):
        for poly in polygons_of(f.geom):
            c = poly.centroid
            if not (x0 <= c.x < x0 + size and z0 <= c.y < z0 + size):
                continue
            if poly.area < 8:
                continue
            outer = Polygon(poly.exterior).simplify(0.25, preserve_topology=True)
            if outer.is_empty or outer.geom_type != "Polygon" or outer.area < 8:
                continue
            outer = orient(outer, sign=1.0)
            height, levels, kind = building_params(f.tags, outer.area)
            name = f.tags.get("name", "").lower()
            landmark = 1.0 if any(k in name for k in LANDMARK_NAMES) else 0.0
            v, t = triangulate(outer)
            if len(t) == 0:
                continue
            t = fix_winding(v, t)
            seed = seed_of(f.osm_id)
            lit = lit_ratio(kind, seed)
            if landmark:
                lit = max(lit, 0.35)
            battrs.append((height, levels, 0.0, float(kind), seed, landmark, outer.area, lit))
            light_buildings.append((outer, lit))
            pts.extend(v.tolist())
            tris.extend(t.tolist())
            poff.append(len(pts))
            toff.append(len(tris))
    if battrs:
        w.section(b"BLDG", struct.pack("<III", len(battrs), len(pts), len(tris))
                  + f32(battrs) + u32(poff) + u32(toff) + f32(pts) + u32(tris))
    stats["buildings"] += len(battrs)

    # ---- flat surfaces as a planar partition (no overlaps -> no z-fighting)
    roads_u = world.union_of(world.road_polys, world.road_tree, rect)
    paths_u = world.union_of(world.path_polys, world.path_tree, rect).difference(roads_u)
    def area_union(kind):
        geoms = [p for f in world.query(kind, rect) for p in polygons_of(f.geom)]
        return unary_union(geoms).intersection(rect) if geoms else Polygon()
    taken = unary_union([roads_u, paths_u])
    squares_u = area_union("square").difference(taken)
    taken = unary_union([taken, squares_u])
    paved_u = area_union("paved").difference(taken)
    taken = unary_union([taken, paved_u])
    water_u = area_union("water").difference(taken)
    taken = unary_union([taken, water_u])
    wood_u = area_union("wood").difference(taken)
    park_u = area_union("park").difference(taken)
    taken = unary_union([taken, wood_u, park_u])
    ground_u = rect.difference(taken)

    fpos, fkind, fidx = [], [], []
    for geom, kind in ((ground_u, K_GROUND), (park_u, K_PARK), (wood_u, K_PARK), (squares_u, K_SQUARE),
                       (paved_u, K_PAVED), (roads_u, K_ROAD), (paths_u, K_PATH), (water_u, K_ICE)):
        for poly in polygons_of(geom.simplify(0.15, preserve_topology=True) if kind != K_GROUND else geom):
            if poly.area < 0.05:
                continue
            v, t = triangulate(poly)
            if len(t) == 0:
                continue
            t = fix_winding(v, t)
            base = len(fpos)
            fpos.extend(v.tolist())
            fkind.extend([float(kind)] * len(v))
            fidx.extend((t + base).tolist())
    w.section(b"FLAT", struct.pack("<II", len(fpos), len(fidx)) + f32(fpos) + f32(fkind) + u32(fidx))

    # ---- decal ribbons: tyre ruts on roads, trodden lines on paths (multiplied over the snow)
    dpos, dattr, didx = [], [], []
    for f in world.query("road", rect):
        for ln in lines_of(f.geom.intersection(rect)):
            ribbon(ln, f.extra["width"] / 2, K_ROAD, dpos, dattr, didx)
    for f in world.query("path", rect):
        if f.tags.get("highway") == "steps":
            continue
        for ln in lines_of(f.geom.intersection(rect)):
            ribbon(ln, min(f.extra["width"] / 2, 1.6), K_PATH, dpos, dattr, didx)
    if dpos:
        didx = fix_winding(dpos, didx)
        w.section(b"DECL", struct.pack("<II", len(dpos), len(didx)) + f32(dpos) + f32(dattr) + u32(didx))

    # ---- snow banks: ploughed snow along the kerbs of major roads, with gaps where
    #      paths and side roads meet them
    major = [world.road_polys[i] for i in (world.road_tree.query(rect) if world.road_tree else [])
             if world.by["road"][i].tags.get("highway") in MAJOR_ROADS]
    banks = []
    if major:
        major_u = unary_union(major)
        minor = [world.road_polys[i] for i in world.road_tree.query(grown)
                 if world.by["road"][i].tags.get("highway") not in MAJOR_ROADS]
        cut = unary_union([*[p.buffer(1.2) for p in minor],
                           world.union_of(world.path_polys, world.path_tree, grown).buffer(1.0),
                           *(world.bld_polys[i].buffer(0.6) for i in (world.bld_tree.query(grown)
                                                                       if world.bld_tree else []))])
        edge = major_u.boundary.intersection(rect).difference(cut)
        for ln in merge_lines(edge):
            if ln.length < 4:
                continue
            ln = ln.simplify(0.3)
            off = ln.offset_curve(0.55)
            if off.is_empty or off.geom_type != "LineString":
                continue
            mid = off.interpolate(0.5, normalized=True)
            if major_u.contains(mid):
                off = ln.offset_curve(-0.55)
                if off.is_empty or off.geom_type != "LineString":
                    continue
            banks.append(np.asarray(off.coords))
    if banks:
        offs = np.cumsum([0] + [len(b) for b in banks])
        allp = np.concatenate(banks)
        w.section(b"BANK", struct.pack("<II", len(banks), len(allp)) + u32(offs) + f32(allp))
    stats["banks_m"] += sum(LineString(b).length for b in banks)

    # ---- street lamps: OSM street_lamp nodes, plus generated ones along streets without them
    lamps = []  # x, z, yaw, from_osm
    def nearest_road_yaw(x, z):
        if world.road_tree is None:
            return float(rng.uniform(0, math.tau))
        p = Point(x, z)
        i = world.road_tree.nearest(p)
        f = world.by["road"][i]
        q = f.geom.interpolate(f.geom.project(p))
        dx, dz = q.x - x, q.y - z
        if dx * dx + dz * dz < 1e-4:
            return float(rng.uniform(0, math.tau))
        return math.atan2(-dx, -dz)  # Godot yaw so that -Z (forward) points at the road
    osm_lamps = [f.geom for f in world.query("lamp", rect) if rect.contains(f.geom)]
    for p in osm_lamps:
        lamps.append((p.x, p.y, nearest_road_yaw(p.x, p.y), LAMP_OSM))
    occupied = STRtree([Point(l[0], l[1]) for l in lamps]) if lamps else None
    placed = [Point(l[0], l[1]) for l in lamps]
    bld_near = [world.bld_polys[i] for i in (world.bld_tree.query(grown) if world.bld_tree else [])]
    bld_u = unary_union(bld_near).buffer(0.8) if bld_near else Polygon()
    surf_block = unary_union([roads_u, water_u] + ([keep_clear] if keep_clear is not None else []))
    def try_lamp(x, z, yaw, min_d=11.0, ltype=LAMP_STREET):
        p = Point(x, z)
        if not rect.contains(p) or bld_u.contains(p) or surf_block.contains(p):
            return
        if occupied is not None and any(placed[i].distance(p) < 16.0 for i in occupied.query(p.buffer(16.0))):
            return
        if any(q.distance(p) < min_d for q in placed[len(osm_lamps):]):
            return
        lamps.append((x, z, yaw, ltype))
        placed.append(p)
    for f in world.query("road", rect):
        hw = f.tags.get("highway")
        if hw not in MAJOR_ROADS and hw not in ("living_street", "pedestrian"):
            continue
        spacing = 34.0 if hw in ("primary", "secondary", "trunk") else 38.0
        both = hw in ("primary", "secondary", "trunk")
        off = f.extra["width"] / 2 + 1.2
        for ln in lines_of(f.geom.intersection(rect)):
            start = seed_of(f.osm_id) * spacing
            d, side = start, 1.0
            while d < ln.length:
                p, q = ln.interpolate(d), ln.interpolate(min(d + 0.5, ln.length))
                tx, tz = q.x - p.x, q.y - p.y
                tl = math.hypot(tx, tz) or 1.0
                nx, nz = -tz / tl, tx / tl
                for s in ((1.0, -1.0) if both else (side,)):
                    lx, lz = p.x + nx * off * s, p.y + nz * off * s
                    try_lamp(lx, lz, math.atan2(nx * s, nz * s))
                side = -side
                d += spacing
    for f in world.query("path", rect):
        if f.tags.get("highway") not in ("footway", "pedestrian", "path"):
            continue
        in_green = any(g.geom.intersects(f.geom) for g in world.query("park", f.geom.buffer(2)))
        if not in_green and f.tags.get("highway") != "pedestrian":
            continue
        for ln in lines_of(f.geom.intersection(rect)):
            d = seed_of(f.osm_id) * 22.0
            while d < ln.length:
                p, q = ln.interpolate(d), ln.interpolate(min(d + 0.5, ln.length))
                tx, tz = q.x - p.x, q.y - p.y
                tl = math.hypot(tx, tz) or 1.0
                nx, nz = -tz / tl, tx / tl
                off = f.extra["width"] / 2 + 0.8
                try_lamp(p.x + nx * off, p.y + nz * off, math.atan2(nx, nz), min_d=14.0, ltype=LAMP_PARK)
                d += 28.0
    if lamps:
        w.section(b"LAMP", struct.pack("<I", len(lamps)) + f32(lamps))
    stats["lamps_osm"] += len(osm_lamps)
    stats["lamps_generated"] += len(lamps) - len(osm_lamps)

    # ---- trees: OSM natural=tree nodes plus Poisson-scattered trees in parks and woods
    trees = [(f.geom.x, f.geom.y, float(rng.uniform(0.85, 1.25)), float(rng.random() < 0.3))
             for f in world.query("tree", rect) if rect.contains(f.geom)]
    keep_out = unary_union([roads_u.buffer(1.5), paths_u.buffer(1.0), squares_u, paved_u,
                            bld_u.buffer(1.5)] + [Point(l[0], l[1]).buffer(2.0) for l in lamps]
                           + ([keep_clear] if keep_clear is not None else []))
    for kind, spacing, spruce in (("wood", 5.5, 0.5), ("park", 8.0, 0.25)):
        for f in world.query(kind, rect):
            region = f.geom.intersection(rect).difference(keep_out)
            leisure = f.tags.get("leisure")
            if leisure in ("pitch", "playground") or f.tags.get("landuse") == "cemetery":
                continue
            sp = spacing if (kind == "wood" or leisure in ("park", "garden")) else 13.0
            for x, z in poisson_points(region, sp, rng, 300):
                trees.append((x, z, float(rng.uniform(0.75, 1.3)), float(rng.random() < spruce)))
    if trees:
        w.section(b"TREE", struct.pack("<I", len(trees)) + f32(trees))
    stats["trees"] += len(trees)
    return w, lamps, light_buildings


def find_spawn(world: World, feats_named: dict) -> tuple[dict, list[dict]]:
    """Spawn on the Esplanade, facing the Opera Theatre, with the longest clear view."""
    landmarks = []
    opera = feats_named.get("opera")
    esplanade = feats_named.get("esplanade")
    if opera is not None:
        c = opera.geom.centroid
        landmarks.append({"name": opera.tags.get("name", "Opera"), "x": round(c.x, 2), "z": round(c.y, 2),
                          "osm_id": opera.osm_id})
    if esplanade is not None:
        c = esplanade.geom.representative_point()
        landmarks.append({"name": esplanade.tags.get("name", "Esplanade"), "x": round(c.x, 2),
                          "z": round(c.y, 2), "osm_id": esplanade.osm_id})
    if esplanade is None:
        print("WARNING: no 'Эспланада' area found; spawning at the origin")
        return {"x": 0.0, "z": 0.0, "yaw_deg": 0.0}, landmarks
    region = esplanade.geom
    if world.bld_tree is not None:
        near = [world.bld_polys[i] for i in world.bld_tree.query(region)]
        if near:
            region = region.difference(unary_union(near).buffer(4.0))
    region = region.buffer(-3.0)
    target = opera.geom.centroid if opera is not None else None
    minx, miny, maxx, maxy = region.bounds
    best, best_score = None, -1e9
    prepared = prep(region)
    for x in np.arange(minx, maxx, 8.0):
        for z in np.arange(miny, maxy, 8.0):
            p = Point(x, z)
            if not prepared.contains(p):
                continue
            if target is None:
                return {"x": round(x, 2), "z": round(z, 2), "yaw_deg": 0.0}, landmarks
            dist = p.distance(target)
            ray = LineString([(x, z), (target.x, target.y)])
            clear = dist
            if world.bld_tree is not None:
                for i in world.bld_tree.query(ray):
                    b = world.bld_polys[i]
                    if opera is not None and b.intersects(opera.geom.buffer(-0.5)):
                        continue
                    if b.intersects(ray):
                        clear = min(clear, p.distance(b))
            score = min(clear, 350.0) - 0.15 * dist
            if score > best_score:
                best, best_score = (x, z, dist, clear), score
    if best is None:
        c = esplanade.geom.representative_point()
        best = (c.x, c.y, 0, 0)
    x, z = best[0], best[1]
    yaw = math.degrees(math.atan2(-(target.x - x), -(target.y - z))) if target is not None else 0.0
    print(f"spawn on the Esplanade at ({x:.1f}, {z:.1f}), {best[2]:.0f} m from the Opera, "
          f"clear view {best[3]:.0f} m, yaw {yaw:.1f} deg")
    return {"x": round(float(x), 2), "z": round(float(z), 2), "yaw_deg": round(yaw, 2)}, landmarks


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["overpass", "pbf", "features"], default="overpass")
    ap.add_argument("--pbf", type=Path, help="path to a .osm.pbf extract (with --source pbf)")
    ap.add_argument("--features", type=Path, help="GeoJSON features file (with --source features)")
    ap.add_argument("--bbox", help="min_lon,min_lat,max_lon,max_lat (default: Esplanade..Opera, Perm)")
    ap.add_argument("--origin", help="lat,lon of the world origin (default: existing manifest or bbox centre)")
    ap.add_argument("--chunk-size", type=float, default=CHUNK_SIZE)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--merge", action="store_true", help="add chunks to an existing dataset in --out")
    ap.add_argument("--overpass-endpoint", default=None)
    ap.add_argument("--cache", type=Path, default=Path(__file__).parent / "cache")
    ap.add_argument("--name", default="Perm city centre")
    args = ap.parse_args(argv)

    t0 = time.time()
    bbox = tuple(float(v) for v in args.bbox.split(",")) if args.bbox else DEFAULT_BBOX
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = out / "manifest.json"
    old = json.loads(manifest_path.read_text()) if (args.merge and manifest_path.exists()) else None

    if args.origin:
        lat0, lon0 = (float(v) for v in args.origin.split(","))
    elif old:
        lat0, lon0 = old["origin"]["lat"], old["origin"]["lon"]
    else:
        lat0, lon0 = (bbox[1] + bbox[3]) / 2, (bbox[0] + bbox[2]) / 2
    size = old["chunk_size"] if old else args.chunk_size
    proj = Projector(lat0, lon0)

    # Chunks covering the bbox (z grows southwards, so max_lat gives the min z).
    xa, za = proj.xz(bbox[0], bbox[3])
    xb, zb = proj.xz(bbox[2], bbox[1])
    cx0, cx1 = math.floor(xa / size), math.ceil(xb / size) - 1
    cz0, cz1 = math.floor(za / size), math.ceil(zb / size) - 1
    chunk_ids = [(cx, cz) for cx in range(cx0, cx1 + 1) for cz in range(cz0, cz1 + 1)]
    lon_a, lat_a = proj.lonlat(cx0 * size - FETCH_MARGIN_M, (cz1 + 1) * size + FETCH_MARGIN_M)
    lon_b, lat_b = proj.lonlat((cx1 + 1) * size + FETCH_MARGIN_M, cz0 * size - FETCH_MARGIN_M)
    fetch_bbox = (lon_a, lat_a, lon_b, lat_b)
    print(f"origin {lat0:.6f},{lon0:.6f}; {len(chunk_ids)} chunks of {size:.0f} m "
          f"(x {cx0}..{cx1}, z {cz0}..{cz1}); fetch bbox {','.join(f'{v:.5f}' for v in fetch_bbox)}")

    if args.source == "overpass":
        feats = feats_from_overpass(fetch_overpass(fetch_bbox, args.overpass_endpoint, args.cache))
        source_note = "OpenStreetMap via Overpass API"
    elif args.source == "pbf":
        if not args.pbf or not args.pbf.exists():
            raise SystemExit("--source pbf needs --pbf <file.osm.pbf> (see README)")
        feats = feats_from_pbf(args.pbf, fetch_bbox)
        source_note = f"OpenStreetMap extract {args.pbf.name}"
    else:
        if not args.features or not args.features.exists():
            raise SystemExit("--source features needs --features <file.geojson>")
        feats = feats_from_geojson(args.features)
        source_note = f"OpenStreetMap features from {args.features.name}"
    counts = {}
    for f in feats:
        counts[f.kind] = counts.get(f.kind, 0) + 1
    print("features:", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))

    named = {}
    for f in feats:
        n = f.tags.get("name", "").lower()
        if f.kind == "building" and ("театр оперы" in n or "opera" in n):
            named.setdefault("opera", f)
        if f.kind in ("park", "square", "paved") and "эспланада" in n:
            if "esplanade" not in named or f.geom.area > named["esplanade"].geom.area:
                named["esplanade"] = f

    world = World(feats, proj)
    stats = {"buildings": 0, "lamps_osm": 0, "lamps_generated": 0, "trees": 0, "banks_m": 0.0}
    if old and not args.origin and "spawn" in old:
        spawn, landmarks = old["spawn"], old.get("landmarks", [])
    else:
        spawn, landmarks = find_spawn(world, named)
    # Keep the first view open: no trees or generated lamps right at the spawn point.
    spawn_clear = Point(spawn["x"], spawn["z"]).buffer(9.0)
    chunk_index = dict(old["chunks"]) if old else {}
    total_bytes = 0
    built = {cid: build_chunk(world, cid[0], cid[1], size, stats, spawn_clear) for cid in chunk_ids}
    for (cx, cz), (w, _, _) in built.items():
        near_lamps, near_blds = [], []
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                nb = built.get((cx + dx, cz + dz))
                if nb:
                    near_lamps.extend(nb[1])
                    near_blds.extend(nb[2])
        png = bake_light_map(cx, cz, size, near_lamps, near_blds)
        w.section(b"LMAP", struct.pack("<II", LMAP_RES, len(png)) + png)
        data = w.finish(cx, cz, size)
        name = f"chunk_{cx}_{cz}.bin"
        (out / name).write_bytes(data)
        total_bytes += len(data)
        chunk_index[f"{cx},{cz}"] = name

    keys = [tuple(int(v) for v in k.split(",")) for k in chunk_index]
    bounds = [min(k[0] for k in keys) * size, min(k[1] for k in keys) * size,
              (max(k[0] for k in keys) + 1) * size, (max(k[1] for k in keys) + 1) * size]
    manifest = {
        "format": "PWC1",
        "version": FORMAT_VERSION,
        "name": args.name,
        "origin": {"lat": lat0, "lon": lon0},
        "projection": "local equirectangular; x = east, z = south (metres)",
        "chunk_size": size,
        "bounds": bounds,
        "chunks": dict(sorted(chunk_index.items())),
        "spawn": spawn,
        "landmarks": landmarks,
        "source": source_note,
        "attribution": "© OpenStreetMap contributors",
        "license": "Open Database License (ODbL) 1.0, https://www.openstreetmap.org/copyright",
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "stats": {k: (round(v) if isinstance(v, float) else v) for k, v in stats.items()},
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    print(f"wrote {len(chunk_ids)} chunks ({total_bytes / 1024:.0f} KiB) + manifest to {out} "
          f"in {time.time() - t0:.1f} s; stats {manifest['stats']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
