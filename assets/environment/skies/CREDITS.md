# Sky HDRIs — provenance

## qwantani_sunset_puresky_4k.hdr  (ACTIVE sky — client Environment)
- **Source:** Poly Haven — https://polyhaven.com/a/qwantani_sunset_puresky
- **Licence:** CC0 (public domain; no attribution required — credited here as courtesy)
- **Authors:** Greg Zaal (photography), Jarod Guest (processing)
- **Resolution:** 4K Radiance HDR (`.hdr`), ~17 MB
- **Variant:** "Pure Sky" — sky-only (no baked ground geometry), wraps cleanly as a skybox dome.
- **Use:** authored golden-hour sky for the client Environment (`client/client.tscn`), wired as a
  `PanoramaSkyMaterial`. The `DirectionalLight3D` is aimed at this HDRI's sun (azimuth ~36.5°,
  elevation lifted to ~22° for readable shadows). Client-only presentation (AGENTS.md §7).
- **Selection:** chosen 2026-07-07 over Belfast Sunset (too overcast/low-contrast) and Rosendal
  Park Sunset (too high-contrast) after a real-GPU A/B on conquest_town.
