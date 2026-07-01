# Runbook — Reading Server Telemetry

The dedicated server prints one `[telemetry]` line per **1-second window** to stdout (captured in
`docker/srvlog-*.log` for fleet runs). It is the primary observability surface — there is no
metrics stack (see [`docs/specs/m8-hardening-ops.md`](../specs/m8-hardening-ops.md)). This runbook
is the field glossary and how to read health from it.

Emit site: `server/server_main.gd` `_log_telemetry`. Format: space-separated `key=value`.

## Health fields — read these first

| Field | Meaning | Budget / how to read |
|---|---|---|
| `tick_mean` | mean server step time this window (ms) | **< 33.3 ms** = 30 Hz held. The gate metric — take the **max across windows** (peak) for a run. |
| `tick_p99` | 99th-percentile step time (ms) | spikiness; a high p99 with low mean = intermittent stalls (GC, a heavy tick). |
| `agg` | aggregate egress across all clients (Mbit/s) | 128p sits ~13–21 Mbit/s. Sudden growth = a replication regression. |
| `pktloss` | mean per-peer ENet packet loss (%) | ~0 on a clean LAN; sustained non-zero = network stress / a saturated link. |
| `starv` | ticks this window where a client's input was missing (server reused the last frame) | rises when the bot fleet can't feed 128 inputs at 30 Hz; a few hundred/window at 128 is tolerable, sustained high = add `BOT_REPLICAS`. Not a gate criterion. |
| `players` / `alive` | connected pawns / currently-alive | should reach the fleet size (128). |
| `rewind_clamped` | lag-comp rewinds clamped to the history horizon | occasional is fine; sustained = clients far behind. |

## Match state

`t0` / `t1` = tickets remaining per team · `pts` = per-point owners · `cap_events` = capture flips ·
`kills` `shots` `hit_rate` `downed` `bleedouts` `revives`. Match end is a separate
`[match] OVER winner=<0|1|-1> t0=.. t1=.. elapsed=..s cap_events=..` line — a valid `winner` +
`elapsed < TIME_LIMIT` means the match resolved via tickets, not the time fail-safe.

## Feature counters (per window; gate scripts take the max across windows)

These prove a subsystem fired at least once under load; each is a running per-window count.

- **Ballistics/combat:** `proj` (fired) `projhit` `projlive` `projdrop` · `pen` (wall penetration) · `dmg` · `swaps` (weapon) · `supp` (suppression events) · `melees` `backstabs` `sledge`.
- **Throwables:** `nades` `splash` `smoke` `flashes` `flashblinds` `impacts` · `rockets` (RPG detonations) `rstruct` (rockets vs structures).
- **Structures/destruction:** `struct` (live pieces) `bld` (placed) `rmv` `blk` (blocked) `destroyed` `collapsed`.
- **Gadgets/support:** `c4` `mines` `heals` `ammo` `bags` `bagx` (exhausted) · `repairs` `repair_oh` (overheats).
- **Movement:** `climbs` `vaults` `dropblk` (drop-shoot blocked).
- **Vehicles:** `enters` `exits` `veh_dead` `rkt_veh` (RPG-vs-vehicle kills) `transport_m` (metres driven).
- **Construction/FOB (M12):** `built_small` `built_large` `bsolo` `dismantled` `repaired` `fobs_built` `fob_spawns` `fob_disabled` `fobs_destroyed`.
- **Anti-cheat:** `ac_viol` (input-validation rejections) — should stay ~0 for bot fleets.

## Quick one-liners

```bash
f=docker/srvlog-<ts>.log
grep -oE 'tick_mean=[0-9.]+' "$f" | sed 's/.*=//' | sort -g | tail -1     # peak-window mean tick
grep -oE 'agg=[0-9.]+'       "$f" | sed 's/.*=//' | sort -g | tail -1     # peak aggregate Mbit/s
grep -oE 'starv=[0-9]+'      "$f" | sed 's/.*=//' | sort -n | tail -1     # worst starvation window
grep -m1 '\[match\] OVER'    "$f"                                          # match result
```

Bot-driver CPU is a separate `[bot-perf] bots=<n> ai_us_mean=<us>` line in the **bots** container
logs (`docker compose logs bots`), not the server log.
