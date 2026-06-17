# Assets

The M7 art kit is **procedurally generated in GDScript** (`client/art/*_kit.gd`), not authored
in a DCC tool. There are intentionally no `.glb`/`.obj` files here — the low-poly blocky look is
welded primitive boxes built at runtime, sized to the sim's real dimensions. Visual sign-off is
the owner's playtest of the preview scenes (`client/art/preview/`); geometry is unit-tested
headlessly. See `docs/plans/2026-06-17-m7-p2-art-kit-procedural.md`.
