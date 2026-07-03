#!/usr/bin/env python3
"""Batch-convert FBX scenery (Broken Vector static vehicles, etc.) to GLB via Blender.

Usage:
  blender --background --python tools/blender_fbx_to_glb.py -- \\
    --input ~/projects/blockfire-models/static-vehicles/Models \\
    --textures ~/projects/blockfire-models/static-vehicles/Textures \\
    --colorsheet "Palette_Silver.png" \\
    --output assets/environment/vehicles_static \\
    --category vehicle_static \\
    --catalog data/scenery_catalog.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys


def _argv_after_double_dash() -> list[str]:
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1 :]
    return sys.argv[1:]


def slugify(name: str) -> str:
    s = re.sub(r"\.(dae|fbx)$", "", name, flags=re.IGNORECASE)
    s = re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_").lower()
    return s


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--textures", required=True)
    p.add_argument("--colorsheet", default="", help="Optional colorsheet; omit for embedded/vertex materials")
    p.add_argument("--output", required=True)
    p.add_argument("--category", required=True)
    p.add_argument("--catalog", default="")
    return p.parse_args(_argv_after_double_dash())


def main() -> None:
    import bpy  # noqa: PLC0415

    args = parse_args()
    in_dir = os.path.abspath(args.input)
    tex_dir = os.path.abspath(args.textures)
    out_dir = os.path.abspath(args.output)
    sheet_path = os.path.join(tex_dir, args.colorsheet) if args.colorsheet else ""
    os.makedirs(out_dir, exist_ok=True)
    if args.colorsheet and not os.path.isfile(sheet_path):
        raise FileNotFoundError(sheet_path)

    sheet_img = None
    fbx_files = sorted(f for f in os.listdir(in_dir) if f.lower().endswith(".fbx"))
    if not fbx_files:
        raise SystemExit(f"no .fbx in {in_dir}")

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    entries: dict[str, dict] = {}

    for fname in fbx_files:
        src = os.path.join(in_dir, fname)
        stem = slugify(fname)
        sid = (
            f"{args.category}_{stem.removeprefix(args.category + '_')}"
            if stem.startswith(args.category)
            else f"{args.category}_{stem}"
        )
        dst = os.path.join(out_dir, f"{sid}.glb")

        bpy.ops.wm.read_factory_settings(use_empty=True)
        if args.colorsheet:
            sheet_img = bpy.data.images.load(sheet_path, check_existing=True)
        bpy.ops.import_scene.fbx(filepath=src)

        if args.colorsheet:
            for mat in bpy.data.materials:
                mat.use_nodes = True
                nodes = mat.node_tree.nodes
                links = mat.node_tree.links
                nodes.clear()
                out = nodes.new("ShaderNodeOutputMaterial")
                bsdf = nodes.new("ShaderNodeBsdfPrincipled")
                tex = nodes.new("ShaderNodeTexImage")
                tex.image = sheet_img
                links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
                links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
                bsdf.inputs["Roughness"].default_value = 0.9

        bpy.ops.object.select_all(action="DESELECT")
        for obj in bpy.data.objects:
            if obj.type == "MESH":
                obj.select_set(True)
        if not bpy.context.selected_objects:
            print(f"SKIP (no mesh): {fname}")
            continue
        bpy.context.view_layer.objects.active = bpy.context.selected_objects[0]
        if len(bpy.context.selected_objects) > 1:
            bpy.ops.object.join()
        root = bpy.context.selected_objects[0]
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        min_y = min((root.matrix_world @ v.co).y for v in root.data.vertices)
        root.location.y -= min_y
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)

        bpy.ops.export_scene.gltf(
            filepath=dst,
            export_format="GLB",
            export_yup=True,
            export_apply=True,
            export_texcoords=True,
            export_materials="EXPORT",
            export_image_format="AUTO",
        )
        rel = os.path.relpath(dst, repo_root)
        entries[sid] = {
            "id": sid,
            "category": args.category,
            "name": re.sub(r"\.fbx$", "", fname, flags=re.IGNORECASE),
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
        with open(catalog_path, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2)
            f.write("\n")
        print(f"catalog -> {catalog_path} ({len(entries)} added)")


if __name__ == "__main__":
    main()
