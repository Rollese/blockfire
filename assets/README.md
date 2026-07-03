# Assets

The M7 art kit started **procedurally generated in GDScript** (`client/art/*_kit.gd`) — welded
primitive boxes built at runtime, sized to the sim's real dimensions, unit-tested headlessly. As P2
progresses, individual categories are being swapped for **imported low-poly GLB models** behind the
same kit interfaces (the procedural kit remains the fallback). Visual sign-off is the owner's
playtest; geometry is unit-tested headlessly. See `docs/specs/art-pipeline.md`.

## Imported models (all CC0 — public domain, no attribution required; credited as courtesy)

- **`characters/`** — Kenney "Blocky Characters" (CC0, kenney.nl). Node-transform animated; loaded by
  `client/art/glb_character_kit.gd`, behind the `use_model_characters` setting.
- **`weapons/`** — Broken Vector "Weapons Pack V.1" (commercial, [brokenvector.com](https://www.brokenvector.com/game-assets/)).
  Converted from OBJ with `tools/obj_to_glb.py` (`assault_rifle.glb` = AR, `submachine_gun.glb` = SMG,
  `sniper_rifle.glb` = DMR, `pistol.glb` = PISTOL). Loaded by `client/art/glb_weapon_kit.gd`, normalized
  to a common length and forward axis. RPG has no model in this pack, so it falls back to procedural `WeaponKit`.
- **`environment/`** — Broken Vector scenery packs (commercial, itch.io). Converted with `tools/dae_to_glb.py`
  (Collada) and `tools/blender_fbx_to_glb.py` (FBX static vehicles). Catalog: `data/scenery_catalog.json`,
  factory: `client/art/scenery_kit.gd`. Map authors place via `scenery` in `maps/*.json`.
  - `trees/`, `rocks/` — foliage and boulders
  - `cliffs/` — cliff/rock tiles for terrain edges
  - `roads/` — modular road/highway/tunnel pieces + wrecked `road_car_*` props
  - `storage/` — barrels, crates, containers, cabinets, etc.
  - `vehicles_static/` — decorative parked cars, trucks, bus (not driveable sim vehicles)
  - `props/` — weapon ammo boxes and other vertex-colored props (no palette swap)
  Map-wide `scenery_palette` keys: `tree`, `rock`, `cliff`, `road`, `road_car`, `storage`, `vehicle_static`.
  Per-instance `"palette"` overrides the map default for that prop's category.
