#!/usr/bin/env python3
"""Convert OBJ models (e.g. Broken Vector Weapons Pack) to GLB for Godot.

Preserves MTL vertex colors. Applies Z-up -> Y-up when --z-up is set (Broken Vector OBJ exports).

Usage:
  tools/.venv-scenery/bin/python tools/obj_to_glb.py \\
    --input ~/projects/blockfire-models/WeaponsPack_V.1/OBJ/AssaultRifle_01.obj \\
    --output assets/weapons/assault_rifle.glb
"""
from __future__ import annotations

import argparse
import os
import re

import numpy as np
import trimesh
from trimesh.transformations import rotation_matrix


def slugify(name: str) -> str:
    s = re.sub(r"\.(obj)$", "", name, flags=re.IGNORECASE)
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_").lower()


def z_up_to_y_up() -> np.ndarray:
    r = rotation_matrix(-np.pi / 2.0, [1.0, 0.0, 0.0])[:3, :3]
    m = np.eye(4)
    m[:3, :3] = r
    return m


def convert_one(src: str, dst: str, z_up: bool) -> None:
    scene = trimesh.load(src, force="scene")
    if z_up:
        scene.apply_transform(z_up_to_y_up())
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    scene.export(dst)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="OBJ file or directory")
    p.add_argument("--output", required=True, help="Output .glb file or directory")
    p.add_argument("--z-up", action="store_true", help="Rotate Z-up source to Y-up")
    args = p.parse_args()

    in_path = os.path.abspath(args.input)
    out_path = os.path.abspath(args.output)

    if os.path.isfile(in_path):
        dst = out_path if out_path.endswith(".glb") else os.path.join(out_path, slugify(os.path.basename(in_path)) + ".glb")
        convert_one(in_path, dst, args.z_up)
        print(f"OK {in_path} -> {dst}")
        return

    os.makedirs(out_path, exist_ok=True)
    for fname in sorted(os.listdir(in_path)):
        if not fname.lower().endswith(".obj"):
            continue
        src = os.path.join(in_path, fname)
        dst = os.path.join(out_path, slugify(fname) + ".glb")
        convert_one(src, dst, args.z_up)
        print(f"OK {fname} -> {dst}")


if __name__ == "__main__":
    main()
