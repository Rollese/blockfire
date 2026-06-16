#!/usr/bin/env bash
# One-command isolated M5-P1 (Land Vehicles) gate via Docker (single host, `full` profile),
# LOCALLY on game2 (no ssh). Server pinned to P-cores (0-15); bots take the rest.
# Verdict = M3 baseline (valid winner, points captured, peak tick < budget, ended via tickets)
# PLUS M5-P1 vehicle counters (max across windows):
#   enters >= 1        — at least one occupant boarded a vehicle
#   transport_m >= 30  — a driven vehicle carried an occupant >= 30 m (transport proven)
#   veh_dead >= 1 AND rkt_veh >= 1 — a vehicle was destroyed by an RPG (RPG->HP->destruction)
#   repairs >= 1       — the Engineer repair kit restored HP under load
# Aggregate bandwidth (agg Mbit/s, peak) is reported as the bw-budget evidence.
#
# Usage:  SERVER_CPUS=0-3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-m5-p1-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# game2 example (server on isolated cores, bots on the rest of the 32 threads):
#   SERVER_CPUS=0-3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-m5-p1-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m5-p1] building + starting server + bot fleet (vehicles enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
# Persist the full server log (telemetry + [perf] breakdown) as recorded gate evidence
# and for post-run tick-budget diagnosis once containers are torn down.
srvlog_file="srvlog-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[m5-p1] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M5-P1 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

# M5-P1 vehicle counters are per-window (reset each telemetry second); take the max across windows.
maxof()  { echo "$srvlog" | grep -oE "$1=[0-9]+"  | sed "s/$1=//" | sort -n | tail -1; }
maxoff() { echo "$srvlog" | grep -oE "$1=[0-9.]+" | sed "s/$1=//" | sort -g | tail -1; }
enters="$(maxof enters)"; veh_dead="$(maxof veh_dead)"; rkt_veh="$(maxof rkt_veh)"
repairs="$(maxof repairs)"; transport_m="$(maxoff transport_m)"

echo "[m5-p1] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) peak agg=${peak_agg:-?}Mbit/s"
echo "[m5-p1] enters=${enters:-0} transport_m=${transport_m:-0} veh_dead=${veh_dead:-0} rkt_veh=${rkt_veh:-0} repairs=${repairs:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points captured"; ok=0; }
[ "${enters:-0}" -ge 1 ] || { echo "FAIL: no vehicle boardings (enters=${enters:-0})"; ok=0; }
awk "BEGIN{exit !(${transport_m:-0} >= 30.0)}" || { echo "FAIL: no transport >=30m (transport_m=${transport_m:-0})"; ok=0; }
[ "${veh_dead:-0}" -ge 1 ] || { echo "FAIL: no vehicle destroyed"; ok=0; }
[ "${rkt_veh:-0}" -ge 1 ] || { echo "FAIL: no RPG hit a vehicle (RPG->HP unproven)"; ok=0; }
[ "${repairs:-0}" -ge 1 ] || { echo "FAIL: repair kit never restored HP"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M5-P1 DOCKER GATE: PASS"; exit 0; else echo "M5-P1 DOCKER GATE: FAIL"; exit 1; fi
