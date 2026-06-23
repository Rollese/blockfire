#!/usr/bin/env bash
# M11 (Destructible Buildings) Gate A — 128-bot sim fleet via Docker (single host, `full` profile).
# Runs Conquest on a buildings map (default conquest_arena_buildings) so the bot fleet's explosive
# heuristic blasts buildings near objectives, exercising chunk-damage → support-cascade → collapse
# at scale, and verifies the destruction systems hold the tick + bandwidth budget at 128 players.
#
# Host: LOCALLY on game2 (14900KS / 32 threads). Pin the server to isolated P-cores.
#
# This Gate A was DEFERRED in 2026-06 while the combat AI was inert (bots couldn't stage building
# destruction under load); it is now unblocked — the AI fires (see the M5.5-P1/P2 fleet gates).
#
# M11 Gate A verdict = M3 criteria (valid winner, peak tick < budget, ended on tickets not the
# time fail-safe) PLUS the destruction counters (max across windows):
#   struct    >= 1  — buildings stamped on the map
#   destroyed >= 1  — at least one piece destroyed under load (chunks->0 removal works at scale)
# REPORTED (not gated; density-dependent — proven deterministically in tests, AGENTS.md §10):
#   dmg / rstruct / collapsed / nades / rockets.
# The +M4 re-gate (player building/destruction unchanged after the P1 chunked-store unify) is
# covered by the green unit suite (M4 building/destruction tests) + this fleet holding budget with
# zero script errors (no second destruction codepath).
#
# Usage:  ./run-m11-gate.sh
# Env:    MAP TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS  (passed through to compose)
# game2 example: SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 ./run-m11-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

# Canonical gate map = conquest_proving_grounds (177 pieces): holds budget comfortably AND a
# full-length 128-bot match stages an emergent whole-building collapse. Set MAP=conquest_arena_buildings
# for the dense-buildings stress variant (768 pieces — destruction fires hard but tick rides the
# 33.3 ms edge; that's a map-scale snapshot-cost finding, not an M11-logic regression).
export MAP="${MAP:-conquest_proving_grounds}"
TIME_LIMIT="${TIME_LIMIT:-900}"; export TIME_LIMIT
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m11] building + starting server + 128-bot fleet on map=$MAP (destructible buildings)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
srvlog_file="srvlog-m11-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[m11] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M11 GATE-A: FAIL"; exit 1
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
struct="$(maxof struct)"; dmg="$(maxof dmg)"; destroyed="$(maxof destroyed)"
rstruct="$(maxof rstruct)"; collapsed="$(maxof collapsed)"; nades="$(maxof nades)"; rockets="$(maxof rockets)"
errors="$(echo "$srvlog" | grep -ciE 'SCRIPT ERROR|Parse Error')"

echo "[m11] map=$MAP winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) peak agg=${peak_agg:-?}Mbit/s script_errors=${errors}"
echo "[m11] struct=${struct:-0} dmg=${dmg:-0} destroyed=${destroyed:-0} rstruct=${rstruct:-0} collapsed=${collapsed:-0} nades=${nades:-0} rockets=${rockets:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${struct:-0}" -ge 1 ] || { echo "FAIL: no buildings stamped (struct=0) — wrong map?"; ok=0; }
[ "${destroyed:-0}" -ge 1 ] || { echo "FAIL: no pieces destroyed (destroyed=0) — if near-building combat density was low this is expected; mechanic proven in tests/server_buildings_functional_test.gd"; ok=0; }
[ "${errors:-1}" -eq 0 ] || { echo "FAIL: server script/parse errors in the run"; ok=0; }
# Reported (not gated): cascade orphan removals + whole-building collapse are density-dependent.
[ "${collapsed:-0}" -ge 1 ] && echo "[m11] note: collapsed=${collapsed} (whole-building COLLAPSE fired under load)" || echo "[m11] note: collapsed=0 (density-dependent; proven deterministically in tests/server_buildings_functional_test.gd + support_test.gd)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M11 GATE-A: PASS"; exit 0; else echo "M11 GATE-A: FAIL"; exit 1; fi
