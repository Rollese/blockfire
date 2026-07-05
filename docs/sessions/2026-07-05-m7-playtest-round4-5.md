# Session log — 2026-07-05 — M7 desktop playtest rounds 4–5

Owner-driven live playtest of the M7 rendered client on the desktop (192.168.1.194,
CachyOS/Wayland/RX 9070 XT), client driven over SSH; server + bots on game2. All work
landed on branch **`playtest-fixes-m7-round2`** (pushed to origin, **NOT merged to
master** — awaiting the owner's overall playtest sign-off, which is the M7 gate).
Suite **1256/0** at session end.

## ⚠️ Handoff notes for a concurrent/next agent (read first)

- **Do not disturb `playtest-fixes-m7-round2`.** It carries unmerged round-3 + round-4/5
  playtest fixes and merges to `master` only after the owner signs off the playtest.
  If you work on **other features**, branch from **`master`** (not this branch), and
  `git fetch` + reconcile before any push — sessions share this repo.
- **Run the server/bots in detached `tmux`** (`tmux new-session -d -s bf-srv "… --server …"`
  / `-s bf-bots "… --bots …"`). Session-bound `run_in_background` Bash tasks get
  **SIGKILLed when the Claude session tears down** — that killed the server mid-playtest
  this session, and Godot's SIGKILL-on-exit prints a **benign segfault** the owner saw
  (it is NOT a game crash). Never `tmux kill-server`/`pkill tmux`; use `pkill -x godot`.
- **Wire change this session:** `SELF_STATE` gained a trailing **regen-cooldown** byte
  (owner-only, back-compat via the `get_available_bytes` guard, u8 normalized to
  `STAMINA_REGEN_DELAY`). Current SELF_STATE trailing order is
  `… stamina, vel_y, grounded, vaulting, vault_tick, regen_cooldown`. Preserve it if you
  touch `encode_self_state`/`decode_self_state`/`reconcile_full`. (Trailing-optional, so no
  `Protocol.VERSION` bump — same pattern as the round-4 vault bytes.)
- Launch the playtest client with **no `--connect`** so it boots to the main menu →
  Server Browser → Join **"LAN — game2"** (that entry already exists in
  `client/menus/server_browser.gd`). Live ping / player-count in the browser is an unbuilt
  **M9** master-server feature, not a bug.

## Changes landed (commits on `playtest-fixes-m7-round2`)

| Commit | Type | Summary |
|---|---|---|
| `68c2d55` | fix(net) | `NetHost.poll()` re-entered `_host.service()` after a disconnect handler tore the host down → script-error crash on any network hiccup. Loop is now `while _host != null`. |
| `1fec333` | fix(vehicle) | Client zeroed the **driver's steering axes** before send → couldn't drive. Now forwards them (seated pawn is slaved server-side; safe). Mounted gun is server-AUTO-fire — no manual turret yet. |
| `5ceff22` | feat(movement) | **Manual vault** (BattleBit): humans press jump to vault; bots keep auto-vault (new `Pawn.auto_vault`, server sets false for humans, client prediction false — fleet `vaults>=1` preserved). Jump→vault cancels the jump impulse/stamina. |
| `7df10a3` | fix(grenade) | Frag + smoke **bounce off structures** instead of tunnelling through walls (`StructureStore.march_normal` + velocity reflect, restitution 0.45). Impact grenades already collided. |
| `3dc715a` | fix(net) | **C6 stamina reconcile**: SELF_STATE carries the stamina regen-cooldown; `reconcile_full` resets `predicted._regen_cooldown`. Fixes the jump-apex + empty-sprint (~1 Hz) snap that lived at the stamina boundaries. |
| `4c0bf54` | feat(hud) | Slim white **stamina bar**, bottom-centre, shown only when stamina < full (there was no stamina UI). |
| `3ba8105` | fix(client) | Empty grenade slot no longer lobs a **phantom** (gate charge/throw/cosmetic on `count > 0`). |
| `bca2069` | fix(client) | **Reconcile deadzone 0.04 → 0.12** so per-connect prediction-lead jitter (~4–6 cm) uses smooth 30→60 interpolation instead of the `_pos_err` active-ease path. Fixed the moving/sprint micro-snap. |
| `11b1608` | chore(menu) | Corrected the game2 server-browser entry's map label to `conquest_town`. |
| `bc293fd` | chore(client) | Removed the temporary reconcile diagnostics after the lag hunt. |
| `<wip>` | wip(client) | Inert **red-ladder render scaffolding** (`WorldRenderer._make_ladder` + `MapDef` ladder `yaw`) — NOT wired (no setup loop, no town ladders). Starting point for B1/B2. |

(Several `chore … TEMP …` commits between the above were the reconcile-diagnostic
instrumentation used to localize the movement-feel issue; they were reverted by `bc293fd`.)

## Playtest results (owner)

- Confirmed good: melee 2-hit, downed can't nade, disconnect overlay (D2), server-browser
  join (D1/D3), no invisible walls at build sites (C1), revive bar (E1), no bot-park-on-bags (F2/F3).
- Fixed this session and awaiting re-test: vehicle driving (A2), manual vault (B3/B4),
  grenade wall-bounce, C6 stamina snap, empty-slot grenade.
- **Movement feel:** started as "heavily lagging / snaps back several times a second";
  ended **smooth for walking/sprinting**, with the jump apex "barely noticeable" (4–5 very
  rapid, very small corrections at the top).

## Key diagnosis — movement snap (for whoever does the netcode follow-up)

The snap-back is **connection-dependent prediction-lead jitter**, proven by per-reconnect
variation (the reconcile correction was purely *vertical* 0.54 m one join, *horizontal*
0.28 m the next, ~0 another — same code). `_client_tick` is a **local counter that starts
at 0 and just increments** — there is **no explicit tick-lead / jitter-buffer management**,
so the client's prediction lead settles to whatever the server input-buffer depth lands at
each connect. The deadzone widening masks the *feel*; a real fix is **explicit tick-lead
management** (target a small stable lead, adapt smoothly), done deliberately with the fleet
gate — not by live trial-and-error. The residual jump-apex micro-jitter is this lead, most
visible where the pawn hovers at the apex (vel_y ≈ 0). To re-measure, add a temp reconcile
meter (peak correction magnitude/vector/airborne) to the `[client-dbg]` 1 Hz line.

## Deferred / still open

- **B1/B2 — red ladders on two-story buildings.** Scaffolding committed but NOT wired:
  need the `setup()` loop `for ld in map.ladders: add_child(_make_ladder(ld))` **and**
  `ladders` entries in `maps/conquest_town.json` (bottom/top/radius/yaw), verified by
  screenshot. Blocks testing high ground / fall damage / high-wall vaults.
- **Explicit tick-lead netcode** (above) — the root movement-feel fix.
- **Manual vehicle turret** aim/fire (mounted gun is auto-fire only).
