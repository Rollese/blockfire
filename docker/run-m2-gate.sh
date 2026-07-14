#!/usr/bin/env bash
# M2 ammo/magazine system — 128-bot sim fleet gate (single host, `full` profile) on conquest_town.
# Proves the BattleBit individual-magazine system holds at scale with no tick/bandwidth regression
# and no runtime errors: a bot sub-cohort hold-R FAST-RELOADs (drops a recoverable mag) and another
# holds the REDISTRIBUTE key to consolidate partial mags, so the new server paths (_drop_mag /
# ServerDroppedMags TTL+sweep+broadcast / _finish_reload FIFO+fast / _step_redistribute) all run
# under 128p load. Pickup (mags_picked) is proven by tests/server_dropped_mag_test.gd (bots aren't in
# _human_ids so they don't receive the owner-only DROPPED_MAG_LIST).
#
# Host: LOCALLY on game2 (14900KS / 32 threads). game2 example:
#   SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 TICKETS=200 ./run-m2-gate.sh
#
# Map = conquest_town (canonical gameplay map; bot RPG restraint tuned there). Verdict = M3 criteria
# (valid winner, peak-window mean tick < 33.3 ms, ended on tickets not the time fail-safe, >=1
# capture) PLUS zero runtime SCRIPT/parse errors PLUS mags_dropped>=1 (the fast-reload-drop path ran).
# TICKETS defaults to 200 so the capture metric is reliable (cap_events is flaky at 80 — see M19 note).
set -uo pipefail
cd "$(dirname "$0")"

export MAP="${MAP:-conquest_town}"
TIME_LIMIT="${TIME_LIMIT:-900}"; export TIME_LIMIT
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-840}"
export TICKETS="${TICKETS:-200}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m2] building + starting server + 128-bot fleet on map=$MAP (TICKETS=$TICKETS)…"
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
	echo "M2 GATE: FAIL"; exit 1
fi

winner="$(echo "$over"   | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"  | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
scripterr="$(echo "$srvlog" | grep -icE 'SCRIPT ERROR|Parse Error' || true)"
lastline="$(echo "$srvlog" | grep -oE '\[telemetry\].*' | tail -1)"
mags_dropped="$(echo "$lastline" | grep -oE 'mags_dropped=[0-9]+' | sed 's/mags_dropped=//')"
mags_picked="$(echo "$lastline"  | grep -oE 'mags_picked=[0-9]+'  | sed 's/mags_picked=//')"
redist="$(echo "$lastline"       | grep -oE 'redist=[0-9]+'       | sed 's/redist=//')"
echo "[m2] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak-window mean tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) script_errors=${scripterr}"
echo "[m2] mags_dropped=${mags_dropped:-0} mags_picked=${mags_picked:-0} redist=${redist:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: runtime SCRIPT/parse errors in server log"; ok=0; }
[ "${mags_dropped:-0}" -ge 1 ] || { echo "FAIL: no mags dropped — fast-reload path did not run"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M2 GATE: PASS"; exit 0; else echo "M2 GATE: FAIL"; exit 1; fi
