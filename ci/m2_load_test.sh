#!/usr/bin/env bash
# M2 gate: server + 128 bots (2 teams) headless. Assert mean server tick < 33.3ms
# AND kills register (bots actually shoot each other). Exit non-zero on breach.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27230}"
BOTS="${BOTS:-128}"
DURATION="${DURATION:-60}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m2] server on $PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m2] $BOTS bots"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!
sleep "$DURATION"

line="$(grep "players=$BOTS" "$server_log" | tail -1)"
echo "--- last telemetry ---"; echo "$line"
if [ -z "$line" ]; then echo "FAIL: never reached $BOTS players"; exit 1; fi

mean="$(echo "$line" | sed -n 's/.*tick_mean=\([0-9.]*\)ms.*/\1/p')"
total_kills="$(grep -oE 'kills=[0-9]+' "$server_log" | sed 's/kills=//' | awk '{s+=$1} END{print s+0}')"
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"
echo "[m2] last-window mean tick=${mean}ms  peak-window mean tick=${peak_tick}ms  (budget ${TICK_BUDGET_MS})  total kills over run=${total_kills}"

ok=1
awk "BEGIN{exit !($peak_tick < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
[ "$total_kills" -ge 1 ] || { echo "FAIL: no kills registered"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M2 GATE: PASS"; exit 0; else echo "M2 GATE: FAIL"; exit 1; fi
