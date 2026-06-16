#!/usr/bin/env bash
# One-command isolated M4.5-P3 (Movement) gate via Docker (single host, `full` profile):
# brings up the dedicated server + bot fleet in separate containers (server uncontended on its
# own cores), waits for the match to finish, and applies the M4.5-P3 assertions on top of the
# M3 baseline.
#
# Host: this runs LOCALLY on game2 (14900KS / CachyOS, 32 threads) — the full-time dev+gate
# host. No cross-host ssh. A laptop only attaches to a tmux session on game2. Pin the server to
# isolated cores so the bot fleet can't steal its cycles.
#
# M4.5-P3 verdict = M3 criteria (valid winner, points captured, peak-window tick < budget, match
# ended via tickets not the time fail-safe) PLUS the movement counters (max across windows):
#   climbs >= 1  — at least one pawn entered ladder-climb mode (bot traversed the climb wall)
#   vaults >= 1  — at least one pawn completed an auto-vault (over the prebuilt sandbag / a
#                  half-height structure piece)
# dropblk (drop-shoot rejections) is REPORTED but not gated — the drop-shoot gate criterion is
# the unit test (combat_test::drop_shoot_*); a live rejection is density/timing dependent.
# Aggregate bandwidth (agg Mbit/s, peak across windows) is reported as the bw-budget evidence.
# All counters are per-window (reset each telemetry second); we take the max across all windows.
#
# Usage:  ./run-m4.5-p3-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# game2 example (server on isolated cores, bots on the rest of the 32 threads):
#   SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 ./run-m4.5-p3-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m4.5-p3] building + starting server + bot fleet (movement geometry enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
# Persist the full server log (telemetry + [perf] breakdown) as recorded gate evidence
# (AGENTS.md §6) and for post-run tick-budget diagnosis once containers are torn down.
srvlog_file="srvlog-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[m4.5-p3] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M4.5-P3 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

# P3 movement counters are per-window (reset each telemetry second); take the max across windows.
maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
climbs="$(maxof climbs)"; vaults="$(maxof vaults)"; dropblk="$(maxof dropblk)"

echo "[m4.5-p3] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) peak agg=${peak_agg:-?}Mbit/s"
echo "[m4.5-p3] climbs=${climbs:-0} vaults=${vaults:-0} dropblk=${dropblk:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
[ "${climbs:-0}" -ge 1 ] || { echo "FAIL: no ladder climbs (climbs=${climbs:-0})"; ok=0; }
[ "${vaults:-0}" -ge 1 ] || { echo "FAIL: no vaults (vaults=${vaults:-0})"; ok=0; }
# dropblk (drop-shoot rejections) reported, not gated — gate criterion is the unit test.
[ "${dropblk:-0}" -ge 1 ] && echo "[m4.5-p3] note: dropblk=${dropblk} (drop-shoot rejection exercised in-match)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M4.5-P3 DOCKER GATE: PASS"; exit 0; else echo "M4.5-P3 DOCKER GATE: FAIL"; exit 1; fi
