#!/usr/bin/env bash
# One-command isolated M5.5-P2 (Survivability: armor class + suppression) gate via Docker
# (single host, `full` profile): brings up the dedicated server + 128-bot fleet in separate
# containers (server uncontended on its own cores), waits for the match to finish, and applies
# the M5.5-P2 assertions on top of the M3 baseline.
#
# Host: this runs LOCALLY on game2 (14900KS / CachyOS, 32 threads) — the full-time dev+gate host.
# No cross-host ssh. Pin the server to isolated P-cores so the bot fleet can't steal its cycles.
#
# M5.5-P2 verdict = M3 criteria (valid winner, peak-window tick < budget, match ended via tickets
# not the time fail-safe) PLUS the survivability counter (max across windows):
#   supp >= 1  — at least one near-miss suppression accrual fired (an enemy bullet passed within
#                Suppress.SUPPRESS_RADIUS of a pawn) — proves suppression is live under load.
# Armor-class TTK variance rides the existing kill/down counters (bots span all four classes ->
# all three armor tiers). Bandwidth (agg) is reported so the +1-byte SELF_STATE suppression field
# is confirmed not to blow the budget.
#
# COMBAT-AI / DENSITY CAVEAT: suppression accrues only when enemy bullets pass near pawns, which
# needs both firing AI and density. As of 2026-06-23 bots fire (M5.5-P1 fleet showed proj=207).
# If supp=0 fires here, it means the fleet did not stage enough near-misses (re-check AI/density);
# the suppression MECHANIC itself is proven deterministically by tests/projectile_gate_test.gd
# (test_near_miss_accrues_suppression) + tests/suppress_test.gd (AGENTS.md §10).
#
# Usage:  ./run-m5.5-p2-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# game2 example (server on isolated P-cores, bots on the rest of the 32 threads):
#   SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 ./run-m5.5-p2-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m5.5-p2] building + starting server + bot fleet (armor + suppression enabled, uncontended server)…"
"${DC[@]}" up -d --build

waited=0; over=""
while [ "$waited" -lt "$MAX_WAIT" ]; do
	over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
	[ -n "$over" ] && break
	sleep 5; waited=$((waited + 5))
done

srvlog="$("${DC[@]}" logs server 2>/dev/null)"
# Persist the full server log as recorded gate evidence (AGENTS.md §6).
srvlog_file="srvlog-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[m5.5-p2] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M5.5-P2 DOCKER GATE: FAIL"; exit 1
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

# M5.5-P2 counter is per-window (reset each telemetry second); take the max across windows.
maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
supp="$(maxof supp)"; kills="$(maxof kills)"; downed="$(maxof downed)"

echo "[m5.5-p2] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) peak agg=${peak_agg:-?}Mbit/s"
echo "[m5.5-p2] supp=${supp:-0} kills=${kills:-0} downed=${downed:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }

# --------------------------------------------------------------------------
# NOTE: if supp fires with value 0, this is NOT a suppression bug — it means the fleet did not
# stage enough enemy near-misses (re-check AI/density). The suppression MECHANIC is proven
# deterministically by tests/projectile_gate_test.gd + tests/suppress_test.gd (AGENTS.md §10).
# --------------------------------------------------------------------------
[ "${supp:-0}" -ge 1 ] || { echo "FAIL: no suppression accruals (supp=${supp:-0}) — if near-miss density was low this is expected; see tests/projectile_gate_test.gd"; ok=0; }

awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M5.5-P2 DOCKER GATE: PASS"; exit 0; else echo "M5.5-P2 DOCKER GATE: FAIL"; exit 1; fi
