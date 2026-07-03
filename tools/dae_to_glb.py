#!/usr/bin/env python3
"""Batch-convert Broken Vector Collada (.dae) scenery to glTF binary for Godot.

Uses trimesh (no Blender Collada addon required). Broken Vector models are Z-up with
UV-mapped colorsheet textures (no embedded images in the DAE).

Usage:
  tools/.venv-scenery/bin/python tools/dae_to_glb.py \
    --input ~/projects/blockfire-models/trees/Models \
    --textures ~/projects/blockfire-models/trees/Textures \
    --colorsheet "Colorsheet Tree Normal.png" \
    --output assets/environment/trees \
    --category tree
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

import numpy as np
import trimesh
from PIL import Image
from trimesh.transformations import rotation_matrix


def slugify(name: str) -> str:
    s = re.sub(r"\.(dae|fbx)$", "", name, flags=re.IGNORECASE)
    s = re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_").lower()
    return s


def z_up_to_y_up() -> np.ndarray:
    r = rotation_matrix(-np.pi / 2.0, [1.0, 0.0, 0.0])[:3, :3]
    m = np.eye(4)
    m[:3, :3] = r
    return m


def ground_align(scene: trimesh.Scene) -> None:
    bounds = scene.bounds
    dy = -float(bounds[0][1])
    if abs(dy) < 1e-6:
        return
    m = np.eye(4)
    m[1, 3] = dy
    scene.apply_transform(m)


def apply_colorsheet(scene: trimesh.Scene, sheet_path: str) -> None:
    img = Image.open(sheet_path)
    mat = trimesh.visual.material.PBRMaterial(
        baseColorTexture=img,
        metallicFactor=0.0,
        roughnessFactor=0.9,
    )
    for geom in scene.geometry.values():
        geom.visual = trimesh.visual.TextureVisuals(material=mat)


def convert_one(src: str, dst: str, sheet_path: str) -> None:
    scene = trimesh.load(src, force="scene")
    scene.apply_transform(z_up_to_y_up())
    ground_align(scene)
    apply_colorsheet(scene, sheet_path)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    scene.export(dst)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="Directory of .dae files")
    p.add_argument("--textures", required=True, help="Directory containing colorsheet PNGs")
    p.add_argument("--colorsheet", required=True, help="Colorsheet filename inside --textures")
    p.add_argument("--output", required=True, help="Output directory for .glb files")
    p.add_argument("--category", required=True, help="Catalog category prefix (tree, cliff, road, ...)")
    p.add_argument("--catalog", default="", help="Optional path to merge into scenery_catalog.json")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    in_dir = os.path.abspath(args.input)
    tex_dir = os.path.abspath(args.textures)
    out_dir = os.path.abspath(args.output)
    sheet_path = os.path.join(tex_dir, args.colorsheet)
    os.makedirs(out_dir, exist_ok=True)

    if not os.path.isfile(sheet_path):
        raise FileNotFoundError(sheet_path)

    # Copy colorsheet beside GLBs so Godot resolves the embedded texture path on re-import.
    sheet_dst = os.path.join(out_dir, args.colorsheet)
    shutil.copy2(sheet_path, sheet_dst)

    dae_files = sorted(f for f in os.listdir(in_dir) if f.lower().endswith(".dae"))
    if not dae_files:
        raise SystemExit(f"no .dae in {in_dir}")

    entries: dict[str, dict] = {}
    for fname in dae_files:
        stem = slugify(fname)
        sid = f"{args.category}_{stem.removeprefix(args.category + '_')}" if stem.startswith(args.category) else f"{args.category}_{stem}"
        src = os.path.join(in_dir, fname)
        dst = os.path.join(out_dir, f"{sid}.glb")
        convert_one(src, dst, sheet_path)
        display = fname.replace(".dae", "")
        rel = os.path.relpath(dst, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
        entries[sid] = {
            "id": sid,
            "category": args.category,
            "name": display,
            "path": "res://" + rel.replace(os.sep, "/"),
        }
        print(f"OK {fname} -> {dst}")

    if args.catalog:
        catalog_path = os.path.abspath(args.catalog)
        existing: dict = {}
        if os.path.isfile(catalog_path):
            with open(catalog_path, encoding="utf-8") as f:
                existing = json.load(f)
        items: dict = existing.get("items", {})
        items.update(entries)
        existing["items"] = dict(sorted(items.items()))
        os.makedirs(os.path.dirname(catalog_path), exist_ok=True)
        with open(catalog_path, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2)
            f.write("\n")
        print(f"catalog -> {catalog_path} ({len(entries)} added)")


if __name__ == "__main__":
    main()
