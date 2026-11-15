#!/usr/bin/env python3
"""Development fallback: fetch the OpenStreetMap-sourced part of Overture Maps for a bbox.

WHY THIS EXISTS
    The normal route is tools/preprocess_osm.py with --source overpass (Overpass API)
    or --source pbf (a Geofabrik / other .osm.pbf extract). The sandbox this project was
    built in could not reach Overpass, Geofabrik or openstreetmap.org, but it could reach
    the public Overture Maps mirror on AWS S3. Overture redistributes OSM data (ODbL)
    alongside other sources, and every record lists its sources. This script keeps ONLY
    records whose sources are all `OpenStreetMap` (the OSM way/relation id is kept), so
    the result is OSM data, just delivered through a different mirror. Microsoft/Google
    ML building footprints and any non-OSM records are dropped.

    It writes a GeoJSON FeatureCollection with OSM-style tags, which
    preprocess_osm.py reads with --source features.

HOW IT WORKS
    Overture GeoParquet files are spatially sorted and carry per-row-group min/max
    statistics for the bbox columns. We read just the Parquet footers over HTTP range
    requests, pick the row groups that overlap the bbox, and download only the needed
    columns of those row groups (a few MB instead of hundreds of GB).

    python3 tools/fetch_overture_osm.py --bbox 56.225,58.004,56.262,58.024 \
        --out tools/cache/perm_overture_osm.geojson
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import io
import json
import re
import sys
import threading
from pathlib import Path

import pyarrow.parquet as pq
import requests
import shapely
from shapely import wkb

BUCKET = "https://overturemaps-us-west-2.s3.us-west-2.amazonaws.com"
THEMES = {
    "building": "theme=buildings/type=building",
    "segment": "theme=transportation/type=segment",
    "water": "theme=base/type=water",
    "land_use": "theme=base/type=land_use",
    "land": "theme=base/type=land",
    "infrastructure": "theme=base/type=infrastructure",
}
_local = threading.local()


def session() -> requests.Session:
    if not hasattr(_local, "s"):
        _local.s = requests.Session()
    return _local.s


class HttpRangeFile(io.RawIOBase):
    """Seekable read-only file over HTTP range requests (enough for pyarrow)."""

    def __init__(self, url: str, size: int):
        self.url, self.size, self.pos = url, size, 0
        self.requests = 0
        self.bytes = 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, offset: int, whence: int = 0) -> int:
        self.pos = {0: offset, 1: self.pos + offset, 2: self.size + offset}[whence]
        return self.pos

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            n = self.size - self.pos
        end = min(self.pos + n, self.size)
        if end <= self.pos:
            return b""
        for attempt in range(4):
            try:
                r = session().get(self.url, headers={"Range": f"bytes={self.pos}-{end - 1}"}, timeout=120)
                r.raise_for_status()
                break
            except requests.RequestException:
                if attempt == 3:
                    raise
        data = r.content
        self.requests += 1
        self.bytes += len(data)
        self.pos += len(data)
        return data

    def readinto(self, b) -> int:
        data = self.read(len(b))
        b[: len(data)] = data
        return len(data)


def list_files(release: str, theme_path: str) -> list[tuple[str, int]]:
    out, token = [], None
    while True:
        params = {"list-type": "2", "prefix": f"release/{release}/{theme_path}/"}
        if token:
            params["continuation-token"] = token
        xml = session().get(BUCKET + "/", params=params, timeout=60).text
        for key, size in re.findall(r"<Key>([^<]+)</Key>.*?<Size>(\d+)</Size>", xml, re.S):
            if key.endswith(".parquet"):
                out.append((key, int(size)))
        m = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", xml)
        if not m:
            return out
        token = m.group(1)


def latest_release() -> str:
    xml = session().get(BUCKET + "/", params={"list-type": "2", "prefix": "release/", "delimiter": "/"}, timeout=60).text
    rels = sorted(re.findall(r"<Prefix>release/([^<]+)/</Prefix>", xml))
    return rels[-1]


def bbox_stats(md, rg: int) -> tuple[float, float, float, float] | None:
    """(xmin, ymin, xmax, ymax) of a row group from the bbox.* column statistics."""
    vals = {}
    row = md.row_group(rg)
    for c in range(row.num_columns):
        col = row.column(c)
        path = col.path_in_schema
        if path in ("bbox.xmin", "bbox.ymin", "bbox.xmax", "bbox.ymax") and col.statistics is not None:
            st = col.statistics
            if not st.has_min_max:
                return None
            vals[path] = (st.min, st.max)
    if len(vals) < 4:
        return None
    return vals["bbox.xmin"][0], vals["bbox.ymin"][0], vals["bbox.xmax"][1], vals["bbox.ymax"][1]


def scan_file(key: str, size: int, bbox) -> list[int]:
    f = HttpRangeFile(f"{BUCKET}/{key}", size)
    md = pq.ParquetFile(f).metadata
    hits = []
    for rg in range(md.num_row_groups):
        st = bbox_stats(md, rg)
        if st is None:
            continue
        x0, y0, x1, y1 = st
        if x0 <= bbox[2] and x1 >= bbox[0] and y0 <= bbox[3] and y1 >= bbox[1]:
            hits.append(rg)
    return hits


def read_rows(key: str, size: int, rgs: list[int], bbox) -> list[dict]:
    f = HttpRangeFile(f"{BUCKET}/{key}", size)
    pf = pq.ParquetFile(f)
    names = set(pf.schema_arrow.names)
    wanted = [c for c in (
        "id", "geometry", "bbox", "sources", "names", "class", "subtype", "height", "num_floors",
        "min_height", "min_floor", "roof_shape", "facade_color", "is_underground", "level",
        "subclass", "road_flags", "width", "road_surface") if c in names]
    rows = []
    for rg in rgs:
        tbl = pf.read_row_group(rg, columns=wanted)
        for rec in tbl.to_pylist():
            b = rec["bbox"]
            if b["xmin"] > bbox[2] or b["xmax"] < bbox[0] or b["ymin"] > bbox[3] or b["ymax"] < bbox[1]:
                continue
            rows.append(rec)
    return rows


def osm_only(rec: dict) -> str | None:
    """Return the OSM record id if every source of this record is OpenStreetMap."""
    srcs = rec.get("sources") or []
    if not srcs:
        return None
    ids = []
    for s in srcs:
        if (s.get("dataset") or "") != "OpenStreetMap":
            return None
        if s.get("record_id"):
            ids.append(s["record_id"])
    return ids[0] if ids else "unknown"


def name_of(rec: dict) -> str | None:
    n = rec.get("names") or {}
    return n.get("primary") if isinstance(n, dict) else None


def to_features(kind: str, rows: list[dict]) -> list[dict]:
    feats = []
    for rec in rows:
        osm_id = osm_only(rec)
        if osm_id is None:
            continue
        geom = wkb.loads(rec["geometry"])
        tags: dict[str, str] = {}
        nm = name_of(rec)
        if nm:
            tags["name"] = nm
        cls, sub = rec.get("class"), rec.get("subtype")
        if kind == "building":
            if rec.get("is_underground"):
                continue
            tags["building"] = cls or "yes"
            if rec.get("height") is not None:
                tags["height"] = f"{rec['height']:.2f}"
            if rec.get("num_floors") is not None:
                tags["building:levels"] = str(rec["num_floors"])
            if rec.get("min_height") is not None:
                tags["min_height"] = f"{rec['min_height']:.2f}"
            if rec.get("facade_color"):
                tags["building:colour"] = rec["facade_color"]
        elif kind == "segment":
            if sub != "road":
                continue  # rail / water segments
            tags["highway"] = cls or "road"
            flags = set()
            for f in rec.get("road_flags") or []:
                flags.update(f.get("values") or [])
            if "is_tunnel" in flags:
                tags["tunnel"] = "yes"
            if "is_bridge" in flags:
                tags["bridge"] = "yes"
            if cls == "footway" and rec.get("subclass"):
                tags["footway"] = rec["subclass"]
        elif kind == "water":
            tags["natural"] = "water"
            if cls in ("river", "riverbank", "canal", "stream") or sub == "river":
                tags["water"] = "river"
            tags["overture:class"] = f"{sub}/{cls}"
            if geom.geom_type in ("LineString", "MultiLineString"):
                continue  # waterway centre lines; we only want areas
        elif kind in ("land_use", "land"):
            tags["overture:class"] = f"{sub}/{cls}"
            mapped = {
                "park": ("leisure", "park"), "garden": ("leisure", "garden"),
                "grass": ("landuse", "grass"), "meadow": ("landuse", "meadow"),
                "forest": ("landuse", "forest"), "wood": ("natural", "wood"),
                "pedestrian": ("highway", "pedestrian"), "plaza": ("place", "square"),
                "square": ("place", "square"), "parking": ("amenity", "parking"),
                "cemetery": ("landuse", "cemetery"), "playground": ("leisure", "playground"),
                "pitch": ("leisure", "pitch"), "recreation_ground": ("landuse", "recreation_ground"),
                "scrub": ("natural", "scrub"), "village_green": ("landuse", "village_green"),
            }.get(cls or "")
            if mapped is None or geom.geom_type not in ("Polygon", "MultiPolygon"):
                continue
            tags[mapped[0]] = mapped[1]
            if mapped == ("highway", "pedestrian"):
                tags["area"] = "yes"
        elif kind == "infrastructure":
            if cls != "street_lamp":
                continue
            tags["highway"] = "street_lamp"
        feats.append({
            "type": "Feature",
            "geometry": shapely.geometry.mapping(geom),
            "properties": {"osm_id": osm_id, "tags": tags},
        })
    return feats


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bbox", required=True, help="min_lon,min_lat,max_lon,max_lat")
    ap.add_argument("--release", default=None, help="Overture release (default: latest)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--themes", default=",".join(THEMES))
    ap.add_argument("--workers", type=int, default=16)
    args = ap.parse_args()
    bbox = [float(v) for v in args.bbox.split(",")]
    release = args.release or latest_release()
    print("Overture release", release, "bbox", bbox)

    all_feats: list[dict] = []
    stats = {}
    for kind in args.themes.split(","):
        files = list_files(release, THEMES[kind])
        with cf.ThreadPoolExecutor(args.workers) as ex:
            hits = list(ex.map(lambda kv: scan_file(kv[0], kv[1], bbox), files))
        todo = [(k, s, h) for (k, s), h in zip(files, hits) if h]
        n_rg = sum(len(h) for _, _, h in todo)
        print(f"  {kind}: {len(files)} files scanned, {n_rg} row groups in {len(todo)} files overlap")
        rows = []
        with cf.ThreadPoolExecutor(min(args.workers, max(1, n_rg))) as ex:
            jobs = [ex.submit(read_rows, k, s, [rg], bbox) for k, s, h in todo for rg in h]
            for j in jobs:
                rows.extend(j.result())
        feats = to_features(kind, rows)
        stats[kind] = (len(rows), len(feats))
        print(f"  {kind}: {len(rows)} records in bbox, {len(feats)} kept (OpenStreetMap-only sources)")
        all_feats.extend(feats)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    fc = {
        "type": "FeatureCollection",
        "bbox": bbox,
        "metadata": {
            "source": f"Overture Maps release {release}, filtered to records sourced only from OpenStreetMap",
            "license": "ODbL 1.0 - (c) OpenStreetMap contributors",
            "counts": {k: {"in_bbox": a, "osm_kept": b} for k, (a, b) in stats.items()},
        },
        "features": all_feats,
    }
    out.write_text(json.dumps(fc, ensure_ascii=False))
    print("wrote", out, f"({out.stat().st_size / 1e6:.1f} MB, {len(all_feats)} features)")


if __name__ == "__main__":
    sys.exit(main())
