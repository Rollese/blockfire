# Assets

The M7 art kit started **procedurally generated in GDScript** (`client/art/*_kit.gd`) — welded
primitive boxes built at runtime, sized to the sim's real dimensions, unit-tested headlessly. As P2
progresses, individual categories are being swapped for **imported low-poly GLB models** behind the
same kit interfaces (the procedural kit remains the fallback). Visual sign-off is the owner's
playtest; geometry is unit-tested headlessly. See `docs/specs/art-pipeline.md`.

## Imported models (all CC0 — public domain, no attribution required; credited as courtesy)

- **`characters/`** — Kenney "Blocky Characters" (CC0, kenney.nl). Node-transform animated; loaded by
  `client/art/glb_character_kit.gd`, behind the `use_model_characters` setting.
- **`weapons/`** — Quaternius "Ultimate Guns Pack" (CC0, quaternius.com / poly.pizza). Only the GLBs
  mapped to the `Weapon` enum are committed (`assault_rifle.glb` = AR, `submachine_gun.glb` = SMG,
  `sniper_rifle.glb` = DMR); loaded by `client/art/glb_weapon_kit.gd`, normalized to a common length
  and forward axis. RPG has no model in this pack, so it falls back to the procedural `WeaponKit`.
- **`environment/trees/`**, **`environment/rocks/`** — Broken Vector low-poly tree and rock packs
  (commercial license from [brokenvector.com](https://www.brokenvector.com/game-assets/); purchased via
  itch.io). Converted from Collada to GLB with `tools/dae_to_glb.py`; catalog in
  `data/scenery_catalog.json`, loaded by `client/art/scenery_kit.gd`. Map authors place instances via
  the optional `scenery` array in `maps/*.json` (`id`, `pos`, optional `yaw`/`scale`).
