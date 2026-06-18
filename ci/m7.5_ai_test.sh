#!/usr/bin/env bash
# M7.5 AI smoke gate (single-host bare-metal, run on game2): server + bots play Conquest under
# the new AI brain (AiDriver) and assert the match converges (a winner appears), the AI telemetry
# is present, and the tick budget holds.
#
# Host note: game2 (14900KS / CachyOS) is the full-time dev+gate host. This is the lightweight
# ≤48-bot single-process smoke; the 128-bot Docker FLEET run is deferred for host coordination.
#
# Models ci/m4.5_p3_test.sh exactly — same shebang/set flags, GODOT/ROOT/PORT vars, taskset
# core-pinning, full-unit-suite-green precondition, server+bots launch, log capture,
# max-across-windows counter scrape, and cleanup/trap.
#
# Gate (smoke):
#   (a) full unit suite 0 failed
#   (b) a valid Conquest winner= appears in the server log (match converges under the AI brain)
#   (c) peak-window tick parsed and REPORTED; treated as FAIL if >= TICK_BUDGET_MS
#   (d) [bot-perf] line present in bots log (bot-driver CPU telemetry active)
#
# Reported (not hard-gated): kills/combat counters from telemetry; ai_us_mean from [bot-perf].
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
	echo "[m7.5-ai] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m7.5-ai] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

# --- Full unit suite must be green before the integration smoke (DoD) ---
echo "[m7.5-ai] running full unit suite…"
unit_log="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" -- --test >"$unit_log" 2>&1
unit_line="$(grep -oE 'TESTS: [0-9]+ run, [0-9]+ failed' "$unit_log" | tail -1)"
echo "[m7.5-ai] unit suite: ${unit_line:-<none>}"
if ! echo "$unit_line" | grep -q ', 0 failed'; then
	echo "FAIL: unit suite not green"; tail -20 "$unit_log"; exit 1
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

echo "[m7.5-ai] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m7.5-ai] $BOTS bots (seed=12345)"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" seed=12345 >"$bots_log" 2>&1 &
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

# --- M7.5 AI counters: max across telemetry windows ---
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
kills=$(maxof kills); shots=$(maxof shots); downed=$(maxof downed)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

# --- Bot-driver AI telemetry ---
bot_perf_line="$(grep -m1 '\[bot-perf\]' "$bots_log" || true)"
ai_us_mean="$(echo "$bot_perf_line" | grep -oE 'ai_us_mean=[0-9.]+' | sed 's/ai_us_mean=//' || true)"

echo "[m7.5-ai] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m7.5-ai] kills=${kills:-0} shots=${shots:-0} downed=${downed:-0}"
echo "[m7.5-ai] bot-perf: ${bot_perf_line:-<none>}"

fail=0
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner (winner=${winner:-<empty>})"; fail=1; }
[ -n "$bot_perf_line" ] || { echo "FAIL: no [bot-perf] line in bots log (AI telemetry missing)"; fail=1; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || {
	echo "FAIL: peak-window tick over budget (${peak_tick}ms >= ${TICK_BUDGET_MS}ms)"
	echo "  note: if host is contended, re-run with TICK_BUDGET_MS=<higher> to isolate tick from noise"
	fail=1
}

if [ "$fail" -eq 0 ]; then
	echo "M7.5 AI smoke PASS — winner=${winner} elapsed=${elapsed}s peak=${peak_tick}ms kills=${kills:-0} ai_us_mean=${ai_us_mean:-n/a}"
else
	echo "FAIL: M7.5 AI smoke — see above for reason(s)"
fi
exit $fail
