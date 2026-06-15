#!/usr/bin/env bash
# One-command isolated M4.5-P2 (Combat Depth) gate via Docker (single host, `full` profile):
# brings up the dedicated server + bot fleet in separate containers (server uncontended on its
# own cores), waits for the match to finish, and applies the M4.5-P2 assertions on top of the
# M3 baseline.
#
# M4.5-P2 verdict = M3 criteria (valid winner, points captured, peak-window tick < budget, match
# ended via tickets not the time fail-safe) PLUS the combat-depth counters (max across windows):
#   rockets >= 1  — at least one RPG rocket detonated
#   c4      >= 1  — at least one C4 detonation
#   mines   >= 1  — at least one claymore/mine triggered
#   pen     >= 1  — at least one bullet penetrated a thin material
#   heals   >= 1  — at least one medic heal dispensed (active or bag)
#   ammo    >= 1  — at least one ammo resupply (active or bag)
#   bags    >= 1  — at least one supply/medic bag thrown
# bagx (bags exhausted) is reported but not gated — pools may not drain within a match.
# All counters are per-window (reset each telemetry second); we take the max across all windows.
#
# Usage:  ./run-m4.5-p2-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# Fleet example (game2 14900KS / unraid W-2275, server on isolated cores):
#   SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-m4.5-p2-gate.sh
#
# See AGENTS.md §8 for unraid fleet conventions (stay confined to /mnt/app/blockfire).
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m4.5-p2] building + starting server + bot fleet (combat depth enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
# Persist the full server log (telemetry + [perf] breakdown) as recorded gate evidence
# (AGENTS.md §6) and for post-run tick-budget diagnosis once containers are torn down.
srvlog_file="srvlog-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[m4.5-p2] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M4.5-P2 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"

# P2 combat-depth counters are per-window (reset each telemetry second); take the max across windows.
maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
rockets="$(maxof rockets)"; c4="$(maxof c4)"; mines="$(maxof mines)"; pen="$(maxof pen)"
heals="$(maxof heals)"; ammo="$(maxof ammo)"; bags="$(maxof bags)"; bagx="$(maxof bagx)"

echo "[m4.5-p2] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"
echo "[m4.5-p2] rockets=${rockets:-0} c4=${c4:-0} mines=${mines:-0} pen=${pen:-0} heals=${heals:-0} ammo=${ammo:-0} bags=${bags:-0} bagx=${bagx:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
[ "${rockets:-0}" -ge 1 ] || { echo "FAIL: no RPG detonations (rockets=${rockets:-0})"; ok=0; }
[ "${c4:-0}" -ge 1 ]      || { echo "FAIL: no C4 detonations (c4=${c4:-0})"; ok=0; }
[ "${mines:-0}" -ge 1 ]   || { echo "FAIL: no mine triggers (mines=${mines:-0})"; ok=0; }
[ "${pen:-0}" -ge 1 ]     || { echo "FAIL: no bullet penetrations (pen=${pen:-0})"; ok=0; }
[ "${heals:-0}" -ge 1 ]   || { echo "FAIL: no heal events (heals=${heals:-0})"; ok=0; }
[ "${ammo:-0}" -ge 1 ]    || { echo "FAIL: no ammo resupply (ammo=${ammo:-0})"; ok=0; }
[ "${bags:-0}" -ge 1 ]    || { echo "FAIL: no bags thrown (bags=${bags:-0})"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M4.5-P2 DOCKER GATE: PASS"; exit 0; else echo "M4.5-P2 DOCKER GATE: FAIL"; exit 1; fi
