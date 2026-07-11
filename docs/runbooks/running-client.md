# Runbook: running the rendered client (M7 P1 — Checkpoint 1)

The M7-C1 **rendered first-person infantry client**: deploy → move/look → fire/reload (predicted ammo)
→ kill/die/redeploy → capture, with the core HUD. Placeholder primitives (the low-poly art kit is
P2). The client is a **view + predictor + intent-sender** — it owns no authority (AGENTS.md §7); the
server on game2 decides everything.

Requires **Godot 4.7.x** on `PATH` (verified on 4.7.stable). First run on a fresh checkout:
```
godot --headless --path . --import
```

## Topology (the normal playtest split)

- **Dedicated server + bots: headless on game2** (14900KS / CachyOS — `192.168.1.166` on the LAN).
- **Rendered client: the owner's desktop** (display + GPU), connecting over LAN with `--connect=<game2-ip>`.

Sub-ms LAN latency — prediction/interpolation are barely exercised, which is the point for a first
feel pass. (Loopback also works: run server, bots, and client on one box with `--connect=127.0.0.1`.)

## 1. On game2 — start the server + bots (headless)

Server (authoritative, 30 Hz; runs until killed):
```
godot --headless --path . -- --server --port=27015
```

Bots (one process, N real client connections; they auto-deploy and play Conquest):
```
godot --headless --path . -- --bots --bot-count=8 --connect=127.0.0.1 --port=27015
```
Bots send `HELLO.auto_deploy=true` (the default), so they spawn and respawn automatically and keep a
match running for you to drop into. A handful (6–8) is plenty for a feel pass.

**Spawn the human with an RPG (destruction testing):** add **`--human-rpg`** to the **server**. By
default humans never roll Engineer (the RPG-primary loadout has no click-fire gun); this flag forces
every manual-deploy (human) player to spawn **Engineer + RPG** so you can blow up buildings/structures
(LMB fires the rocket). Bots are unaffected. Engineers also carry C4 or a claymore by id parity.

**Fast destruction testing (no cooldowns):** two **server** flags let a playtester level a building in
seconds instead of waiting out cooldowns —
- **`--fast-nades`** — drops the grenade throw cooldown from 10 s to ~1 tick, so spamming **G** rains
  frags. Frags damage building structure; a wall comes down in a handful of throws.
- **`--fast-rpg`** — the RPG fires with no cooldown and never depletes its rockets (pair with
  `--human-rpg` so the human actually carries one). Hold LMB to demolish.

Both are QA-only convenience flags (bots unaffected); leave them off for balance/gate runs.

**Checkpoint-3 feel-pass tips (added 2026-06-17):**
- Use the small **`--map=conquest_dev_arena`** (one objective, 60 m) for a tight infantry test instead
  of the sprawling default `conquest_proving_grounds` — pass `--map=conquest_dev_arena` to the **server,
  bots, AND client** (they must match). The arena now also carries a transport per team.
- The server **exits at match end** (a team's tickets hit 0), which disconnects the client (grey
  "connecting…" screen = dead server, not an import bug). For a long uninterrupted session bump
  **`--tickets=2000 --time-limit=3600`** on the server, or just restart it when it ends.
- New C3 keys: **G** throw grenade/RPG · **B** cycle throwable · **H** gadget · **U** squad menu (while
  alive) · **R** reload · **F** revive (hold) / enter vehicle / interact.

## 2. On the desktop — run the rendered client

```
godot --path . -- --connect=192.168.1.166 --port=27015 --name=YourName
```
Replace the IP with game2's current LAN address. The client sends `HELLO.auto_deploy=false`, so it
opens on the **deploy screen** instead of auto-spawning.

**Renderer:** Forward+ (Vulkan) by default, GL Compatibility fallback for weaker GPUs
([ADR-0005](../adr/0005-client-renderer.md)). The fallback toggle persists in the settings file
(`renderer_fallback`); flip it in the Settings menu (Esc) if Vulkan misbehaves, then relaunch.

**Skip the deploy screen (testing convenience):** add `--deploy=<ref>` to auto-send one
`DEPLOY_REQUEST` at the chosen spawn (`0` = HQ; `i` = the i-th owned capture point). Used by the
headless connect-smoke; handy for quick iteration.
```
godot --headless --path . -- --connect=127.0.0.1 --port=27015 --deploy=0 --name=Smoke
```

## Controls (BattleBit-style defaults — hud-ui.md; rebinding is P2)

| Action | Key | Action | Key |
|---|---|---|---|
| Move | WASD | Reload | R |
| Sprint | Shift | Interact | F |
| Jump | Space | Scoreboard | Tab (hold) |
| Crouch | Ctrl | Menu / deploy-back | Esc |
| Prone | X | Fire / ADS | LMB / RMB |
| Lean L/R | Q / E | Look | mouse |

Esc toggles the settings menu and releases the mouse; the mouse is captured while deployed.

## 3. Checkpoint-1 playtest checklist (owner)

Connect from the desktop to game2 and verify the core loop:
1. **Deploy** — pick a spawn (HQ or an owned point) → you appear there.
2. **Move** — walk / sprint / jump / crouch / prone / lean; mouse-look responds, pitch clamps.
3. **Fire / reload** — ammo counts down, reload refills (predicted), recoil + tracer/muzzle.
4. **Kill a bot** — hitmarker / kill-confirm.
5. **Take damage** — red vignette + directional arc toward the shooter (no health numbers, by design).
6. **Die → redeploy** — deploy screen returns; the spawn list reflects currently-owned points.
7. **Capture** — stand on a point → capture progress + ticket counts on the HUD.
8. **Compass** — objective/flag bearings show on the top strip.

Judge it **playable + BattleBit-feeling**. Feel issues (look sign/sensitivity, move-vs-camera basis,
recoil, reconciliation smoothness, HUD layout) are logged as **follow-ups, not C1 blockers** — the
deterministic mechanics are already proven headless (AGENTS.md §10). Note in particular: the
input-controller look/move **sign convention** is left as a playtest knob (Task 20) — if forward or
look is mirrored, that's the first dial to turn.

## What is NOT in C1 (don't expect it)

Vehicles (Checkpoint 2); DBNO/revive UI, gadgets/grenades/building UI, squad list, TAB scoreboard
(Checkpoint 3); the real art kit + LOD + audio polish (P2); rebindable keys (P2). Reserve ammo is
the sim's current "reload refills full mag, infinite reserve".

## Headless validation (already green — what the agent proved without a display)

- Full unit suite: `godot --headless --path . -- --test` (DeploySpawn, protocol codecs,
  WeaponPredictor, prediction/reconcile, all HUD-model logic, input map, stance pose, settings,
  world-view interpolation, input actions).
- Server-edge regression: `ci/m5_p1_test.sh` (the ≤48-bot smoke) — the new `DEPLOY_REQUEST` /
  `DAMAGE_EVENT` / `SELF_STATE` / `HELLO.auto_deploy` messages don't regress the server tick.
- End-to-end wiring: a headless server+client connect (`--deploy=0`) reaches WELCOME → deploy →
  snapshots with no errors.

Rendering, gunplay/movement feel, and HUD readability are **only** validated by this playtest.
