#!/usr/bin/env bash
# M1 gate: run the server + 128 bots headless for ~30s, parse the last telemetry
# line, and assert mean server tick < 33.3 ms (30 Hz held). Exit non-zero on breach.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27130}"
BOTS="${BOTS:-128}"
DURATION="${DURATION:-30}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

echo "[m1] server on $PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m1] $BOTS bots"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

sleep "$DURATION"

# last telemetry line at full population
line="$(grep "players=$BOTS" "$server_log" | tail -1)"
echo "--- last telemetry ---"
echo "$line"

if [ -z "$line" ]; then
	echo "FAIL: never reached $BOTS players"; exit 1
fi

mean="$(echo "$line" | sed -n 's/.*tick_mean=\([0-9.]*\)ms.*/\1/p')"
echo "[m1] mean tick = ${mean}ms (budget ${TICK_BUDGET_MS}ms)"
if awk "BEGIN{exit !($mean < $TICK_BUDGET_MS)}"; then
	echo "M1 GATE: PASS"; exit 0
else
	echo "M1 GATE: FAIL (mean tick $mean >= $TICK_BUDGET_MS)"; exit 1
fi
