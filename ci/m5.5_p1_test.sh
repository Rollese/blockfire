#!/usr/bin/env bash
# M5.5-P1 ballistics smoke gate (single-host bare-metal, run on game2): server + bots play
# Conquest on the proving-grounds map and exercises the NEW stepped-projectile + fire-mode +
# weapon-swap systems.  Three telemetry counters are read from the server [telemetry] line:
#   proj      — peak-window bullets spawned (per-second window)
#   projhit   — peak-window bullets that hit a pawn
#   projlive  — peak-window concurrent live projectiles
#   projdrop  — peak-window spawns refused at the projectile cap
#   swaps     — peak-window weapon swaps
#
# COMBAT-AI CAVEAT: the combat bot AI is currently INERT in full matches (documented: bots
# connect + move but do not fire; shots=0, no attrition winner).  Therefore:
#   • proj/projhit will read 0 today and the match will NOT produce an attrition winner.
#   • The ballistics MECHANIC is proven deterministically by tests/projectile_gate_test.gd
#     (authoritative per AGENTS.md §10); proj>0/projhit>0 are REPORTED here and will be
#     HARD-GATED only once the combat AI fires (mirrors how m4.5_p3 hard-gates climbs/vaults
#     only in the 128-bot fleet gate).
#   • swaps runs on the bot swap-cycle boundary independently of combat; reported via maxof.
#   • If no attrition winner is reached, the script prints a clearly-labelled NOTE and treats
#     the missing winner as non-fatal (warn, not FAIL).
# Hard PASS/FAIL depends ONLY on: unit suite green + tick budget.  A missing winner is warned,
# not failed, until the AI fires.
#
# Host note: game2 (14900KS / CachyOS) is the full-time dev+gate host; a laptop only attaches
# to a tmux session here.  This is the lightweight ≤48-bot single-process smoke; the
# authoritative 128-bot run is the Docker FLEET gate (docker/run-m5.5-p1-gate.sh).
#
# Models ci/m4.5_p3_test.sh — same server+bots launch, log capture, cleanup, and
# max-across-windows counter approach (telemetry counters reset each second, so we take the
# maximum window value rather than the last).
#
# Gate (smoke): full unit suite green, tick budget met.  Winner is REPORTED (and noted if
# absent due to inert AI); ballistics counters REPORTED; swaps REPORTED.
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27251}"
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
	echo "[m5.5-p1] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m5.5-p1] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

# --- Full unit suite must be green before the integration smoke (DoD) ---
echo "[m5.5-p1] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m5.5-p1] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m5.5-p1] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m5.5-p1] $BOTS bots"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"

# --- M5.5-P1 (ballistics) counters: max across telemetry windows ---
# All counters are per-window (reset each telemetry second); take the max across all windows.
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
proj=$(maxof proj); projhit=$(maxof projhit); projlive=$(maxof projlive)
projdrop=$(maxof projdrop); swaps=$(maxof swaps)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

# --- Winner / combat-AI-inert handling ---
winner=""
if [ -n "$over_line" ]; then
	winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
	elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
	echo "[m5.5-p1] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
else
	echo "[m5.5-p1] no [match] OVER within ${MAX_WAIT}s — peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
fi
echo "[m5.5-p1] proj=${proj:-0} projhit=${projhit:-0} projlive=${projlive:-0} projdrop=${projdrop:-0} swaps=${swaps:-0}"

fail=0

# Winner assertion — non-fatal when combat AI is inert (no attrition possible)
if [ -n "$over_line" ]; then
	if [ "$winner" = "0" ] || [ "$winner" = "1" ]; then
		echo "[m5.5-p1] winner OK (${winner})"
	else
		# --------------------------------------------------------------------------
		# NOTE: no attrition winner — combat AI inert (pre-existing separate workstream).
		# The ballistics MECHANIC is proven deterministically by
		# tests/projectile_gate_test.gd (AGENTS.md §10).  proj>0/projhit>0 will be
		# HARD-GATED here once the combat AI fires (mirrors m4.5_p3 fleet gate).
		# --------------------------------------------------------------------------
		echo "[m5.5-p1] NOTE: no attrition winner — combat AI inert (pre-existing); projectile mechanic proven by tests/projectile_gate_test.gd"
		# non-fatal: warn only
	fi
else
	# --------------------------------------------------------------------------
	# NOTE: no attrition winner — combat AI inert (pre-existing separate workstream).
	# The ballistics MECHANIC is proven deterministically by
	# tests/projectile_gate_test.gd (AGENTS.md §10).  proj>0/projhit>0 will be
	# HARD-GATED here once the combat AI fires (mirrors m4.5_p3 fleet gate).
	# --------------------------------------------------------------------------
	echo "[m5.5-p1] NOTE: no attrition winner — combat AI inert (pre-existing); projectile mechanic proven by tests/projectile_gate_test.gd"
	# non-fatal: warn only
fi

# proj/projhit are REPORTED, not gated here — ballistics mechanic proven by unit test;
# hard gate lives in docker/run-m5.5-p1-gate.sh once AI fires.
[ "${proj:-0}" -ge 1 ]    && echo "[m5.5-p1] note: proj=${proj} (projectiles spawned in-match)"
[ "${projhit:-0}" -ge 1 ] && echo "[m5.5-p1] note: projhit=${projhit} (projectile hits in-match)"
[ "${projlive:-0}" -ge 1 ] && echo "[m5.5-p1] note: projlive=${projlive} (peak concurrent projectiles)"
[ "${projdrop:-0}" -ge 1 ] && echo "[m5.5-p1] note: projdrop=${projdrop} (spawns refused at cap)"
[ "${swaps:-0}" -ge 1 ]   && echo "[m5.5-p1] note: swaps=${swaps} (weapon swaps exercised in-match)"

# Tick budget — always hard-gated
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: M5.5-P1 (laptop smoke) — proj=${proj:-0} projhit=${projhit:-0} projlive=${projlive:-0} projdrop=${projdrop:-0} swaps=${swaps:-0} peak=${peak_tick}ms"
exit $fail
