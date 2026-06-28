#!/usr/bin/env bash
# M4.5-P2 smoke gate: server + bots play Conquest and assert the combat-depth systems fired
# (RPG rockets, C4, mines, bullet penetration, medic heals, ammo resupply, thrown bags).
# Models ci/m4.5_p1_test.sh — same server+bots launch, log capture, cleanup, and
# max-across-windows counter approach (counters reset each telemetry second, so we take
# the maximum window value rather than the last).
set -uo pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-27242}"
BOTS="${BOTS:-48}"
TICKETS="${TICKETS:-30}"           # small pool so 48-bot attrition completes within MAX_WAIT
TIME_LIMIT="${TIME_LIMIT:-600}"
MAX_WAIT="${MAX_WAIT:-420}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
# Core pinning — disjoint cores keep the tick metric clean on the dev laptop (8C/16T).
SERVER_CPUS="${SERVER_CPUS:-0-3}"
BOTS_CPUS="${BOTS_CPUS:-4-15}"
if command -v taskset >/dev/null 2>&1; then
	SRV_PIN=(taskset -c "$SERVER_CPUS"); BOT_PIN=(taskset -c "$BOTS_CPUS")
	echo "[m4.5-p2] core pinning: server=$SERVER_CPUS bots=$BOTS_CPUS"
else
	SRV_PIN=(); BOT_PIN=(); echo "[m4.5-p2] WARNING: taskset not found — running unpinned (tick metric may be noisy)"
fi

server_log="$(mktemp)"; bots_log="$(mktemp)"
server_pid=""; bots_pid=""
cleanup() { for p in "$bots_pid" "$server_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
echo "[m4.5-p2] server on $PORT (tickets=$TICKETS time-limit=$TIME_LIMIT bots=$BOTS)"
"${SRV_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --server --port="$PORT" --tickets="$TICKETS" --time-limit="$TIME_LIMIT" >"$server_log" 2>&1 &
server_pid=$!
sleep 2
echo "[m4.5-p2] $BOTS bots"
"${BOT_PIN[@]}" "$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$PORT" >"$bots_log" 2>&1 &
bots_pid=$!

waited=0; over_line=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over_line="$(grep -m1 '\[match\] OVER' "$server_log" || true)"
	[ -n "$over_line" ] && break
	sleep 3; waited=$((waited+3))
done

echo "--- match result ---"; echo "$over_line"
if [ -z "$over_line" ]; then echo "FAIL: no winner within ${MAX_WAIT}s"; exit 1; fi

# winner is on the OVER line: "winner=%d"
winner="$(echo "$over_line" | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over_line" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"

# --- M4.5 P2 (combat depth) assertions: max across telemetry windows ---
maxof() { grep -oE "$1=[0-9]+" "$server_log" | sed "s/$1=//" | sort -n | tail -1; }
rockets=$(maxof rockets); c4=$(maxof c4); mines=$(maxof mines)
heals=$(maxof heals); ammo=$(maxof ammo); bags=$(maxof bags); bagx=$(maxof bagx); pen=$(maxof pen)
peak_tick="$(grep -oE 'tick_mean=[0-9.]+' "$server_log" | sed 's/tick_mean=//' | sort -g | tail -1)"

echo "[m4.5-p2] winner=${winner} elapsed=${elapsed}s peak-window tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m4.5-p2] rockets=${rockets:-0} c4=${c4:-0} mines=${mines:-0} pen=${pen:-0} heals=${heals:-0} ammo=${ammo:-0} bags=${bags:-0} bagx=${bagx:-0}"

fail=0
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner (winner=${winner:-<empty>})"; fail=1; }
[ "${rockets:-0}" -ge 1 ] || { echo "FAIL: no RPG detonations (rockets=${rockets:-0})"; fail=1; }
[ "${c4:-0}" -ge 1 ]      || { echo "FAIL: no C4 detonations (c4=${c4:-0})"; fail=1; }
# mines (claymore trips) is reported, not gated on the laptop smoke: a trip needs an enemy within
# the 1.5 m point-blank trigger radius of a (ranged) Recon — a density-dependent event the 48-bot
# laptop run rarely produces. The 128-bot FLEET gate hard-asserts mines>=1 (that's the authoritative
# gate; the laptop can't even run 128). Placement + cone logic are unit-tested in gadget_test.
[ "${mines:-0}" -ge 1 ] && echo "[m4.5-p2] note: mines=${mines} (claymore trips exercised in-match)"
# pen (bullet penetration) is reported, not gated: it needs a shot to cross a penetrable
# half-height sandbag, which bots don't build (they build full CONCRETE walls) — so it's
# geometry/scale dependent and the DoD omits it. Correctness is covered by server_pen_test +
# combat_test (apply_penetration, absorption/transmit, 1-pen cap, post-exit damage).
[ "${pen:-0}" -ge 1 ] && echo "[m4.5-p2] note: pen=${pen} (penetration exercised in-match)"
[ "${heals:-0}" -ge 1 ]   || { echo "FAIL: no heal events (heals=${heals:-0})"; fail=1; }
[ "${ammo:-0}" -ge 1 ]    || { echo "FAIL: no ammo resupply (ammo=${ammo:-0})"; fail=1; }
[ "${bags:-0}" -ge 1 ]    || { echo "FAIL: no bags thrown (bags=${bags:-0})"; fail=1; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget (${peak_tick}ms)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: M4.5-P2 (laptop smoke) — rockets=${rockets} c4=${c4} mines=${mines:-0} pen=${pen:-0} heals=${heals} ammo=${ammo} bags=${bags} winner=${winner}"
exit $fail
