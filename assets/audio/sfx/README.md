# SFX assets — sources & licenses

Real recordings replacing the placeholder synth tones in `AudioDirector._gen_tone`. Layout mirrors
the catalog: `data/sounds.json` `stream` values are paths relative to this folder (e.g.
`weapons/gunfire_ar` -> `res://assets/audio/sfx/weapons/gunfire_ar.wav`). New assets are converted
to 48 kHz 16-bit mono (3D voices spatialize mono sources); the three original Snake takes kept
their as-shipped 44.1 kHz stereo since they're owner-playtested.

Sources (both royalty-free for commercial use, no attribution required; local copies live in
`~/projects/blockfire-audio/` on game2):

- **Snake** — "Snake's Authentic Gun Sounds" packs 1+2 (f8studios.itch.io, CC0). Real firearm
  recordings, `Full Sound` = with natural outdoor reverb tail, `Isolated` = dry.
- **WASD Sound** — Free Integrated Footstep SFX Bundle v2 (wasd-sound.itch.io, commercial OK).
  Boots on dirt/grass/stone/wood; we committed dirt walk/run/sneak/land/jump only.
- **Sonniss** — GDC Game Audio Bundle Part 9 (sonniss.com, royalty-free commercial license, see
  `License - GDC Game Audio.pdf` in the bundle).

| asset | event(s) | source take | notes |
|---|---|---|---|
| `weapons/gunfire_ar.wav` | `gunfire` | Snake 1: 5.56 Single | AR + fallback/remote report |
| `weapons/gunfire_smg.wav` | `gunfire_smg` | Snake 2: 9mm Single | |
| `weapons/gunfire_dmr.wav` | `gunfire_dmr` | Snake 2: .308 (7.62x51) Single | replaced the 7.62x54R take — correct FAL/DMR cartridge |
| `weapons/gunfire_pistol.wav` | `gunfire_pistol` | Snake 2: 9mm Single Isolated | dry take reads as handgun vs the SMG's full take |
| `weapons/gunfire_supp.wav` | `gunfire_supp` | Snake 1: .22LR Single Isolated | suppressed-tier report (event not emitted yet) |
| `weapons/bullet_crack.wav` | `bullet_crack` | Sonniss: D. Dumais "WHIP Snap Crack 05" | whip crack = literal supersonic crack |
| `weapons/bullet_whiz.wav` | `bullet_whiz` | Sonniss: D. Dumais blade-swing scrape 14 (0.35 s cut, LP 7 kHz) | flyby zip |
| `foley/reload.wav` | `reload` | Snake 1: AR Reload Full | |
| `foley/melee.wav` | `melee` | Sonniss: D. Dumais blade-swing scrape 14 (1.0 s cut) | own-swing whoosh cue |
| `impacts/impact_concrete.wav` | `impact` | Sonniss: InMotionAudio case-down-on-concrete 12 (0.7 s cut) | bullet thud on world |
| `explosions/explosion.wav` | `explosion` | Sonniss: Ivo Vicic "Fireworks powerful explosions near" (single blast cut @6.6 s) | frag/C4/RPG/vehicle detonations |
| `explosions/flashbang.wav` | `flashbang` | Sonniss: same recording, different blast (@16.5 s) | brighter pop |
| `vehicles/engine_loop.wav` | `engine` | Sonniss: ESM diesel boat idle (8 s cut, tail crossfaded into head) | `.import` sets `edit/loop_mode=2` (forward) — keep that on reimport |
| `ui/hitmarker.wav` | `hitmarker` | Sonniss: CSD "Interface Sci-Fi Ping Down" (0.5 s trim) | |
| `ui/ui_click.wav` | `ui_click` | Sonniss: ESM "Click Deep Mechanism Latch" | |

Still on synth-tone fallback: none — all catalog events have real assets.

### Footsteps (WASD Sound — Free Integrated Footstep SFX Bundle v2)

Royalty-free for commercial use (see `License WASD Sound Bundles.pdf` in the bundle). Boots on dirt;
six round-robin variants per action (`variants` in `sounds.json` → `stream_NN.wav`).

| asset prefix | event(s) | WASD source | in-game use |
|---|---|---|---|
| `footsteps/dirt_walk_01..06` | `footstep_walk` | Dirt Walk | default stride |
| `footsteps/dirt_run_01..06` | `footstep_run` | Dirt Run | sprint (intensity ≥ 0.85) |
| `footsteps/dirt_sneak_01..06` | `footstep_sneak` | Dirt Sneak | crouch locomotion |
| `footsteps/dirt_land_01..06` | `footstep_land` | Dirt Drop | hard landing |
| `footsteps/dirt_jump_01..06` | `footstep_jump` | Dirt Jump | reserved (catalog wired; takeoff not emitted yet) |

`FootstepAudio` maps renderer cadence → event; `AudioDirector` round-robins variants. Stone/grass/wood
materials from the WASD bundle remain in `~/projects/blockfire-audio/` for future surface routing.

`AudioDirector._stream_for()` loads `res://assets/audio/sfx/<def.stream>.wav` (or `_NN.wav` when
`variants` > 1) when present and falls back to the synth tone otherwise (`tools/synth_gunshot.py`
stays as the procedural fallback generator). Unused pack material (bipod, mag packs, racks/chamber
checks, burst/spray variants, 20-gauge, revolvers) remains in `~/projects/blockfire-audio/` for
future wiring — e.g. per-weapon reloads, suppressor mechanic, shotgun.
