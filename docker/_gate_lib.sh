#!/usr/bin/env bash
# Shared helpers for the Docker fleet gate/stress scripts (M8-P1). Source this after `cd`-ing to
# docker/, then call the functions. It defines `DC` (the compose invocation, `full` profile) and
# small scrapers over the server log. Env knobs (PORT/TICKETS/TIME_LIMIT/BOT_COUNT/BOT_REPLICAS/
# MAP/SERVER_CPUS/BOTS_CPUS/BOOT_DELAY) are read by docker-compose.yml, not here.
#
# Purpose: one place for the launch/wait/scrape/verdict logic that every run-*-gate.sh duplicated,
# so new gates (and stress.sh) are a few lines of criteria on top. Existing closed-milestone gate
# scripts are left as recorded evidence and not retrofitted.

DC=(docker compose -f docker-compose.yml --profile full)

# Tear the fleet down (containers + volumes). Safe to call from an EXIT trap.
gate_cleanup() { "${DC[@]}" down -v >/dev/null 2>&1 || true; }

# Build images and start server + bot fleet detached.
gate_up() {
	echo "[gate] building + starting dedicated server + bot fleet (uncontended server)…"
	"${DC[@]}" up -d --build
}

# Poll the server log until "[match] OVER" appears or $1 seconds elapse. Echoes the OVER line
# (empty on timeout).
gate_wait_over() {
	local max="$1" waited=0 over=""
	while [ "$waited" -lt "$max" ]; do
		over="$("${DC[@]}" logs server 2>/dev/null | grep -m1 '\[match\] OVER' || true)"
		[ -n "$over" ] && break
		sleep 5; waited=$((waited + 5))
	done
	echo "$over"
}

gate_srvlog() { "${DC[@]}" logs server 2>/dev/null; }   # full server log to stdout
gate_alllog() { "${DC[@]}" logs 2>/dev/null; }          # all containers (server + bots)

# Field-name matches are anchored on start-of-line or a space: `destroyed=` must NOT match
# the tail of `fobs_destroyed=` (nor struct=/rstruct=, blk=/dropblk=). The unanchored
# versions could false-PASS a >=1 criterion off the wrong counter.
# Scalar (possibly negative) named field from a single line: gate_field "$over" winner
gate_field() { echo "$1" | grep -oE "(^| )$2=-?[0-9]+" | head -1 | sed 's/.*=//'; }
# Max float value of a repeated `name=<float>` across a multi-line blob: gate_peak "$srvlog" tick_mean
gate_peak()  { echo "$1" | grep -oE "(^| )$2=[0-9.]+" | sed 's/.*=//' | sort -g | tail -1; }
# Max int value of a repeated `name=<int>` across a blob (per-window counters): gate_maxof "$srvlog" kills
gate_maxof() { echo "$1" | grep -oE "(^| )$2=[0-9]+" | sed 's/.*=//' | sort -n | tail -1; }

# The [bot-perf] line with the largest bots= count (bot-driver CPU telemetry). Empty if none.
gate_botperf_line() { gate_alllog | grep '\[bot-perf\]' | sort -t= -k2 -n | tail -1; }

# Write a small committable evidence file: verdict + scraped numbers + srvlog sha256. The raw
# srvlogs are gitignored (multi-MB), so this is what actually lands in git as the AGENTS §6
# "recorded evidence" — the sha256 ties it to the exact local log it summarizes.
# Usage: gate_evidence <label> <PASS|FAIL> <srvlog_file> "key=val key=val …"
gate_evidence() {
	local label="$1" verdict="$2" logfile="$3" summary="$4"
	local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=".."
	local dir="$root/docs/gate-evidence"
	mkdir -p "$dir"
	local out="$dir/$(date +%Y%m%d-%H%M%S)-${label}.txt"
	{
		echo "gate: $label"
		echo "date: $(date -Iseconds)"
		echo "host: $(hostname)"
		echo "git: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
		echo "verdict: $verdict"
		echo "summary: $summary"
		if [ -f "$logfile" ]; then
			echo "srvlog: $(basename "$logfile")"
			echo "srvlog_sha256: $(sha256sum "$logfile" | cut -d' ' -f1)"
		fi
	} > "$out"
	echo "[gate] evidence written to $out — commit it with the closing change"
}
