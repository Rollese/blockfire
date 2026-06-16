#!/usr/bin/env bash
# M5-P1 smoke gate (single-host bare-metal, run on game2): server + bots play Conquest and assert
# the vehicle systems are exercised.
#
# Host note: game2 (14900KS / CachyOS) is the full-time dev+gate host; a laptop only attaches to
# a tmux session here. This is the lightweight ≤48-bot single-process smoke; the authoritative
# 128-bot run is the Docker FLEET gate (docker/run-m5-p1-gate.sh), also run locally on game2.
#
# Models ci/m4.5_p3_test.sh — same server+bots launch, log capture, cleanup, and
# max-across-windows counter approach (telemetry counters reset each second, so we take the
# maximum window value rather than the last).
#
# Gate (smoke): full unit suite green, a valid Conquest winner, and peak-window tick under
# budget. enters>=1 and repairs>=1 are hard-gated here (density-independent: bots board/repair
# regardless of count). transport_m>=30, veh_dead>=1, and rkt_veh>=1 are REPORTED but NOT
# hard-gated at 48 bots — the RPG-kill chain and sustained 30m drive are density/timing dependent
# and the authoritative hard assertions live in the 128-bot FLEET gate (docker/run-m5-p1-gate.sh).
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27244}"
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
	echo "[m5-p1] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m5-p1] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

# --- Full unit suite must be green before the integration smoke (DoD) ---
echo "[m5-p1] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m5-p1] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m5-p1] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m5-p1] $BOTS bots"
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

# --- M5-P1 (vehicles) counters: max across telemetry windows ---
maxof()  { grep -oE "$1=[0-9]+"  "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
maxoff() { grep -oE "$1=[0-9.]+" "$server_log" | sed "s/$1=//" | sort -g | tail -1; }
enters=$(maxof enters); repairs=$(maxof repairs)
veh_dead=$(maxof veh_dead); rkt_veh=$(maxof rkt_veh); transport_m=$(maxoff transport_m)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m5-p1] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m5-p1] enters=${enters:-0} repairs=${repairs:-0} veh_dead=${veh_dead:-0} rkt_veh=${rkt_veh:-0} transport_m=${transport_m:-0}"

fail=0
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner (winner=${winner:-<empty>})"; fail=1; }
# enters and repairs are hard-gated: density-independent, bots always board and repair.
[ "${enters:-0}" -ge 1 ] || { echo "FAIL: no vehicle boardings (enters=${enters:-0})"; fail=1; }
[ "${repairs:-0}" -ge 1 ] || { echo "FAIL: repair kit never restored HP (repairs=${repairs:-0})"; fail=1; }
# transport_m, veh_dead, rkt_veh: REPORTED, not gated on the 48-bot smoke — density/timing
# dependent; the 128-bot FLEET gate hard-asserts all three.
[ "${veh_dead:-0}" -ge 1 ] && echo "[m5-p1] note: veh_dead=${veh_dead} (vehicle destruction exercised in-match)"
[ "${rkt_veh:-0}" -ge 1 ] && echo "[m5-p1] note: rkt_veh=${rkt_veh} (RPG->vehicle hit exercised in-match)"
awk "BEGIN{exit !(${transport_m:-0} >= 30.0)}" && echo "[m5-p1] note: transport_m=${transport_m} (>=30m transport exercised in-match)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: M5-P1 (smoke) — winner=${winner} enters=${enters:-0} repairs=${repairs:-0} veh_dead=${veh_dead:-0} rkt_veh=${rkt_veh:-0} transport_m=${transport_m:-0} peak=${peak_tick}ms"
exit $fail
