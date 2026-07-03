#!/usr/bin/env python3
"""Copy Broken Vector palette PNGs into assets and register paths in scenery_catalog.json."""
from __future__ import annotations

import json
import os
import shutil

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MODELS = os.path.expanduser("~/projects/blockfire-models")
CATALOG = os.path.join(REPO, "data/scenery_catalog.json")

# (category, source_dir, [(short_name, source_filename), ...])
PALETTES = [
    (
        "cliff",
        "cliffs/Textures",
        [("grey", "Colorscheme Grey.png"), ("red", "Colorscheme Red.png"), ("yellow", "Colorscheme Yellow.png")],
    ),
    (
        "road",
        "roads/Textures",
        [("road", "Road Colorscheme.png")],
    ),
    (
        "road_car",
        "roads/Textures",
        [("car_1", "Car Colorscheme 1.png"), ("car_2", "Car Colorscheme 2.png")],
    ),
    (
        "storage",
        "storage/Palettes",
        [
            ("blue", "Palette_Blue.png"),
            ("green", "Palette_Green.png"),
            ("purple", "Palette_Purple.png"),
            ("red", "Palette_Red.png"),
            ("yellow", "Palette_Yellow.png"),
        ],
    ),
    (
        "vehicle_static",
        "static-vehicles/Textures",
        [
            ("blue", "Palette_Blue.png"),
            ("green", "Palette_Green.png"),
            ("purple", "Palette_Purple.png"),
            ("red", "Palette_Red.png"),
            ("silver", "Palette_Silver.png"),
            ("yellow", "Palette_Yellow.png"),
        ],
    ),
]

DEFAULTS = {
    "cliff": "grey",
    "road": "road",
    "road_car": "car_1",
    "storage": "blue",
    "vehicle_static": "silver",
}


def main() -> None:
    with open(CATALOG, encoding="utf-8") as f:
        data = json.load(f)
    palettes: dict = data.setdefault("palettes", {})
    defaults: dict = data.setdefault("defaults", {})

    for category, rel_dir, entries in PALETTES:
        out_dir = os.path.join(REPO, "assets/environment", category.replace("_", "-") if category == "vehicle_static" else category + ("s" if category in ("tree", "rock") else ""), "palettes")
        # fix paths: cliff->cliffs? use consistent folder names matching output
        folder_map = {
            "cliff": "cliffs",
            "road": "roads",
            "road_car": "roads",
            "storage": "storage",
            "vehicle_static": "vehicles_static",
        }
        folder = folder_map[category]
        out_dir = os.path.join(REPO, "assets/environment", folder, "palettes")
        os.makedirs(out_dir, exist_ok=True)
        group: dict = palettes.setdefault(category, {})
        for short, src_name in entries:
            src = os.path.join(MODELS, rel_dir, src_name)
            dst = os.path.join(out_dir, f"{short}.png")
            shutil.copy2(src, dst)
            rel = os.path.relpath(dst, REPO).replace(os.sep, "/")
            group[short] = f"res://{rel}"
            print(f"palette {category}/{short} -> {rel}")
        defaults[category] = DEFAULTS[category]

    data["palettes"] = palettes
    data["defaults"] = dict(sorted(defaults.items()))
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"updated {CATALOG}")


if __name__ == "__main__":
    main()
