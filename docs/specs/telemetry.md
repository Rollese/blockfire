# Spec — Server Telemetry (schema-of-record)

Status: **active** (M8-P2) · Milestone: [`M8-hardening-ops.md`](../milestones/M8-hardening-ops.md) ·
Interpretation/how-to: [`docs/runbooks/reading-telemetry.md`](../runbooks/reading-telemetry.md)

The dedicated server's observability surface is a single **`[telemetry]` line per 1-second window**
on stdout (no metrics stack — a LAN game; see [`m8-hardening-ops.md`](m8-hardening-ops.md)). This
spec is the authoritative schema; the runbook covers reading it for health.

## Format
`[telemetry] key=value key=value …` — space-separated, one line per window, stable key order.
Emitted by `server/server_main.gd::_log_telemetry`; per-window counters reset in
`Telemetry.reset_window()`. Machine-parseable with `grep -oE 'key=[0-9.]+'`. Match-end is a
separate `[match] OVER winner=.. t0=.. t1=.. elapsed=..s cap_events=..` line.

## Field contract

**Health (floats/ints, sampled or windowed):**
- `players` int — connected pawns. `alive` int — currently-alive pawns.
- `tick_mean` / `tick_p99` float ms — mean / p99 server step time this window. Budget < 33.3 ms.
- `agg` float Mbit/s — aggregate egress across clients (`Telemetry.total_bytes()×8/1e6`).
- `pktloss` float % — **mean per-peer ENet packet loss** (`Telemetry.mean_packet_loss_pct` over
  `peer.get_statistic(PEER_PACKET_LOSS)`; the raw ENet stat is a rolling mean scaled by 65536).
  0 on a clean LAN; rises under network stress. Added M8-P2.
- `starv` int — ticks this window a client's input was missing (last frame reused).
- `rewind_clamped` int — lag-comp rewinds clamped to the history horizon.
- `hit_rate` float — `_hits/_shots` this window.

**Match state:** `t0` `t1` (tickets/team), `pts` (per-point owner string, `.`=neutral), `cap_events`.

**Feature counters (per-window ints; gate scripts take the max across windows):** ballistics/combat
`kills shots proj projhit projlive projdrop pen dmg swaps supp melees backstabs sledge`; throwables
`nades splash smoke rockets rstruct flashes flashblinds impacts`; structures `struct bld rmv blk
destroyed collapsed`; gadgets/support `c4 mines heals ammo bags bagx repairs repair_oh`; movement
`climbs vaults dropblk`; vehicles `enters exits veh_dead rkt_veh transport_m`; construction/FOB
`built_small built_large bsolo dismantled repaired fobs_built fob_spawns fob_disabled fobs_destroyed`;
survivability `downed bleedouts revives`; anti-cheat `ac_viol`. Full glossary in the runbook.

## Stability
Key names + order are a stable contract for log scrapers and the `docker/*gate*.sh` scripts. New
fields are **appended** (never reordered/removed) so existing parsers keep working — as `pktloss`
was inserted after `agg` this milestone (scrapers key on name, not column).

## Deferred (YAGNI until a consumer exists)
An opt-in `--telemetry-json=<path>` NDJSON sink (one JSON record per window, same fields) is
specced for dashboard scraping but **not implemented** — the key=value stdout line + the runbook
one-liners cover current needs, and no dashboard consumes it yet. Revisit if/when one does.
