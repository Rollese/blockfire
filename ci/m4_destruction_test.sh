#!/usr/bin/env bash
# M4 Phase-2 gate: server + bots play Conquest with building + DESTRUCTION enabled. Assert a
# winner is declared, pieces are destroyed and frags detonate, structures still replicate, and the
# peak-window server tick stays under budget. (Smoke is reported, not gated — destruction is the
# frag-driven path.) Exit non-zero on breach. 128 on the fleet; 48 on the dev laptop.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27242}"
BOTS="${BOTS:-128}"
TICKETS="${TICKETS:-80}"
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m4p2] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m4p2] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m4p2] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m4p2] $BOTS bots (building + destruction enabled)"
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

winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"
destroyed_total="$(grep -oE 'destroyed=[0-9]+' "$server_log" | sed 's/destroyed=//' | awk '{s+=$1} END{print s+0}')"
nades_total="$(grep -oE 'nades=[0-9]+' "$server_log" | sed 's/nades=//' | awk '{s+=$1} END{print s+0}')"
splash_total="$(grep -oE 'splash=[0-9]+' "$server_log" | sed 's/splash=//' | awk '{s+=$1} END{print s+0}')"
smoke_total="$(grep -oE 'smoke=[0-9]+' "$server_log" | sed 's/smoke=//' | awk '{s+=$1} END{print s+0}')"
synced="$(grep -m1 'structures synced' "$bots_log" || true)"
echo "[m4p2] winner=${winner} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) destroyed=${destroyed_total} nades=${nades_total} splash=${splash_total} smoke=${smoke_total}"
echo "[m4p2] ${synced:-<no structures synced to bots>}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${destroyed_total:-0}" -ge 1 ] || { echo "FAIL: no pieces were destroyed"; ok=0; }
[ "${nades_total:-0}" -ge 1 ] || { echo "FAIL: no frags detonated"; ok=0; }
[ -n "$synced" ] || { echo "FAIL: structures did not replicate to bots"; ok=0; }
awk "BEGIN{exit !($peak_tick < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M4-P2 GATE: PASS"; exit 0; else echo "M4-P2 GATE: FAIL"; exit 1; fi
