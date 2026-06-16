#!/usr/bin/env bash
# M4.5-P3 smoke gate (single-host bare-metal, run on game2): server + bots play Conquest on the
# proving-grounds map (which now carries a climb wall + ladder + ledge and a prebuilt vault
# sandbag on the bot route) and assert the movement systems are exercised.
#
# Host note: game2 (14900KS / CachyOS) is the full-time dev+gate host; a laptop only attaches to
# a tmux session here. This is the lightweight ≤48-bot single-process smoke; the authoritative
# 128-bot run is the Docker FLEET gate (docker/run-m4.5-p3-gate.sh), also run locally on game2.
#
# Models ci/m4.5_p2_test.sh — same server+bots launch, log capture, cleanup, and
# max-across-windows counter approach (telemetry counters reset each second, so we take the
# maximum window value rather than the last).
#
# Gate (smoke): full unit suite green, a valid Conquest winner, and peak-window tick under
# budget. climbs/vaults are REPORTED but NOT hard-gated at 48 bots — traversal of the static
# geometry is density-dependent and the authoritative hard assertion (climbs>=1, vaults>=1)
# lives in the 128-bot FLEET gate (docker/run-m4.5-p3-gate.sh). Drop-shoot rejection is covered
# by the unit test (combat_test::drop_shoot_*); dropblk is reported here for visibility.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27243}"
BOTS="${BOTS:-48}"
TICKETS="${TICKETS:-30}"           # small pool so 48-bot attrition completes within MAX_WAIT
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
# Core pinning — disjoint cores keep the tick metric clean (dev laptop 8C/16T; game2 32T).
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m4.5-p3] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m4.5-p3] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

# --- Full unit suite must be green before the integration smoke (DoD) ---
echo "[m4.5-p3] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m4.5-p3] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m4.5-p3] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m4.5-p3] $BOTS bots"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"
if [ -z "$over_line" ]; then echo "FAIL: no winner within ${MAX_WAIT}s"; tail -20 "$server_log"; exit 1; fi

winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"

# --- M4.5 P3 (movement) counters: max across telemetry windows ---
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
climbs=$(maxof climbs); vaults=$(maxof vaults); dropblk=$(maxof dropblk)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m4.5-p3] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m4.5-p3] climbs=${climbs:-0} vaults=${vaults:-0} dropblk=${dropblk:-0}"

fail=0
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner (winner=${winner:-<empty>})"; fail=1; }
# climbs/vaults are REPORTED, not gated on the laptop smoke (density-dependent; the 128-bot fleet
# gate hard-asserts both). Movement helpers are unit-tested (ladder_test, vault_test, sim_loop_test).
[ "${climbs:-0}" -ge 1 ] && echo "[m4.5-p3] note: climbs=${climbs} (ladder traversal exercised in-match)"
[ "${vaults:-0}" -ge 1 ] && echo "[m4.5-p3] note: vaults=${vaults} (vault exercised in-match)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: M4.5-P3 (laptop smoke) — winner=${winner} climbs=${climbs:-0} vaults=${vaults:-0} dropblk=${dropblk:-0} peak=${peak_tick}ms"
exit $fail
