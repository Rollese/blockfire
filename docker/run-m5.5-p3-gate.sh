#!/usr/bin/env bash
# One-command isolated M5.5-P3 (Melee & Throwables) gate via Docker (single host, `full` profile):
# brings up the dedicated server + 128-bot fleet in separate containers (server uncontended on its
# own cores), waits for the match to finish, and applies the M5.5-P3 assertions on top of the M3
# baseline.
#
# Host: runs LOCALLY on game2 (14900KS / CachyOS, 32 threads). Pin the server to isolated P-cores.
# Map defaults to conquest_proving_grounds (has buildings, so the Engineer sledge has structures).
#
# M5.5-P3 verdict = M3 criteria (valid winner, peak-window tick < budget, match ended via tickets
# not the time fail-safe) PLUS the reliable bot-exercised counters (max across windows):
#   melees  >= 1 — a melee swing landed
#   flashes >= 1 — a flashbang detonated
#   impacts >= 1 — an impact grenade detonated on contact
# REPORTED (warn, non-fatal — emergent / map-dependent, proven deterministically):
#   backstabs (rear-arc instakill), sledge (engineer demolition), flashblinds (LOS blinds).
# The MECHANICS are proven by tests/melee_test.gd + tests/grenade_test.gd + the deterministic
# resolves in tests/grenade_gate_test.gd (AGENTS.md §10). Bandwidth (agg) is reported so the +1-byte
# SELF_STATE blind field is confirmed within budget.
#
# Usage:  ./run-m5.5-p3-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS MAP
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# game2 example:  SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 ./run-m5.5-p3-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"
export TIME_LIMIT
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m5.5-p3] building + starting server + bot fleet (melee + throwables enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
srvlog_file="srvlog-m5.5-p3-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[m5.5-p3] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M5.5-P3 DOCKER GATE: FAIL"; exit 1
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
melees="$(maxof melees)"; backstabs="$(maxof backstabs)"; sledge="$(maxof sledge)"
flashes="$(maxof flashes)"; flashblinds="$(maxof flashblinds)"; impacts="$(maxof impacts)"

echo "[m5.5-p3] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) peak agg=${peak_agg:-?}Mbit/s"
echo "[m5.5-p3] melees=${melees:-0} backstabs=${backstabs:-0} sledge=${sledge:-0} flashes=${flashes:-0} flashblinds=${flashblinds:-0} impacts=${impacts:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }

# Reliable bot-exercised counters (hard-gated under 128-bot density).
[ "${melees:-0}"  -ge 1 ] || { echo "FAIL: no melee swings landed (melees=${melees:-0})"; ok=0; }
[ "${flashes:-0}" -ge 1 ] || { echo "FAIL: no flashbang detonations (flashes=${flashes:-0})"; ok=0; }
[ "${impacts:-0}" -ge 1 ] || { echo "FAIL: no impact-grenade detonations (impacts=${impacts:-0})"; ok=0; }

# Emergent / map-dependent — REPORTED, proven deterministically (AGENTS.md §10).
[ "${backstabs:-0}"   -ge 1 ] && echo "[m5.5-p3] note: backstabs=${backstabs} (rear-arc instakills in-match)" || echo "[m5.5-p3] note: backstabs=0 — proven by tests/grenade_gate_test.gd::test_knife_backstab_instakills"
[ "${sledge:-0}"      -ge 1 ] && echo "[m5.5-p3] note: sledge=${sledge} (engineer demolition in-match)"     || echo "[m5.5-p3] note: sledge=0 — proven by tests/grenade_gate_test.gd::test_sledge_engineer_damages_wall"
[ "${flashblinds:-0}" -ge 1 ] && echo "[m5.5-p3] note: flashblinds=${flashblinds} (LOS blinds in-match)"     || echo "[m5.5-p3] note: flashblinds=0 — proven by tests/grenade_gate_test.gd::test_flash_blinds_exposed_pawn"

awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M5.5-P3 DOCKER GATE: PASS"; exit 0; else echo "M5.5-P3 DOCKER GATE: FAIL"; exit 1; fi
