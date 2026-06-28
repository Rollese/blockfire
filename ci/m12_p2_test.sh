#!/usr/bin/env bash
# M12-P2 smoke gate: server + bots play Conquest and assert cooperative shovel construction fired
# (a small build site completes; built_large/bsolo/dismantled/repaired reported — density-dependent).
# Models ci/m4.5_p1_test.sh — same server+bots launch, log capture, cleanup, and
# max-across-windows counter approach (counters reset each telemetry second, so we take
# the maximum window value rather than the last).
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27242}"
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
	echo "[m4.5-p2] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m4.5-p2] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m4.5-p2] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m4.5-p2] $BOTS bots"
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

# --- M12-P2 (cooperative shovel construction) assertions: max across telemetry windows ---
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
built_small=$(maxof built_small); built_large=$(maxof built_large); bsolo=$(maxof bsolo)
dismantled=$(maxof dismantled); repaired=$(maxof repaired)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m12-p2] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m12-p2] built_small=${built_small:-0} built_large=${built_large:-0} bsolo=${bsolo:-0} dismantled=${dismantled:-0} repaired=${repaired:-0}"

fail=0
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner (winner=${winner:-<empty>})"; fail=1; }
[ "${built_small:-0}" -ge 1 ] || { echo "FAIL: no small site completed (built_small=${built_small:-0})"; fail=1; }
# built_large / bsolo (cooperation gate) need >=2 drillers converging on one large site — reliable at
# 128 bots but density-dependent at the laptop smoke. The 128-bot FLEET gate hard-asserts both
# (run-m12-p2-gate.sh). The cooperation gate itself is unit-proven in build_construction_functional_test.
[ "${built_large:-0}" -ge 1 ] && echo "[m12-p2] note: built_large=${built_large} (cooperative large build exercised)"
[ "${bsolo:-0}" -ge 1 ] && echo "[m12-p2] note: bsolo=${bsolo} (cooperation gate observed)"
# dismantled / repaired are reported, not gated (density-dependent — see run-m12-p2-gate.sh).
[ "${dismantled:-0}" -ge 1 ] && echo "[m12-p2] note: dismantled=${dismantled} (enemy shovel-dismantle exercised)"
[ "${repaired:-0}" -ge 1 ] && echo "[m12-p2] note: repaired=${repaired} (friendly shovel-repair exercised)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: M12-P2 (laptop smoke) — built_small=${built_small} built_large=${built_large:-0} bsolo=${bsolo:-0} dismantled=${dismantled:-0} repaired=${repaired:-0} winner=${winner}"
exit $fail
