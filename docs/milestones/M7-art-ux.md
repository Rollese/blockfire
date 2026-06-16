# M7 — Art Pass + UX Polish

**Status:** **todo — recommended NEXT** · **Blocked by:** M5 land gate (done ✅) · *(pulled before M6 on 2026-06-16: this is the first human-playable rendered client; M6 voice + M10 air both need it)*

**Objective:** Replace placeholders with the low-poly blocky kit and finish player-facing UX.

## Scope
- Low-poly **blocky asset kit** (characters, weapons, vehicles, environment) echoing BattleBit's aesthetic; LOD pipeline.
- Full HUD: health, ammo, minimap, capture status, killfeed, scoreboard.
- Deploy / squad / settings menus.
- Audio/visual feedback polish (hit markers, damage indicators).
- **Steam integration (first rendered client)**: Steam auth via session tickets + **VAC** baseline (via GodotSteam; keep it client/server-edge, never in `shared/`). Steam Direct $100/app.
- **Anti-cheat Layer 3 — line-of-sight replication culling**: don't replicate enemies a player has no sight line to (extends interest culling + the 32-entity relevance cap), using M4 occlusion data. Anti-wallhack/ESP. See [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md) / [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md).

## Gate
End-to-end **human playtest of a full Conquest match** with the real art and complete HUD.

## Specs required
- `docs/specs/art-pipeline.md`, `docs/specs/hud-ui.md`
