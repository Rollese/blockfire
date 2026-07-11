#!/usr/bin/env bash
# M20 Stats & Analytics — P1 live gate (game-server StatsReporter -> P1-A ingest API -> Postgres).
# Proves the full producer->API->DB pipeline end-to-end on a real bot match, plus the NDJSON
# backend-down durability guarantee (no data loss across an API outage).
#
# Runs the backend docker-compose stack (db/api/worker) and, on the HOST, a Godot dedicated
# server (--stats-endpoint) + a separate bot-driver process. Not the 128-bot perf fleet — this
# is a correctness/data-flow gate, so a small bot count on the canonical gameplay map is enough.
#
# Usage:  ./run-stats-p1-gate.sh
# Env:    PORT BOTS TICKETS TIME_LIMIT MAX_WAIT MAP INGEST_TOKEN GODOT
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$(pwd)"

GODOT="${GODOT:-godot}"
PORT="${PORT:-28123}"
BOTS="${BOTS:-24}"
TICKETS="${TICKETS:-30}"
TIME_LIMIT="${TIME_LIMIT:-240}"
MAX_WAIT="${MAX_WAIT:-260}"
MAP="${MAP:-conquest_town}"
TOKEN="${INGEST_TOKEN:-dev-secret}"
ENDPOINT="http://localhost:8000"
SPOOL="$HOME/.local/share/godot/app_userdata/Blockfire/stats_spool.ndjson"
BE=(docker compose -f "$ROOT/backend/docker-compose.yml")
PSQL=("${BE[@]}" exec -T db psql -U blockfire -d blockfire_stats)

srv_pids=()
cleanup() { for p in "${srv_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

# --- one match: $1=port, returns when the server logs [match] OVER (or MAX_WAIT elapses) ---
play_match() {
	local port="$1" log="$2"
	"$GODOT" --headless --path "$ROOT" -- --server --port="$port" --map="$MAP" \
		--tickets="$TICKETS" --time-limit="$TIME_LIMIT" \
		--stats-endpoint="$ENDPOINT" --stats-token="$TOKEN" >"$log" 2>&1 &
	local sp=$!; srv_pids+=("$sp"); sleep 3
	"$GODOT" --headless --path "$ROOT" -- --bots --bot-count="$BOTS" --port="$port" --map="$MAP" \
		>"${log%.log}.bots.log" 2>&1 &
	local bp=$!; srv_pids+=("$bp")
	local waited=0 over=""
	while [ "$waited" -lt "$MAX_WAIT" ]; do
		over="$(grep -m1 '\[match\] OVER' "$log" || true)"; [ -n "$over" ] && break
		sleep 5; waited=$((waited+5))
	done
	sleep 3; kill "$bp" "$sp" 2>/dev/null; wait "$bp" "$sp" 2>/dev/null
	echo "$over"
}

echo "[stats-p1] bringing up backend (INGEST_TOKEN set)…"
INGEST_TOKEN="$TOKEN" "${BE[@]}" up --build -d >/dev/null 2>&1
for _ in $(seq 1 20); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null || { echo "FAIL: backend not healthy"; exit 1; }
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

log="$(mktemp --suffix=.log)"
echo "[stats-p1] match A (backend up) on :$PORT map=$MAP…"
overA="$(play_match "$PORT" "$log")"
echo "  $overA"
[ -n "$overA" ] || { echo "FAIL: match A produced no winner"; exit 1; }
scripterr="$(grep -icE 'SCRIPT ERROR|Parse Error' "$log" || true)"
[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: server SCRIPT/Parse errors"; exit 1; }

echo "[stats-p1] durability: match B with API DOWN (must spool), then drain on recovery…"
"${BE[@]}" stop api >/dev/null 2>&1
overB="$(play_match "$((PORT+1))" "$(mktemp --suffix=.log)")"
echo "  (api down) $overB"
spooled="$(wc -l <"$SPOOL" 2>/dev/null || echo 0)"
[ "${spooled:-0}" -ge 1 ] || { echo "FAIL: nothing spooled while API down (data would be lost)"; "${BE[@]}" start api >/dev/null 2>&1; exit 1; }
echo "  spooled $spooled records while down"
"${BE[@]}" start api >/dev/null 2>&1
for _ in $(seq 1 20); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
overC="$(play_match "$((PORT+2))" "$(mktemp --suffix=.log)")"
echo "  (api up) $overC"
remain="$(wc -l <"$SPOOL" 2>/dev/null || echo 0)"

echo "--- results ---"
"${PSQL[@]}" -c "SELECT match_id, winner, complete, duration_s, (SELECT count(*) FROM match_players mp WHERE mp.match_id=m.match_id) players, (SELECT count(*) FROM events e WHERE e.match_id=m.match_id) kills FROM matches m ORDER BY match_id;"
"${PSQL[@]}" -c "SELECT weapon_id, sum(shots) shots, sum(hits) hits, round(sum(hits)::numeric/nullif(sum(shots),0),3) hit_rate FROM match_player_weapons GROUP BY weapon_id ORDER BY shots DESC;"
matches="$("${PSQL[@]}" -tAc 'SELECT count(*) FROM matches;')"

ok=1
[ "${matches:-0}" -ge 3 ] || { echo "FAIL: expected >=3 matches (A + recovered B + C), got $matches"; ok=0; }
[ "${remain:-1}" -eq 0 ] || { echo "FAIL: spool not fully drained after recovery ($remain left)"; ok=0; }
if [ "$ok" -eq 1 ]; then echo "STATS P1 GATE: PASS"; exit 0; else echo "STATS P1 GATE: FAIL"; exit 1; fi
