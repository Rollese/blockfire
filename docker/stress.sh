#!/usr/bin/env bash
# M8 — one-command 128-bot stress run (the M8 gate). Spins the dedicated server + a 128-bot fleet
# in Docker on a single host, runs a full Conquest match to a winner, then prints a PASS/FAIL
# verdict and a telemetry summary. This is the canonical operator entrypoint; the per-milestone
# run-*-gate.sh scripts remain for their specific feature assertions.
#
# Host: game2 (14900KS / CachyOS, 32 threads). Pin the server to isolated P-cores.
# Defaults to conquest_proving_grounds (comfortable tick budget). For the dense high-load variant
# (peak snapshot + combat + destruction cost), run with MAP=conquest_town.
#
# Verdict (M8 gate — docs/milestones/M8-hardening-ops.md):
#   - a valid Conquest winner appears (match completes)
#   - peak-window server tick_mean < TICK_BUDGET_MS (30 Hz held within budget)
#   - match ended via tickets, not the time fail-safe
#   - [bot-perf] telemetry present (bot-driver CPU scales to 128)
#   - match not inert (cap_events >= 1 OR kills >= 1) — capture-race or attrition both valid
# Reported: peak tick, aggregate bandwidth, peak players, kills, bot-driver ai_us_mean.
#
# Usage:   ./stress.sh
# Env:     MAP TIME_LIMIT TICK_BUDGET_MS MAX_WAIT PORT TICKETS BOT_COUNT BOT_REPLICAS
#          SERVER_CPUS BOTS_CPUS BOOT_DELAY LABEL
#          ENCODER=native|gd — snapshot encoder A/B (ADR-0003); default native
# game2:   SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./stress.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./_gate_lib.sh

# ADR-0003: the fleet gate must exercise the shipped (native) encoder — refuse to run without
# the built .so unless the GDScript reference path was explicitly requested (ENCODER=gd).
export ENCODER="${ENCODER:-native}"
if [ "$ENCODER" != "gd" ] && [ ! -f ../native/snapshot_encoder/target/release/libsnapshot_encoder.so ]; then
	echo "FATAL: native snapshot encoder not built — run:"
	echo "  cargo build --release --manifest-path ../native/snapshot_encoder/Cargo.toml"
	echo "  (or set ENCODER=gd for a reference-path run)"
	exit 1
fi

TIME_LIMIT="${TIME_LIMIT:-900}"; export TIME_LIMIT
TICK_BUDGET_MS="${TICK_BUDGET_MS:-33.3}"
MAX_WAIT="${MAX_WAIT:-720}"
LABEL="${LABEL:-stress}"

trap gate_cleanup EXIT

gate_up
over="$(gate_wait_over "$MAX_WAIT")"
srvlog="$(gate_srvlog)"
botperf="$(gate_botperf_line)"

srvlog_file="srvlog-${LABEL}-$(date +%Y%m%d-%H%M%S).log"
printf '%s\n' "$srvlog" > "$srvlog_file"
echo "[stress] full server log saved to $(pwd)/$srvlog_file"
echo "--- match result ---"; echo "$over"
if [ -z "$over" ]; then
	echo "FAIL: no winner within ${MAX_WAIT}s"; echo "$srvlog" | tail -25
	gate_evidence "$LABEL" "FAIL" "$srvlog_file" "no winner within ${MAX_WAIT}s"
	echo "STRESS GATE: FAIL"; exit 1
fi

winner="$(gate_field "$over" winner)"
elapsed="$(gate_field "$over" elapsed)"
cap_events="$(gate_field "$over" cap_events)"
peak_tick="$(gate_peak "$srvlog" tick_mean)"
peak_agg="$(gate_peak "$srvlog" agg)"
kills="$(gate_maxof "$srvlog" kills)"
players="$(gate_maxof "$srvlog" players)"
ai_us="$(echo "$botperf" | grep -oE 'ai_us_mean=[0-9.]+' | sed 's/ai_us_mean=//')"

echo "[stress] winner=${winner} elapsed=${elapsed}s peak tick=${peak_tick}ms (budget ${TICK_BUDGET_MS}) agg=${peak_agg:-?}Mbit/s players=${players:-?} kills=${kills:-0} bot-perf ai_us_mean=${ai_us:-?}us"

ok=1
[ "$winner" = "0" ] || [ "$winner" = "1" ] || { echo "FAIL: no valid winner"; ok=0; }
[ -n "$botperf" ] || { echo "FAIL: no [bot-perf] telemetry — bot-driver CPU scaling unproven"; ok=0; }
[ "${cap_events:-0}" -ge 1 ] || [ "${kills:-0}" -ge 1 ] || { echo "FAIL: match inert — no captures AND no kills"; ok=0; }
awk "BEGIN{exit !(${peak_tick:-999} < $TICK_BUDGET_MS)}" || { echo "FAIL: peak-window tick over budget"; ok=0; }
awk "BEGIN{exit !(${elapsed:-99999} < $TIME_LIMIT)}" || { echo "FAIL: match hit time fail-safe, not tickets"; ok=0; }
verdict=$([ "$ok" -eq 1 ] && echo PASS || echo FAIL)
gate_evidence "$LABEL" "$verdict" "$srvlog_file" \
	"winner=${winner} elapsed=${elapsed}s peak_tick=${peak_tick}ms budget=${TICK_BUDGET_MS}ms agg=${peak_agg:-?}Mbit/s players=${players:-?} kills=${kills:-0} cap_events=${cap_events:-0} ai_us_mean=${ai_us:-?}us map=${MAP:-default}"
echo "STRESS GATE: $verdict"; [ "$ok" -eq 1 ] && exit 0 || exit 1
