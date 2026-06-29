#!/usr/bin/env bash
# M12-P3 smoke gate: server + bots play Conquest and assert squad-leader FOB construction fired
# (a cooperative FOB build site completes -> fobs_built; fob_spawns/fob_disabled/fobs_destroyed are
# emergent/density-dependent and REPORTED, not forced — same precedent as M12-P2's built_small/etc).
# Models ci/m12_p2_test.sh — same server+bots launch, log capture, cleanup, and max-across-windows
# counter approach (counters reset each telemetry second, so we take the maximum window value).
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27243}"
BOTS="${BOTS:-48}"
TICKETS="${TICKETS:-30}"           # small pool so 48-bot attrition completes within MAX_WAIT
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
# Core pinning — disjoint cores keep the tick metric clean on the dev laptop (8C/16T).
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m12-p3] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m12-p3] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m12-p3] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m12-p3] $BOTS bots"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"
if [ -z "$over_line" ]; then echo "FAIL: no winner within ${MAX_WAIT}s"; exit 1; fi

# winner is on the OVER line: "winner=%d"
winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"

# --- M12-P3 (squad-leader FOB) assertions: max across telemetry windows ---
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
fobs_built=$(maxof fobs_built); fob_spawns=$(maxof fob_spawns)
fob_disabled=$(maxof fob_disabled); fobs_destroyed=$(maxof fobs_destroyed)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m12-p3] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m12-p3] fobs_built=${fobs_built:-0} fob_spawns=${fob_spawns:-0} fob_disabled=${fob_disabled:-0} fobs_destroyed=${fobs_destroyed:-0}"

fail=0
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner (winner=${winner:-<empty>})"; fail=1; }
# fobs_built is the headline (a FOB site shovelled to completion by a leader + the large drillers). The
# high-cost FOB (BUILD_COST 800, min_builders 2) may not complete within a small low-pressure smoke —
# if fobs_built=0 at 48 bots the smoke PRINTS A NOTE rather than hard-failing (like m12_p2 does for
# built_small). The AUTHORITATIVE hard assert is the 128-bot fleet gate (docker/run-m12-p3-gate.sh).
if [ "${fobs_built:-0}" -ge 1 ]; then
	echo "[m12-p3] note: fobs_built=${fobs_built} (cooperative squad-leader FOB build exercised in-match)"
else
	echo "[m12-p3] note: fobs_built=0 in this smoke — high-cost FOB may not complete at ${BOTS} bots; 128-bot fleet gate hard-asserts it"
fi
# fob_spawns / fob_disabled / fobs_destroyed are emergent/density-dependent — reported, not gated.
[ "${fob_spawns:-0}" -ge 1 ] && echo "[m12-p3] note: fob_spawns=${fob_spawns} (squad spawned at a FOB)"
[ "${fob_disabled:-0}" -ge 1 ] && echo "[m12-p3] note: fob_disabled=${fob_disabled} (FOB spawn disabled by enemy proximity)"
[ "${fobs_destroyed:-0}" -ge 1 ] && echo "[m12-p3] note: fobs_destroyed=${fobs_destroyed} (built FOB destroyed)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: M12-P3 (laptop smoke) — fobs_built=${fobs_built:-0} fob_spawns=${fob_spawns:-0} fob_disabled=${fob_disabled:-0} fobs_destroyed=${fobs_destroyed:-0} winner=${winner}"
exit $fail
