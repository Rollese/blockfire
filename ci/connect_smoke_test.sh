#!/usr/bin/env bash
# M0 gate: a client AND a bot connect to the dedicated server over our custom
# message layer and complete the handshake. Headless, no rendering. Exits non-zero
# on failure so CI can gate on it.
#
# All waits poll the logs (0.25s interval, generous ceilings) — the original fixed
# sleeps (2s boot + 4s handshake) were flake-prone on slow/loaded CI runners.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27115}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"        # seconds for the server to start listening
HANDSHAKE_TIMEOUT="${HANDSHAKE_TIMEOUT:-60}"  # seconds for client+bot to complete handshake

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

# Poll a file for a pattern: wait_for <file> <grep-pattern> <timeout-s>. Returns 1 on timeout.
wait_for() {
	local file="$1" pattern="$2" timeout_s="$3" waited=0
	while ! grep -q "$pattern" "$file" 2>/dev/null; do
		awk "BEGIN{exit !($waited >= $timeout_s)}" && return 1
		sleep 0.25; waited=$(awk "BEGIN{print $waited + 0.25}")
	done
	return 0
}

# Ensure resources are imported once (fresh checkout has no .godot/).
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

echo "[smoke] starting server on port $PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" >"$server_log" 2>&1 &
server_pid=$!
if ! wait_for "$server_log" "\[server\] listening" "$BOOT_TIMEOUT"; then
	echo "FAIL: server did not start listening within ${BOOT_TIMEOUT}s"
	echo "--- server log ---"; cat "$server_log"
	echo "SMOKE TEST: FAIL"; exit 1
fi

echo "[smoke] starting client"
"$GODOT" --headless --path "$ROOT" -- --connect=127.0.0.1 --port="$PORT" --name=smoke-client >"$client_log" 2>&1 &
client_pid=$!

echo "[smoke] starting 1 bot"
"$GODOT" --headless --path "$ROOT" -- --bots --bot-count=1 --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

pass=1
wait_for "$server_log" "2 peers" "$HANDSHAKE_TIMEOUT" || { echo "FAIL: server did not reach 2 peers"; pass=0; }
wait_for "$client_log" "WELCOME" 5 || { echo "FAIL: client did not receive WELCOME"; pass=0; }
wait_for "$bots_log" "connected (id" 5 || { echo "FAIL: bot did not connect"; pass=0; }

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
