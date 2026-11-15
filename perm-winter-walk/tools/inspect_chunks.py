#!/usr/bin/env python3
"""Decode chunk files (independently of the writer) and draw a top-down map PNG.

    python3 tools/inspect_chunks.py game/data/perm --png map.png
"""
import argparse
import json
import struct
from pathlib import Path

import numpy as np


def read_chunk(path: Path) -> dict:
    b = path.read_bytes()
    magic, ver, cx, cz, size, nsec = struct.unpack_from("<4sIiifI", b, 0)
    assert magic == b"PWC1", magic
    off = 24
    out = {"cx": cx, "cz": cz, "size": size, "version": ver}
    for _ in range(nsec):
        tag, ln = struct.unpack_from("<4sI", b, off)
        p = b[off + 8: off + 8 + ln]
        off += 8 + ln
        t = tag.decode()
        if t == "BLDG":
            n, npts, ntri = struct.unpack_from("<III", p)
            o = 12
            attrs = np.frombuffer(p, "<f4", n * 8, o).reshape(n, 8); o += n * 32
            poff = np.frombuffer(p, "<u4", n + 1, o); o += (n + 1) * 4
            toff = np.frombuffer(p, "<u4", n + 1, o); o += (n + 1) * 4
            pts = np.frombuffer(p, "<f4", npts * 2, o).reshape(npts, 2); o += npts * 8
            tris = np.frombuffer(p, "<u4", ntri, o)
            out[t] = dict(attrs=attrs, poff=poff, toff=toff, pts=pts, tris=tris)
        elif t in ("FLAT", "DECL"):
            nv, ni = struct.unpack_from("<II", p)
            o = 8
            pos = np.frombuffer(p, "<f4", nv * 2, o).reshape(nv, 2); o += nv * 8
            k = 1 if t == "FLAT" else 4
            attr = np.frombuffer(p, "<f4", nv * k, o).reshape(nv, k); o += nv * k * 4
            idx = np.frombuffer(p, "<u4", ni, o)
            out[t] = dict(pos=pos, attr=attr, idx=idx)
        elif t == "BANK":
            nl, npts = struct.unpack_from("<II", p)
            offs = np.frombuffer(p, "<u4", nl + 1, 8)
            pts = np.frombuffer(p, "<f4", npts * 2, 8 + (nl + 1) * 4).reshape(npts, 2)
            out[t] = dict(offs=offs, pts=pts)
        elif t in ("LAMP", "TREE"):
            (n,) = struct.unpack_from("<I", p)
            out[t] = np.frombuffer(p, "<f4", n * 4, 4).reshape(n, 4)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", type=Path)
    ap.add_argument("--png", type=Path)
    ap.add_argument("--window", help="x0,z0,x1,z1 to zoom")
    a = ap.parse_args()
    man = json.loads((a.dataset / "manifest.json").read_text())
    chunks = [read_chunk(a.dataset / f) for f in man["chunks"].values()]
    nb = sum(len(c["BLDG"]["attrs"]) for c in chunks if "BLDG" in c)
    nl = sum(len(c["LAMP"]) for c in chunks if "LAMP" in c)
    print(f"{len(chunks)} chunks, {nb} buildings, {nl} lamps, spawn {man['spawn']}")
    if not a.png:
        return
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    colors = {0: "#e8eef7", 1: "#cfe3d0", 2: "#c9c4d6", 3: "#555a66", 4: "#9aa3b5", 5: "#8fb4d9", 6: "#a8a4b0"}
    fig, ax = plt.subplots(figsize=(16, 14), dpi=110)
    for c in chunks:
        if "FLAT" in c:
            f = c["FLAT"]
            tri = f["pos"][f["idx"].reshape(-1, 3)]
            kinds = f["attr"][f["idx"][0::3], 0].astype(int)
            ax.add_collection(PolyCollection(tri, facecolors=[colors[k] for k in kinds], edgecolors="none"))
    for c in chunks:
        if "BLDG" in c:
            b = c["BLDG"]
            polys = [b["pts"][b["poff"][i]:b["poff"][i + 1]] for i in range(len(b["attrs"]))]
            h = b["attrs"][:, 0]
            ax.add_collection(PolyCollection(polys, array=h, cmap="magma", clim=(0, 40), edgecolors="k", linewidths=0.2))
        if "BANK" in c:
            bk = c["BANK"]
            for i in range(len(bk["offs"]) - 1):
                p = bk["pts"][bk["offs"][i]:bk["offs"][i + 1]]
                ax.plot(p[:, 0], p[:, 1], color="white", lw=0.6)
        if "TREE" in c:
            t = c["TREE"]
            ax.scatter(t[:, 0], t[:, 1], s=2, c=np.where(t[:, 3] > 0.5, "#1d5a32", "#6b4f2a"))
        if "LAMP" in c:
            l = c["LAMP"]
            ax.scatter(l[:, 0], l[:, 1], s=5, c=np.where(l[:, 3] > 0.5, "red", "orange"))
    s = man["spawn"]
    ax.plot([s["x"]], [s["z"]], "c*", ms=18)
    import math
    yaw = math.radians(s["yaw_deg"])
    ax.arrow(s["x"], s["z"], -math.sin(yaw) * 120, -math.cos(yaw) * 120, color="c", width=4)
    for lm in man.get("landmarks", []):
        ax.annotate(lm["name"][:40], (lm["x"], lm["z"]), color="blue", fontsize=9)
    x0, z0, x1, z1 = man["bounds"]
    if a.window:
        x0, z0, x1, z1 = (float(v) for v in a.window.split(","))
    ax.set_xlim(x0, x1)
    ax.set_ylim(z1, z0)  # z is south: flip so north is up
    ax.set_aspect("equal")
    ax.set_title("x east / z south (north up). orange=generated lamps, red=OSM lamps")
    fig.savefig(a.png, bbox_inches="tight")
    print("wrote", a.png)


if __name__ == "__main__":
    main()
