#!/usr/bin/env bash
# One-command isolated M4 Phase-1 (Building) gate via Docker (single host, `full` profile):
# brings up the dedicated server + bot fleet in separate containers (server uncontended on its
# own cores), waits for the match to finish, and applies the M4 assertions on top of the M3
# ones. Building is always-on in the server, so the same compose topology exercises it; this
# script reads the structure telemetry the M3 run-gate.sh ignores.
#
# M4 verdict = M3 criteria (valid winner, points captured, peak-window tick < budget, match
# ended via tickets not the time fail-safe) PLUS: pieces accumulated (peak struct >= 1),
# placements occurred (sum bld >= 1), cover blocked shots (sum blk >= 1), and structures
# replicated to the fleet (a "structures synced" line in the bot containers' logs).
#
# Usage:  ./run-m4-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# Fleet example (unraid W-2275, server on isolated cores):
#   SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-m4-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # building slows attrition vs M3; give the match room
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m4-gate] building + starting server + bot fleet (building enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
botslog="$("${DC[@]}" logs bots 2>/dev/null)"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M4 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog"   | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_struct="$(echo "$srvlog" | grep -oE 'struct=[0-9]+'    | sed 's/struct=//'    | sort -n | tail -1)"
bld_total="$(echo "$srvlog"   | grep -oE 'bld=[0-9]+'       | sed 's/bld=//'       | awk '{s+=$1} END{print s+0}')"
blk_total="$(echo "$srvlog"   | grep -oE 'blk=[0-9]+'       | sed 's/blk=//'       | awk '{s+=$1} END{print s+0}')"
synced="$(echo "$botslog" | grep -m1 'structures synced' || true)"
echo "[m4-gate] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m4-gate] peak struct=${peak_struct} builds=${bld_total} blocked_shots=${blk_total}"
echo "[m4-gate] ${synced:-<no structures synced to bots>}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
[ "${peak_struct:-0}" -ge 1 ] || { echo "FAIL: no pieces accumulated"; ok=0; }
[ "${bld_total:-0}" -ge 1 ]  || { echo "FAIL: no pieces were placed"; ok=0; }
[ "${blk_total:-0}" -ge 1 ]  || { echo "FAIL: cover never blocked a shot"; ok=0; }
[ -n "$synced" ] || { echo "FAIL: structures did not replicate to bots"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M4 DOCKER GATE: PASS"; exit 0; else echo "M4 DOCKER GATE: FAIL"; exit 1; fi
