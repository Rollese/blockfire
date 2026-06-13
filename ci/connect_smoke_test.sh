#!/usr/bin/env bash
# M0 gate: a client AND a bot connect to the dedicated server over our custom
# message layer and complete the handshake. Headless, no rendering. Exits non-zero
# on failure so CI can gate on it.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27115}"

server_log="$(mktemp)"
client_log="$(mktemp)"
bots_log="$(mktemp)"
server_pid=""; client_pid=""; bots_pid=""

cleanup() {
	for pid in "$client_pid" "$bots_pid" "$server_pid"; do
		[ -n "$pid" ] && kill "$pid" 2>/dev/null
	done
	wait 2>/dev/null
	rm -f "$server_log" "$client_log" "$bots_log"
}
trap cleanup EXIT

# Ensure resources are imported once (fresh checkout has no .godot/).
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

echo "[smoke] starting server on port $PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2

echo "[smoke] starting client"
"$GODOT" --headless --path "$ROOT" -- --connect=127.0.0.1 --port="$PORT" --name=smoke-client >"$client_log" 2>&1 &
client_pid=$!

echo "[smoke] starting 1 bot"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count=1 --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

sleep 4

pass=1
grep -q "2 peers" "$server_log" || { echo "FAIL: server did not reach 2 peers"; pass=0; }
grep -q "WELCOME" "$client_log" || { echo "FAIL: client did not receive WELCOME"; pass=0; }
grep -q "connected (id" "$bots_log" || { echo "FAIL: bot did not connect"; pass=0; }

echo "--- server log ---"; cat "$server_log"
echo "--- client log ---"; cat "$client_log"
echo "--- bots log ---";   cat "$bots_log"

if [ "$pass" -eq 1 ]; then
	echo "SMOKE TEST: PASS"
	exit 0
else
	echo "SMOKE TEST: FAIL"
	exit 1
fi
