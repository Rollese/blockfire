#!/usr/bin/env bash
# One-command isolated M3 gate via Docker (single host, `full` profile): brings up the
# dedicated server + bot fleet in separate containers, waits for the match to finish, and
# applies the same assertions as ci/m3_conquest_test.sh — but the server runs uncontended.
#
# For the cross-host setup (server bare-metal on the laptop, bots here), see README.md and
# use the `bots` profile instead; this script orchestrates the single-host case.
#
# Usage:  ./run-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-600}"
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-540}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[gate] building + starting server + bot fleet (uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M3 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"   | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"  | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
echo "[gate] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak-window mean tick=${peak_tick}ms (budget ${TICK_BUDGET_MS})"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M3 DOCKER GATE: PASS"; exit 0; else echo "M3 DOCKER GATE: FAIL"; exit 1; fi
