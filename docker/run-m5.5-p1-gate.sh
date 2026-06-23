#!/usr/bin/env bash
# One-command isolated M5.5-P1 (Ballistics) gate via Docker (single host, `full` profile):
# brings up the dedicated server + bot fleet in separate containers (server uncontended on its
# own cores), waits for the match to finish, and applies the M5.5-P1 assertions on top of the
# M4.5-P3 baseline.
#
# Host: this runs LOCALLY on game2 (14900KS / CachyOS, 32 threads) — the full-time dev+gate
# host. No cross-host ssh. A laptop only attaches to a tmux session on game2. Pin the server to
# isolated cores so the bot fleet can't steal its cycles.
#
# M5.5-P1 verdict = M3 criteria (valid winner, peak-window tick < budget, match ended via
# tickets not the time fail-safe) PLUS the ballistics counters (max across windows):
#   proj     >= 1  — at least one bullet was spawned (projectile system active)
#   projhit  >= 1  — at least one bullet hit a pawn (stepped-projectile collision working)
#   swaps    >= 1  — at least one weapon swap occurred (fire-mode/weapon-swap system active)
# projlive (peak concurrent live projectiles) and projdrop (spawns refused at cap) are
# REPORTED but not gated — they are density/timing dependent.
# All counters are per-window (reset each telemetry second); we take the max across all windows.
#
# COMBAT-AI CAVEAT: the combat bot AI is currently INERT in full matches (documented: bots
# connect + move but do not fire; shots=0, no attrition winner).  Therefore proj/projhit/swaps
# may all read 0 until the combat AI workstream lands.  If a hard assertion fires with value 0,
# this is NOT a ballistics bug — it means the AI is still inert.  The ballistics MECHANIC is
# proven deterministically by tests/projectile_gate_test.gd (AGENTS.md §10).  This fleet gate
# is intended to be run on game2 once the AI fires (separate M7.5 workstream).
#
# Usage:  ./run-m5.5-p1-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# game2 example (server on isolated cores, bots on the rest of the 32 threads):
#   SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 ./run-m5.5-p1-gate.sh
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m5.5-p1] building + starting server + bot fleet (ballistics systems enabled, uncontended server)…"
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
echo "[m5.5-p1] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M5.5-P1 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
peak_agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

# M5.5-P1 ballistics counters are per-window (reset each telemetry second); take the max across windows.
maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
proj="$(maxof proj)"; projhit="$(maxof projhit)"; projlive="$(maxof projlive)"
projdrop="$(maxof projdrop)"; swaps="$(maxof swaps)"

echo "[m5.5-p1] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) peak agg=${peak_agg:-?}Mbit/s"
echo "[m5.5-p1] proj=${proj:-0} projhit=${projhit:-0} projlive=${projlive:-0} projdrop=${projdrop:-0} swaps=${swaps:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }

# --------------------------------------------------------------------------
# NOTE: if any of the following assertions fire with value 0, this is NOT a
# ballistics bug — it means the combat AI is still inert (pre-existing M7.5
# workstream, separate from M5.5-P1).  The ballistics MECHANIC is proven
# deterministically by tests/projectile_gate_test.gd (AGENTS.md §10).
# Hard-gate these counters here; a 0 means: re-check AI workstream status.
# --------------------------------------------------------------------------
[ "${proj:-0}" -ge 1 ]   || { echo "FAIL: no projectiles spawned (proj=${proj:-0}) — if AI is inert this is expected; see tests/projectile_gate_test.gd"; ok=0; }
[ "${projhit:-0}" -ge 1 ] || { echo "FAIL: no projectile hits (projhit=${projhit:-0}) — if AI is inert this is expected; see tests/projectile_gate_test.gd"; ok=0; }
[ "${swaps:-0}" -ge 1 ]  || { echo "FAIL: no weapon swaps (swaps=${swaps:-0}) — if AI is inert this is expected"; ok=0; }
# projlive and projdrop are reported, not gated — density/timing dependent.
[ "${projlive:-0}" -ge 1 ] && echo "[m5.5-p1] note: projlive=${projlive} (peak concurrent projectiles)"
[ "${projdrop:-0}" -ge 1 ] && echo "[m5.5-p1] note: projdrop=${projdrop} (spawns refused at cap)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M5.5-P1 DOCKER GATE: PASS"; exit 0; else echo "M5.5-P1 DOCKER GATE: FAIL"; exit 1; fi
