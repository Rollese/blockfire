#!/usr/bin/env bash
# M4.5-P1 smoke gate: server + bots play Conquest and assert the DBNO/revive loop fired.
# Models ci/m3_conquest_test.sh — same server+bots launch, log capture, cleanup, and
# max-across-windows counter approach (downed/revives reset per telemetry second, so we
# take the maximum window value rather than the last).
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27241}"
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
	echo "[m4.5-p1] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m4.5-p1] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m4.5-p1] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m4.5-p1] $BOTS bots"
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

# --- M4.5 P1 (survivability) assertions ---
# downed/revives are per-window counters (reset each telemetry second); take the
# maximum value seen across all windows so a single active window suffices for PASS.
downed=$(grep -o 'downed=[0-9]*' "$server_log" | cut -d= -f2 | sort -n | tail -1)
revives=$(grep -o 'revives=[0-9]*' "$server_log" | cut -d= -f2 | sort -n | tail -1)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m4.5-p1] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m4.5-p1] max-window downed=${downed:-0} revives=${revives:-0}"

fail=0
[ "${downed:-0}" -ge 1 ]  || { echo "FAIL: no DOWNED events (downed=${downed:-0})"; fail=1; }
[ "${revives:-0}" -ge 1 ] || { echo "FAIL: no revives observed (revives=${revives:-0})"; fail=1; }
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: Conquest produced no valid winner (winner=${winner:-<empty>})"; fail=1; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms > ${TICK_BUDGET_MS}ms)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: M4.5-P1 — downed=${downed:-0} revives=${revives:-0} winner=${winner}"
exit $fail
