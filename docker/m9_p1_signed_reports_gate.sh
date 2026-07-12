#!/usr/bin/env bash
# M9-P1 Signed Match Reports — live gate (ADR-0011).
# Proves end-to-end: a signing-configured game-server match -> HMAC-signed /ingest/match
# -> backend verifies -> matches.trusted=TRUE in Postgres; and the negative paths:
# a forged signature is rejected 401, and an unsigned report is accepted but trusted=FALSE.
# Under REQUIRE_SIGNED_INGEST=true, the unsigned report is rejected 401 instead.
#
# This is a correctness/data-flow gate (small bot count on the canonical gameplay map),
# NOT the 128-bot perf fleet — same posture as the M20 run-stats-p1-gate.sh it mirrors.
#
# Usage:  ./m9_p1_signed_reports_gate.sh
# Env:    PORT BOTS TICKETS TIME_LIMIT MAX_WAIT MAP GODOT
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$(pwd)"

GODOT="${GODOT:-godot}"
PORT="${PORT:-28323}"
BOTS="${BOTS:-24}"
TICKETS="${TICKETS:-20}"
TIME_LIMIT="${TIME_LIMIT:-150}"
MAX_WAIT="${MAX_WAIT:-180}"
MAP="${MAP:-conquest_town}"
PROJECT="bf-m9-p1"
TOKEN="gate-token"
KEY_ID="game2-dev-1"
SECRET="gate-secret"
ENDPOINT="http://localhost:8000"
BE=(docker compose -p "$PROJECT" -f "$ROOT/backend/docker-compose.yml")
PSQL=("${BE[@]}" exec -T db psql -U blockfire -d blockfire_stats)

srv_pids=()
cleanup() { for p in "${srv_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

# --- one signed match: $1=port $2=log ; returns when server logs [match] OVER (or MAX_WAIT) ---
play_signed_match() {
	local port="$1" log="$2"
	"$GODOT" --headless --path "$ROOT" -- --server --port="$port" --map="$MAP" \
		--tickets="$TICKETS" --time-limit="$TIME_LIMIT" \
		--stats-endpoint="$ENDPOINT" --stats-token="$TOKEN" \
		--stats-signing-key-id="$KEY_ID" --stats-signing-secret="$SECRET" >"$log" 2>&1 &
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

echo "[m9-p1] fresh backend (db+api) with INGEST_SIGNING_KEYS=$KEY_ID:*** …"
"${BE[@]}" down -v >/dev/null 2>&1
INGEST_TOKEN="$TOKEN" INGEST_SIGNING_KEYS="$KEY_ID:$SECRET" "${BE[@]}" up --build -d db api >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null || { echo "FAIL: backend not healthy"; exit 1; }
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

log="$(mktemp --suffix=.log)"
echo "[m9-p1] signed match on :$PORT map=$MAP …"
over="$(play_signed_match "$PORT" "$log")"
echo "  $over"
[ -n "$over" ] || { echo "FAIL: signed match produced no winner"; sed -n '1,40p' "$log"; exit 1; }
scripterr="$(grep -icE 'SCRIPT ERROR|Parse Error' "$log" || true)"
[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: server SCRIPT/Parse errors"; exit 1; }

echo "[m9-p1] out-of-band forged POST (bad signature) — must 401 …"
NOW="$(date +%s)"
FORGED_JSON='{"report_version":1,"match":{"match_id":"forged-oob","server_id":"x","map":"m","mode":"conquest"},"players":[]}'
forged_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/ingest/match" \
	-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
	-H "X-BF-Key-Id: $KEY_ID" -H "X-BF-Timestamp: $NOW" -H "X-BF-Signature: $(printf '0%.0s' {1..64})" \
	-d "$FORGED_JSON")"
echo "  forged POST -> HTTP $forged_code"

echo "[m9-p1] out-of-band UNSIGNED POST — must 202 and land trusted=false …"
UNSIGNED_JSON='{"report_version":1,"match":{"match_id":"unsigned-oob","server_id":"x","map":"m","mode":"conquest"},"players":[]}'
unsigned_code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/ingest/match" \
	-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
	-d "$UNSIGNED_JSON")"
echo "  unsigned POST -> HTTP $unsigned_code"

echo "--- results ---"
"${PSQL[@]}" -c "SELECT match_id, trusted, complete, winner FROM matches ORDER BY ingested_at;"
signed_trusted="$("${PSQL[@]}" -tAc "SELECT bool_and(trusted) FROM matches WHERE match_id NOT IN ('unsigned-oob','forged-oob') AND complete;")"
unsigned_trusted="$("${PSQL[@]}" -tAc "SELECT trusted FROM matches WHERE match_id='unsigned-oob';")"
forged_exists="$("${PSQL[@]}" -tAc "SELECT count(*) FROM matches WHERE match_id='forged-oob';")"

ok=1
[ "$(echo "$signed_trusted" | tr -d '[:space:]')" = "t" ] || { echo "FAIL: the real signed match is not trusted=t (got '$signed_trusted')"; ok=0; }
[ "$forged_code" = "401" ] || { echo "FAIL: forged POST expected 401, got $forged_code"; ok=0; }
[ "$(echo "$forged_exists" | tr -d '[:space:]')" = "0" ] || { echo "FAIL: forged POST created a matches row (should be rejected before write)"; ok=0; }
[ "$unsigned_code" = "202" ] || { echo "FAIL: unsigned POST expected 202, got $unsigned_code"; ok=0; }
[ "$(echo "$unsigned_trusted" | tr -d '[:space:]')" = "f" ] || { echo "FAIL: unsigned match expected trusted=f, got '$unsigned_trusted'"; ok=0; }

if [ "$ok" -eq 1 ]; then echo "M9-P1 SIGNED-REPORTS GATE: PASS"; exit 0; else echo "M9-P1 SIGNED-REPORTS GATE: FAIL"; exit 1; fi
