# M16 — standing-bleed + bandage (2026-07-09)

Autonomous session. Executed the long-deferred **M16 standing-bleed + bandage** feature — a
complete owner-ratified spec (`docs/superpowers/specs/2026-07-03-standing-bleed-bandage-design.md`)
whose brainstorm/design was done but implementation had never started (the plan was reportedly lost
to a worktree reclaim, per the `d5f7225` AGENTS §11 note). Pure sim/server core proven
deterministically; **client visual *feel* (dedicated vignette / blood VFX / final cast-bar art)
deferred to owner playtest** per the spec — so no screenshots required.

## What it is (BattleBit survivability loop)
A non-lethal **bullet/blast** hit that leaves you below **60 HP** starts a **standing bleed** draining
the main `health` pool at ~5 HP/s. It ends only when **bandaged** — self or teammate — via a **timed
all-or-nothing channel** (5 s; medic 2.5 s) that also restores **25 HP**. An ignored bleed drains to
0 and routes into the existing **DBNO halving-bleedout** (counts as a down, shrinks the next window).
**Medic** bandages 2× faster and carries **20** charges (was 5). The `bandage` item finally has a
consumer; **revive now also spends one** (victim-first → helper), so dry bots stop revive-looping.

## Reconciliation (the spec pre-dated the merge of the concurrent halving-bleedout branch)
The halving-bleedout rework has since landed on master, so the spec's interaction contract holds as
written: standing bleed-out calls the existing `_down_pawn` / `bleedout_window(down_count+1)` / kill
routing via the shared `Revive` helpers, never reimplementing the halving formula. Wire ids shifted
(`COLLAPSE_WARNING` took 45): **BANDAGE_ACTION = 46, BLEEDING_LIST = 47**, `Protocol.VERSION` 4→5.

## Implementation
- **shared/sim/bleed.gd**, **shared/sim/bandage.gd** — pure rules (`should_start`, `drain_this_tick`;
  `channel_ticks`, `pick_source`). `MEDIC_BANDAGE_COUNT := 20` replaces `MEDIC_EXTRA_BANDAGES`.
- **pawn.gd** — `bleeding` / `bleed_by` / `bleed_weapon` (+ spawn/respawn reset; cleared on down/revive).
- **server_main.gd** — `_apply_pawn_damage` bleed trigger + bandage damage-interrupt; `_bleed_out_standing`
  (mirrors the death branch); `_broadcast_bleeding_list` (ally-only, per-team — a bleeding enemy would
  be a wallhack); SELF_STATE gains `bleeding` + `bandage_progress`.
- **server/support.gd** — `step_bleed`, `step_bandage` (all-or-nothing channel with sprint/fire/range/
  damage hard-cancel), `handle_bandage_action`, `cancel_bandages_involving`, `bandage_progress_u8`;
  **revive-costs-a-bandage** gate in `step_revives` + `complete_revive(target, reviver)`.
- **bots/bot_driver.gd** — a safe (no visible enemy) bleeding bot holds still and self-bandages via
  `BANDAGE_ACTION` (fair-play: reads only its own SELF_STATE.bleeding). This is what exercises the gate.
- **client** — decode bleeding/progress + BLEEDING_LIST; interaction resolver offers "Hold F to
  bandage squadmate" (bleeding mate in range) / "Hold F to bandage" (self, no world prompt); F latches
  BANDAGE_ACTION and the reused revive hold-bar mirrors the server bandage_progress.
- **stats.gd** — `bleeds` / `bandages` / `bleeddowns` in the telemetry line.

## Wire (bumped `Protocol.VERSION` 4→5; `docs/specs/wire-protocol-registry.md` updated)
- **46 BANDAGE_ACTION** (c→s), **47 BLEEDING_LIST** (s→h), SELF_STATE +`bleeding` bit +`bandage_progress` u8.
- Also backfilled the missing **45 COLLAPSE_WARNING** registry row (enum had it, doc didn't).

## Tests (deterministic — AGENTS.md §10)
`tests/bleed_test.gd`, `tests/bandage_test.gd`, `tests/protocol_bandage_test.gd`,
`tests/server_bleed_test.gd` (trigger, drain→down, bandage stop+heal+victim-first pouch, self-bandage,
mid-channel damage reset, dry-bandage no-op, dry-revive fail, revive spends a bandage). Suite **1437/0**;
connect smoke PASS (VERSION 5 handshake clean).

## Fleet gate (128-bot, conquest_town, game2) — PASS
`docs/gate-evidence/20260709-234921-m16-bleed2.txt` (git `afb3880`): `winner=1 elapsed=158s peak
tick=23.83ms<33.3 agg=23.7Mbit/s players=128 kills=23 cap_events=1`, 0 errors. Every M16 stat
exercised emergently: **bleeds=12, bandages=2, bleeddowns=3** (+ revives=5 — the revive-costs-a-
bandage gate still lets revives complete). No tick-budget regression (23.83ms vs the M15 ~24ms baseline).

The first run (`20260709-234322-m16-bleed.txt`, TICKETS default) was an 83s steamroll: bleeds=9 /
bleeddowns=4 but bandages=0 — a bleeding bot almost never got a 5 s window with *zero* visible
enemies. Loosened the bot self-bandage "safe" condition to *no enemy within 18 m* (`BANDAGE_SAFE_DIST`;
a wounded bot patches up behind cover while distant threats exist, as a human would) and re-ran at
TICKETS=200 → bandages=2. Bandage completion was already proven deterministically
(`server_bleed_test.gd`); this makes the fleet exercise it emergently too.

## Deferred (owner playtest / follow-up)
- Client **feel**: dedicated red bleeding vignette, remote blood-drip VFX, final cast-bar art + keybind
  tuning (spec §"Out of scope" — owner-gated at playtest). Wire + input + a functional reused cast-bar
  are in; only the presentation curves remain.
- Bot **teammate**-bandage: bots self-bandage (their own SELF_STATE) but can't see a mate's bleed
  (bleeding isn't in the snapshot EntityState, only owner-SELF_STATE + ally BLEEDING_LIST which bots
  don't receive). The human path fully supports teammate-bandage; the gate proves the mechanic via
  self-bandage + natural bleed-outs. Widening bot bleed-visibility is a fair-play follow-up if wanted.
