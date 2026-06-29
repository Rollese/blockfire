#!/usr/bin/env bash
# One-command isolated M12-P3 (Squad-Leader FOB) gate via Docker (single host, `full` profile):
# brings up the dedicated server + 128-bot fleet in separate containers (server uncontended on its
# own cores), waits for the match to finish, and applies the M12-P3 assertions on top of the
# M3 baseline.
#
# M12-P3 verdict = M3 criteria (valid winner, points captured, peak-window tick < budget, match ended
# via tickets not the time fail-safe) PLUS the squad-leader-FOB headline (max across windows):
#   fobs_built >= 1  — at least one FOB site shovelled to completion by a squad leader + drillers
# The other three FOB counters are emergent/density-dependent and REPORTED, not gated (AGENTS.md §10):
#   fob_spawns      — a squad respawned at its FOB
#   fob_disabled    — a FOB's spawn was disabled by enemy proximity
#   fobs_destroyed  — a built FOB was destroyed
# All counters are per-window (reset each telemetry second); we take the max across all windows.
#
# Usage:  ./run-m12-p3-gate.sh
# Env:    TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#         SERVER_CPUS BOTS_CPUS BOOT_DELAY  (passed through to compose)
# Fleet example (game2 14900KS, server on isolated cores):
#   SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-m12-p3-gate.sh
#
# See AGENTS.md §8 for fleet conventions.
set -uo pipefail
cd "$(dirname "$0")"

TIME_LIMIT="${TIME_LIMIT:-900}"        # give the match room with 128 bots
export TIME_LIMIT                       # compose substitutes ${TIME_LIMIT} into the server command
MAP="${MAP:-conquest_proving_grounds}"  # same map as M12-P2 (build-site path validated there)
export MAP
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
DC=(docker compose -f docker-compose.yml --profile full)

cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[m12-p3] building + starting server + bot fleet (squad-leader FOB, uncontended server)…"
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
echo "[m12-p3] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	echo "M12-P3 DOCKER GATE: FAIL"; exit 1   # always emit the verdict line so callers can poll for it
fi

winner="$(echo "$over"     | sed -n 's/.*winner=\(-\?[0-9]*\).*/\1/p')"
elapsed="$(echo "$over"    | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')"
cap_events="$(echo "$over" | sed -n 's/.*cap_events=\([0-9]*\).*/\1/p')"
peak_tick="$(echo "$srvlog" | grep -oE 'tick_mean=[0-9.]+' | sed 's/tick_mean=//' | sort -g | tail -1)"
agg="$(echo "$srvlog" | grep -oE 'agg=[0-9.]+' | sed 's/agg=//' | sort -g | tail -1)"

# M12-P3 FOB counters are per-window (reset each telemetry second); take the max.
maxof() { echo "$srvlog" | grep -oE "$1=[0-9]+" | sed "s/$1=//" | sort -n | tail -1; }
fobs_built="$(maxof fobs_built)"; fob_spawns="$(maxof fob_spawns)"
fob_disabled="$(maxof fob_disabled)"; fobs_destroyed="$(maxof fobs_destroyed)"

echo "[m12-p3] winner=${winner} elapsed=${elapsed}s cap_events=${cap_events} peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) agg=${agg:-?}Mbit/s"
echo "[m12-p3] fobs_built=${fobs_built:-0} fob_spawns=${fob_spawns:-0} fob_disabled=${fob_disabled:-0} fobs_destroyed=${fobs_destroyed:-0}"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || { echo "FAIL: no points were captured"; ok=0; }
# Live cooperative-FOB proof at scale: a FOB build site (BUILD_COST 800, min_builders 2) is shovelled to
# completion in-match by a squad leader (PLACE_FOB) + the large shovel-drillers converging on the same
# shared cell (exercises leader-only placement -> build-site path -> multi-builder accrual -> completion
# -> registry promotion -> telemetry, end to end). This is the ROBUST gate signal — the per-team leaders
# + the 8 large drillers all converge on ONE persistent shared site near base, so it completes every run.
[ "${fobs_built:-0}" -ge 1 ] || { echo "FAIL: no FOB cooperatively built (fobs_built=${fobs_built:-0})"; ok=0; }
# fob_spawns / fob_disabled / fobs_destroyed are REPORTED, not hard-gated — like M12-P2's built_small /
# dismantled / repaired they are emergent, density-dependent counters (AGENTS.md §10 — don't gate on
# bot-AI behaviour at scale). Every FOB sub-mechanic (spawn, vicinity-disable, destroy/reconcile) is
# proven DETERMINISTICALLY in the M12-P3 lifecycle functional test. The fleet gate proves budget +
# the live cooperative build.
[ "${fob_spawns:-0}" -ge 1 ] && echo "[m12-p3] note: fob_spawns=${fob_spawns} (squad respawned at a FOB in-match)"
[ "${fob_disabled:-0}" -ge 1 ] && echo "[m12-p3] note: fob_disabled=${fob_disabled} (FOB spawn disabled by enemy proximity)"
[ "${fobs_destroyed:-0}" -ge 1 ] && echo "[m12-p3] note: fobs_destroyed=${fobs_destroyed} (built FOB destroyed in-match)"
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "M12-P3 DOCKER GATE: PASS"; exit 0; else echo "M12-P3 DOCKER GATE: FAIL"; exit 1; fi
