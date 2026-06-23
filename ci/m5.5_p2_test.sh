#!/usr/bin/env bash
# M5.5-P2 survivability smoke gate (single-host bare-metal, run on game2): server + bots play
# Conquest on the proving-grounds map and exercises the NEW armor-class + suppression systems.
# Telemetry counter read from the server [telemetry] line:
#   supp     — peak-window near-miss suppression accruals (an enemy bullet passing within
#              Suppress.SUPPRESS_RADIUS of a pawn) — proves the suppression seam fires under load.
# Armor-class TTK variance is REPORTED via the existing kill/down counters across classes (bots
# span all four classes -> all three armor tiers: MEDIC=LIGHT, ASSAULT=MEDIUM, ENG/SUP=HEAVY).
#
# COMBAT-AI CAVEAT: the combat bot AI was historically inert in full matches; as of 2026-06-23
# bots DO fire (M5.5-P1 fleet gate showed proj=207), but suppression needs density+attrition, so
# a short low-pressure smoke can still read supp=0. Therefore:
#   • supp is REPORTED here (warn, non-fatal) and HARD-GATED only in the 128-bot fleet gate
#     (docker/run-m5.5-p2-gate.sh), mirroring how m5.5_p1 hard-gates proj/projhit only in Docker.
#   • The armor + suppression MECHANICS are proven deterministically by tests/armor_test.gd,
#     tests/suppress_test.gd, and tests/projectile_gate_test.gd (authoritative per AGENTS.md §10).
#   • A missing attrition winner is warned, not failed.
# Hard PASS/FAIL depends ONLY on: unit suite green + tick budget. Modeled on ci/m5.5_p1_test.sh.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27252}"
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
	echo "[m5.5-p2] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m5.5-p2] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

# --- Full unit suite must be green before the integration smoke (DoD) ---
echo "[m5.5-p2] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m5.5-p2] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m5.5-p2] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m5.5-p2] $BOTS bots"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"

# --- M5.5-P2 counter: max across telemetry windows (reset each telemetry second) ---
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
supp=$(maxof supp); kills=$(maxof kills); downed=$(maxof downed)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

winner=""
if [ -n "$over_line" ]; then
	winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
	elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
	echo "[m5.5-p2] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
else
	echo "[m5.5-p2] no [match] OVER within ${MAX_WAIT}s — peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
fi
echo "[m5.5-p2] supp=${supp:-0} kills=${kills:-0} downed=${downed:-0}"

fail=0

# Winner / supp are REPORTED here (warn) — the suppression mechanic is proven by unit tests; the
# hard supp>0 gate lives in docker/run-m5.5-p2-gate.sh under 128-bot density.
if [ -n "$over_line" ]; then
	if [ "$winner" = "0" ] || [ "$winner" = "1" ]; then
		echo "[m5.5-p2] winner OK (${winner})"
	else
		echo "[m5.5-p2] NOTE: no attrition winner under low pressure — armor/suppression proven by unit tests (AGENTS.md §10)"
	fi
else
	echo "[m5.5-p2] NOTE: no attrition winner under low pressure — armor/suppression proven by unit tests (AGENTS.md §10)"
fi
[ "${supp:-0}" -ge 1 ] && echo "[m5.5-p2] note: supp=${supp} (near-miss suppression accruals in-match)"

# Tick budget — always hard-gated
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: M5.5-P2 (laptop smoke) — supp=${supp:-0} kills=${kills:-0} downed=${downed:-0} peak=${peak_tick}ms"
exit $fail
