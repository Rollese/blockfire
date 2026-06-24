#!/usr/bin/env bash
# M5.5-P3 melee & throwables smoke gate (single-host bare-metal, run on game2): server + bots play
# Conquest on the proving-grounds map and exercise the NEW melee + flashbang + impact paths.
# Telemetry counters read from the server [telemetry] line (max across windows):
#   melees      — melee swings that landed (knife/sledge)
#   backstabs   — rear-arc instant-kill melee hits
#   sledge      — Engineer sledgehammer structure hits
#   flashes     — flashbang detonations; flashblinds — pawns blinded by them
#   impacts     — impact-grenade contact detonations
#
# COMBAT-AI / DENSITY CAVEAT (same as P1/P2): these counters need firing AI + density + reach. A
# short low-pressure smoke can read low. Therefore the smoke REPORTS the counters (warn) and the
# hard PASS/FAIL depends ONLY on: unit suite green + peak-window tick budget. The mechanics
# themselves are proven deterministically by tests/melee_test.gd, tests/grenade_test.gd, and the
# deterministic resolves in tests/grenade_gate_test.gd (authoritative per AGENTS.md §10). The
# 128-bot fleet gate (docker/run-m5.5-p3-gate.sh) hard-gates melees/flashes/impacts under density.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27253}"
BOTS="${BOTS:-48}"
TICKETS="${TICKETS:-30}"
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAP="${MAP:-conquest_proving_grounds}"
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m5.5-p3] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m5.5-p3] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

echo "[m5.5-p3] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m5.5-p3] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m5.5-p3] server on $PORT (map=$MAP tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --map="$MAP" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m5.5-p3] $BOTS bots"
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
melees=$(maxof melees); backstabs=$(maxof backstabs); sledge=$(maxof sledge)
flashes=$(maxof flashes); flashblinds=$(maxof flashblinds); impacts=$(maxof impacts)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m5.5-p3] melees=${melees:-0} backstabs=${backstabs:-0} sledge=${sledge:-0} flashes=${flashes:-0} flashblinds=${flashblinds:-0} impacts=${impacts:-0}"
echo "[m5.5-p3] peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"

fail=0
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: M5.5-P3 (laptop smoke) — melees=${melees:-0} flashes=${flashes:-0} impacts=${impacts:-0} sledge=${sledge:-0} peak=${peak_tick}ms"
exit $fail
