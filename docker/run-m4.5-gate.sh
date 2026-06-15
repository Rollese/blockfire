#!/usr/bin/env bash
# One-command isolated M4.5-P1 (DBNO/Revive survivability) gate via Docker (single host, `full`
# profile): brings up the dedicated server + bot fleet in separate containers (server uncontended on
# its own cores), waits for the match to finish, and applies the M4.5-P1 assertions on top of the
# M3/M4 baseline.
#
# M4.5-P1 verdict = M3 criteria (valid winner, points captured, peak-window tick < budget, match
# ended via tickets not the time fail-safe) PLUS:
#   downed  >= 1  — at least one pawn entered DOWNED state (any telemetry window)
#   revives >= 1  — at least one revive completed (any telemetry window)
# Both counters are per-window (reset each telemetry second); we take the max across all windows.
#
# Usage:  ./run-m4.5-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# Fleet example (unraid W-2275, server on isolated cores; stay confined to /mnt/app/blockfire):
#   SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-m4.5-gate.sh
#
# See AGENTS.md §8 for unraid fleet conventions.
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m4.5-gate] building + starting server + bot fleet (DBNO/revive enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M4.5-P1 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"

# downed/revives are per-window counters (reset each telemetry second); take the maximum value
# seen across all windows — a single active window suffices for PASS.
peak_downed="$(echo "$srvlog"  | grep -oE 'downed=[0-9]+'  | sed 's/downed=//'  | sort -n | tail -1)"
peak_revives="$(echo "$srvlog" | grep -oE 'revives=[0-9]+' | sed 's/revives=//' | sort -n | tail -1)"

echo "[m4.5-gate] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m4.5-gate] max-window downed=${peak_downed:-0} revives=${peak_revives:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
[ "${peak_downed:-0}" -ge 1 ]  || { echo "FAIL: no DOWNED events observed (downed=${peak_downed:-0})"; ok=0; }
[ "${peak_revives:-0}" -ge 1 ] || { echo "FAIL: no revives observed (revives=${peak_revives:-0})"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M4.5-P1 DOCKER GATE: PASS"; exit 0; else echo "M4.5-P1 DOCKER GATE: FAIL"; exit 1; fi
