#!/usr/bin/env python3
"""Generate conquest_caspian: a 5-flag BF4-Caspian-Border-style infantry Conquest map.

world_half=500 (1000 m across). North-south push across a fully-destructible E-W
border wall; heightmap Hilltop/forest/ridges/river. Coordinates traced from the
owner's annotated reference (docs/superpowers/specs/2026-07-13-conquest-caspian-map-design.md).

Run:  python3 tools/map_gen_caspian.py   ->  writes maps/conquest_caspian.json
      + maps/heightmaps/conquest_caspian.png + _surface.png
"""
import json, os, zlib, struct

CELL = 2.4                     # BuildGrid.CELL_SIZE
WORLD_HALF = 500.0
SPACING = 2.0                  # terrain sample spacing (m)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FP = {}

def extent(name):
    """Cell extent (minx, maxx, minz, maxz) of a prefab."""
    if name not in _FP:
        data = json.load(open(os.path.join(ROOT, "buildings", name + ".json")))
        xs = [p["offset"][0] for p in data["pieces"]]
        zs = [p["offset"][2] for p in data["pieces"]]
        _FP[name] = (min(xs), max(xs), min(zs), max(zs))
    return _FP[name]

def footprint(name):
    minx, maxx, minz, maxz = extent(name)
    return (maxx - minx + 1, maxz - minz + 1)

buildings = []
def place(name, x0, z0, yaw=0):
    """Place a prefab so its MIN world corner lands at (x0,z0)."""
    minx, _mx, minz, _mz = extent(name)
    cx = round(x0 / CELL) - minx
    cz = round(z0 / CELL) - minz
    buildings.append({"prefab": name, "origin_cell": [cx, 0, cz], "yaw": yaw})
    nx, nz = footprint(name)
    return nx * CELL, nz * CELL

def _write_gray_png(path, width, height, data):
    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(data[y * width:(y + 1) * width])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"); f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat)); f.write(chunk(b"IEND", b""))

def _write_rgb_png(path, width, height, rgb_bytes):
    def chunk(typ, body):
        return (struct.pack(">I", len(body)) + typ + body
                + struct.pack(">I", zlib.crc32(typ + body) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(rgb_bytes[y * stride:(y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"); f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat)); f.write(chunk(b"IEND", b""))

def main():
    print("map_gen_caspian: skeleton OK")

if __name__ == "__main__":
    main()
