# M19 P3: Client class-select / loadout screen

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Give humans the BattleBit-faithful deploy loadout screen (spec §G): pick class → primary (+attachments) → armor → grenade → 1-of-3 gadget, with an always-visible passive-perk panel generated from `Loadout.trait_blurbs`; on any change the client locally sanitizes and sends `Msg.SET_LOADOUT`. This lights up all the now-inert client gadget plumbing from P1b/P2 (STIM/BREACH/REPAIR/SMOKE_WALL/RPG-gadget become reachable by real players).

**Architecture:** Two layers. (1) **Logic core** in `client_main`: a stored local loadout `_loadout` (seeded from `Loadout.default_loadout`), a `_send_loadout()` that `Loadout.sanitize`s it and emits `SET_LOADOUT`, and rerouting the existing `Loadout.default_gadget(_my_class)`/equipped-gadget reads to read `_loadout["gadget"]`. (2) **UI** `ClassSelectPanel` (`client/menus/`) that renders the option lists from `Loadout` + `trait_blurbs`, edits `_loadout`, and calls back to `_send_loadout()`; wired into `deploy_menu.gd` (resolves its "move to a class-select screen when that exists" TODO). Server side (`SET_LOADOUT`=48, store-and-apply-at-spawn) already exists and is gate-proven — P3 is client-only.

**Tech Stack:** Godot 4 GDScript UI (Control nodes, built in code like the sibling menus). Options/validation come from `shared/sim/loadout.gd` (already the single authority): `primary_options(cls)`, `gadget_options(cls)`, `allowed_archetypes(cls)`, `trait_blurbs(cls)`, `default_loadout(cls)`, `sanitize(cfg, attach)`. Wire `Protocol.encode_set_loadout(cfg)`. Visual QA via real-GPU screenshots (llvmpipe unreliable for UI colour — memory `blockfire-game2-screenshot-xvfb` / `blockfire-m7-client-playtest-hosts`).

**Key facts (verified):**
- `client/menus/` builds menus in code: `deploy_menu.gd`, `main_menu.gd`, `player_menu.gd`, `settings_menu.gd`, `welcome_panel.gd`. `deploy_menu.gd:66` has the class-select TODO.
- `client_main.gd:~1157` documents the seam: today `equipped_gadget := Loadout.default_gadget(_my_class)` because "a human connection never sends SET_LOADOUT". `_my_class` is set from WELCOME. There are now multiple `default_gadget(_my_class)` reads (gadget input branch) to reroute.
- `Protocol.encode_set_loadout(cfg)` serializes `class/primary/secondary/gadget/armor/grenade` (u8 each) + 3 attachment strings (`optic/barrel/underbarrel`). `Loadout.default_loadout(cls)` returns exactly that dict shape (+`secondary`,`attachments`).
- `Loadout.sanitize(cfg, attach)` needs the `Attachment` catalog — grep how the client loads it (the client already has an `Attachment` instance for weapon stats; reuse it). `sanitize` is total + idempotent (never returns invalid).
- `Loadout.trait_blurbs(cls)` (loadout.gd:185) already returns the full plain-language perk list per class (Combat Vigor, Field Medic, Demolitions +20% blast, Ammo Hauler, DMR/LMG access…). USE IT — do not hand-write perk strings.
- Armor speed/dmg numbers live in `Armor` (grep `Armor.speed_mult`/`Armor.body_mult` or an armor table) for the self-documenting armor picker lines.
- Weapon display names: `Weapon.display_name(id)` (from the variants registry). Grenade names: `client/hud/hud_view.gd` has a `{0:"Frag",1:"Smoke",...}`-style map already.

**Scope (do NOT do here):** No new server/sim/wire (all exists). No LMG-Nest/Grapple/Riot/Sandbag selectability changes. Keep the spawn/deploy buttons' existing behavior (deploy uses the last-sent loadout). STIM teammate-inject + STIM HUD charge readout remain deferred (separate follow-ups). Do not touch the server.

---

## Task 1: Client stored loadout + SET_LOADOUT send + reroute equipped-gadget reads

**Files:** `client/client_main.gd`; Test: extend a client-facing test if one exists (grep `tests/` for `client`), else rely on the connect-smoke + a small pure test of the send path.

- [ ] **Step 1:** Read `client_main.gd`: where `_my_class` is set (WELCOME handler), the `default_gadget(_my_class)` read(s), and where the client has an `Attachment` catalog instance. Confirm the client's tick/`_net` send helper.
- [ ] **Step 2 (test):** Add a headless test `tests/client_loadout_send_test.gd` if feasible: construct the loadout dict, `Loadout.sanitize` it, `Protocol.encode_set_loadout` → `decode_set_loadout` round-trips the chosen class/primary/gadget/armor/grenade. (This proves the config→wire path the client will use; the UI is exercised by connect-smoke.)
- [ ] **Step 3 (implement):**
  - Add `var _loadout: Dictionary = {}` and initialise it on WELCOME: `_loadout = Loadout.default_loadout(_my_class)` (or the persisted one if the client caches across matches — start with default).
  - Add `func _send_loadout() -> void:` — `_loadout = Loadout.sanitize(_loadout, <attach catalog>); _net.send(... Protocol.encode_set_loadout(_loadout) ...)` reliably (mirror an existing reliable client send). Call it once on WELCOME (so the server has the client's real loadout immediately) and whenever the panel changes it (Task 3).
  - Reroute the gadget-input reads: replace `Loadout.default_gadget(_my_class)` with `int(_loadout.get("gadget", Loadout.default_gadget(_my_class)))`. Update the stale comment at ~1157.
- [ ] **Step 4:** `godot --headless --import --path .`; run `ci/connect_smoke_test.sh` (PASS) + full `--test` (0 failures). The connect-smoke should now show the client sending SET_LOADOUT once on join.
- [ ] **Step 5:** Commit `feat(m19-p3): client stores a loadout, sends SET_LOADOUT on join, routes gadget input off it`.

---

## Task 2: `ClassSelectPanel` — the pickers (data-driven from Loadout)

**Files:** Create `client/menus/class_select_panel.gd` (Control built in code, mirror the structure of an existing menu like `player_menu.gd`); Test: none (UI) — verify by instancing headlessly + connect-smoke.

- [ ] **Step 1:** Read `client/menus/player_menu.gd` (or the simplest sibling) for the code-built-Control idiom (VBox/HBox, Buttons, signal wiring, theming, how it's shown/hidden).
- [ ] **Step 2 (implement):** `ClassSelectPanel extends Control` (or PanelContainer). It holds a working copy of the loadout dict and emits a `loadout_changed(cfg: Dictionary)` signal on any edit. Sections, each a labelled row of selectable buttons:
  - **Class** (4): Assault/Medic/Engineer/Support. Changing class re-seeds primary/gadget/armor to that class's defaults (via `Loadout.default_loadout(cls)`), then re-runs the perk + option refresh.
  - **Primary**: buttons from `Loadout.primary_options(cls)`, labelled `Weapon.display_name(id)`.
  - **Attachments** (optic/barrel/underbarrel): options from the attachment catalog for the chosen primary (grep how weapon stats screen or `Attachment` exposes per-slot options; if none, show the 3 slots with the current value + a cycle button).
  - **Armor** (L/M/H): each button shows the self-documenting line (e.g. "Light — +20% speed, least protection" … "Heavy — −20% speed, most protection") pulled from the `Armor` numbers.
  - **Grenade** (Frag/Smoke/Flash): labelled from the grenade name map.
  - **Gadget**: buttons from `Loadout.gadget_options(cls)` **filtered to `IMPLEMENTED_GADGETS`** (unbuilt options greyed/hidden per spec), each with a one-line effect.
  - After building the working cfg from selections, run `Loadout.sanitize(cfg, attach)` and reflect the sanitized result (grey-out illegal combos) before emitting `loadout_changed`.
- [ ] **Step 3:** Add a headless instantiation check (a tiny test or a `--check`/import) confirming the script parses + `.new()` builds without error. Full `--test` still green.
- [ ] **Step 4:** Commit `feat(m19-p3): ClassSelectPanel — data-driven class/primary/attachment/armor/grenade/gadget pickers`.

---

## Task 3: Perk panel + wire panel → client_main → SET_LOADOUT, integrate into deploy flow

**Files:** `client/menus/class_select_panel.gd`, `client/menus/deploy_menu.gd`, `client/client_main.gd`.

- [ ] **Step 1 (perk panel):** In `ClassSelectPanel`, add an always-visible **passive-perk panel** — a VBox of `Label`s populated from `Loadout.trait_blurbs(cls)` (refreshed on class change). Do NOT hardcode the strings. (Optionally show the armor/gadget one-line effects here too.)
- [ ] **Step 2 (wire):** Connect `ClassSelectPanel.loadout_changed` → a `client_main` handler that copies the cfg into `_loadout` and calls `_send_loadout()`. Seed the panel's working copy from `_loadout` when shown (pre-filled per spec).
- [ ] **Step 3 (deploy integration):** In `deploy_menu.gd`, resolve the TODO (line ~66): show/host the `ClassSelectPanel` as part of the deploy flow (e.g. a "Loadout" section/tab next to squad/spawn). Deploy buttons unchanged — deploying uses the last-sent `_loadout`.
- [ ] **Step 4:** `--import`; `ci/connect_smoke_test.sh` PASS; full `--test` green. Manually confirm (headless log) that changing class/gadget in the panel emits a fresh SET_LOADOUT.
- [ ] **Step 5:** Commit `feat(m19-p3): perk panel from trait_blurbs + panel→SET_LOADOUT wiring + deploy-menu integration`.

---

## Task 4: Real-GPU screenshot QA + polish

**Files:** minor polish in `class_select_panel.gd`; QA only (no logic).

- [ ] **Step 1:** Render the deploy/class-select screen on a real GPU (memory: `.116` godot4.7/iGPU self-screenshot, or `.194` Wayland/RX9070XT, or game2 Xvfb + `--rendering-driver opengl3 --shot-after`). Capture one screenshot **per class** (so the perk panel text differs) at a readable resolution.
- [ ] **Step 2:** Verify: all four classes' perk lines render legibly; illegal gadgets greyed/hidden; armor trade-off text visible; selected states clear; layout not clipped at 1080p. Fix any clipping/contrast/legibility issues (NEAREST/theme per the art kit).
- [ ] **Step 3:** Deliver the screenshots to the owner (scp to `~/bf-shots/m19-p3-classselect/` on desktop .194 per memory `blockfire-ab-screenshot-delivery`) for sign-off.
- [ ] **Step 4:** Commit any polish `polish(m19-p3): class-select screen legibility/layout fixes`.

---

## Task 5: Land

- [ ] **Step 1:** Full `--test` 0 failures; `ci/connect_smoke_test.sh` PASS.
- [ ] **Step 2:** (No fleet gate needed — client UI, no server/sim change. Optionally run one 128-bot gate to confirm the new client SET_LOADOUT-on-join doesn't perturb the server: `docker/run-m19-gate.sh` — expect unchanged PASS.)
- [ ] **Step 3:** Update `docs/TASKS.md` M19 row (P3 done; next = P4 LMG Nest). 
- [ ] **Step 4:** Finish via superpowers:finishing-a-development-branch — **fetch origin first** (M20 pushes concurrently), merge origin/master, re-run suite on merged tree (class-cache import gotcha: `godot --headless --import --path .` if new `class_name`s fail), merge to master, push, verify `HEAD==origin/master`, delete branch.

---

## Self-review checklist (before Task 1)
- **Spec §G coverage:** class column ✓, primary+attachments ✓, armor with trade-off ✓, grenade ✓, gadget (built-only) ✓ (Task 2); perk panel from `trait_blurbs` ✓ (Task 3); local sanitize + SET_LOADOUT on change ✓ (Task 1+3); deploy-menu integration ✓ (Task 3); real-GPU QA ✓ (Task 4).
- **Single source of truth:** all option lists + perk strings come from `Loadout`/`Weapon`/`Armor` — no duplicated tables in the UI.
- **Lights up P2:** Task 1's reroute makes `_loadout["gadget"]` drive the client, so a human picking Engineer+REPAIR or Medic+STIM now actually sends/uses it.
- **No server change:** SET_LOADOUT store-and-apply already gate-proven; P3 is client-only.
