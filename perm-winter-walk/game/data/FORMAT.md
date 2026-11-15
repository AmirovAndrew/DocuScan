# Map data format (PWC1)

Written by `tools/preprocess_osm.py`, read by `scripts/city/chunk_loader.gd`.
A dataset is one folder (e.g. `data/perm/`) holding `manifest.json` and one binary
file per chunk. All data is © OpenStreetMap contributors, ODbL 1.0.

## Coordinates

Godot world metres around the dataset origin (`manifest.origin`, WGS84):
`x` = east, `z` = south (`z = -north`), `y` = up. Local equirectangular projection:
`x = (lon - lon0) * cos(lat0) * R * pi/180`, `z = -(lat - lat0) * R * pi/180`, `R = 6371008.8`.

Chunks are squares of `chunk_size` metres (250). Chunk `(cx, cz)` covers
`x ∈ [cx·size, (cx+1)·size)`, `z ∈ [cz·size, (cz+1)·size)`.

## manifest.json

| key | meaning |
|---|---|
| `origin` | `{lat, lon}` of world (0, 0) |
| `chunk_size` | metres |
| `bounds` | `[min_x, min_z, max_x, max_z]` covered by chunks |
| `chunks` | `{"cx,cz": "chunk_cx_cz.bin"}` |
| `spawn` | `{x, z, yaw_deg}`: on the Esplanade, facing the Opera Theatre |
| `landmarks` | `[{name, x, z, osm_id}]` |
| `attribution`, `license`, `source`, `generated`, `stats` | provenance |

Adding an area later (`--merge`) appends to `chunks` and grows `bounds`; the origin and
grid never change, so old chunks stay valid.

## Chunk file

Little-endian. Every section payload is padded to 4 bytes.

```
header   char[4] "PWC1" | u32 version (1) | i32 cx | i32 cz | f32 chunk_size | u32 section_count
section  char[4] tag    | u32 payload_bytes | payload
```

| tag | payload |
|---|---|
| `BLDG` | `u32 n, u32 npts, u32 ntri`, `f32[n·8]` attrs, `u32[n+1]` point offsets, `u32[n+1]` triangle offsets, `f32[npts·2]` outer-ring points (x, z; counter-clockwise in x/z), `u32[ntri]` roof triangle indices (relative to the building's first point) |
| `FLAT` | `u32 nv, u32 ni`, `f32[nv·2]` positions, `f32[nv]` surface kind, `u32[ni]` indices. A planar partition of the chunk: no overlaps |
| `DECL` | `u32 nv, u32 ni`, `f32[nv·2]` positions, `f32[nv·4]` (across m, along m, half width, kind), `u32[ni]` indices. Ribbons along roads/paths |
| `BANK` | `u32 nlines, u32 npts`, `u32[nlines+1]` offsets, `f32[npts·2]` polylines: kerb snow banks |
| `LAMP` | `u32 n`, `f32[n·4]` (x, z, yaw, type: 0 generated street, 1 OSM street lamp, 2 generated park lamp) |
| `TREE` | `u32 n`, `f32[n·4]` (x, z, scale, type: 0 bare deciduous, 1 spruce) |
| `LMAP` | `u32 res, u32 png_bytes`, PNG: baked warm light on the snow, RGB = sqrt(light / 2) |

Building attrs: `height m, levels, min_height, kind, seed, landmark, footprint m², lit share`.
Building kinds: 0 residential, 1 commercial, 2 public, 3 utility, 4 religious.
Surface kinds: 0 snow, 1 park, 2 square, 3 road, 4 footpath, 5 frozen river, 6 paved.

Triangles are wound counter-clockwise in (x, z), which is Godot's front face seen from above.
Unknown section tags must be skipped, so newer files stay readable by older loaders.
