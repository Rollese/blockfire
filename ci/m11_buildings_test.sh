#!/usr/bin/env bash
# M11 (Destructible Buildings) Gate A smoke — ≤48-bot single-host bare-metal (run on game2):
# server + bots play Conquest on a buildings map (default conquest_arena_buildings) and exercise
# the destruction → chunk-damage → support-cascade → collapse pipeline that landed in M11-P1/P2/P3.
# Telemetry counters read from the server [telemetry] line (max across windows):
#   struct    — stamped/live structure pieces (buildings present)
#   dmg       — structure damage events
#   destroyed — pieces fully destroyed (chunks->0 removal)
#   rstruct   — structure pieces removed (incl. cascade orphan removals)
#   collapsed — whole-building COLLAPSE events (support-cascade > threshold)
#   nades/rockets — explosive sources that drive chunk damage
#
# Per AGENTS.md §10 the destruction MECHANIC is proven deterministically by
# tests/server_buildings_functional_test.gd (damage→cascade→orphan loop) + tests/support_test.gd
# + tests/protocol_collapse_test.gd. This fleet smoke proves it survives 128p-style LOAD + budget;
# emergent-AI-staged whole-building COLLAPSE is density-dependent so it is REPORTED (warn), not
# hard-failed, here — hard collapse demonstration lives in the deterministic test + (best-effort) the
# Docker fleet gate. Hard PASS/FAIL = unit suite green + tick budget. A missing winner is warned.
# Models ci/m5.5_p2_test.sh.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27253}"
MAP="${MAP:-conquest_proving_grounds}"   # canonical Conquest gate map (177 pieces, holds budget, collapse fires in a full match); set MAP=conquest_arena_buildings for the dense-map stress variant (768 pieces, rides the budget edge)
BOTS="${BOTS:-48}"
TICKETS="${TICKETS:-30}"
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m11] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m11] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

echo "[m11] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m11] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m11] server on $PORT map=$MAP (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --map="$MAP" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m11] $BOTS bots"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --map="$MAP" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"

maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
struct=$(maxof struct); dmg=$(maxof dmg); destroyed=$(maxof destroyed); rstruct=$(maxof rstruct)
collapsed=$(maxof collapsed); nades=$(maxof nades); rockets=$(maxof rockets)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

winner=""
if [ -n "$over_line" ]; then
	winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
	elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
	echo "[m11] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
else
	echo "[m11] no [match] OVER within ${MAX_WAIT}s — peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
fi
echo "[m11] struct=${struct:-0} dmg=${dmg:-0} destroyed=${destroyed:-0} rstruct=${rstruct:-0} collapsed=${collapsed:-0} nades=${nades:-0} rockets=${rockets:-0}"

fail=0
[ "${struct:-0}" -ge 1 ] || { echo "FAIL: no buildings stamped (struct=0) — wrong map?"; fail=1; }
[ -n "$over_line" ] && { [ "$winner" = "0" ] || [ "$winner" = "1" ]; } && echo "[m11] winner OK (${winner})" || echo "[m11] NOTE: no/!valid attrition winner under low pressure — destruction proven by tests/server_buildings_functional_test.gd (AGENTS.md §10)"
[ "${destroyed:-0}" -ge 1 ] && echo "[m11] note: destroyed=${destroyed} (pieces destroyed in-match)"
[ "${collapsed:-0}" -ge 1 ] && echo "[m11] note: collapsed=${collapsed} (whole-building collapse fired)" || echo "[m11] note: collapsed=0 (density-dependent; proven deterministically in tests)"

awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: M11 Gate-A (laptop smoke, map=$MAP) — struct=${struct:-0} destroyed=${destroyed:-0} collapsed=${collapsed:-0} peak=${peak_tick}ms"
exit $fail
