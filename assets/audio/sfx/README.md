# Weapon SFX (CC0)

Real firearm samples used in place of the placeholder synth tones in `AudioDirector._gen_tone`.
Sourced from a CC0 (public-domain) weapon-sound pack the owner supplied. CC0 requires no
attribution, but for provenance these are caliber "single shot" + reload takes:

| asset                | event(s)        | source take            | in-game weapon |
|----------------------|-----------------|------------------------|----------------|
| `gunfire_ar.wav`     | `gunfire`       | 5.56 Single            | AR (+ remote)  |
| `gunfire_smg.wav`    | `gunfire_smg`   | 9mm Single             | SMG            |
| `gunfire_dmr.wav`    | `gunfire_dmr`   | 7.62x54R Single        | DMR            |
| `reload.wav`         | `reload`        | AR Reload Full         | all            |

`AudioDirector._stream_for()` loads `res://assets/audio/sfx/<def.stream>.wav` when present and
falls back to the synth tone for any event whose asset isn't authored yet (crack/whiz/impact/
footstep/explosion/engine/flash/melee/hitmarker/ui_click). The full CC0 pack (bipod, mag-pack,
per-weapon racks/chamber-checks, burst/spray variants) lives on the laptop at `~/projects/blockfire/sounds/`
for future wiring.
