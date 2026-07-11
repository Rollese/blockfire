#!/usr/bin/env bash
# M20 Stats & Analytics — P2 live gate (player website: rollups + profiles + JSON API).
#
# Proves the full P2 pipeline end-to-end on a real bot match:
#   game-server StatsReporter -> P1-A ingest API -> Postgres -> worker rollup -> web/JSON pages.
# Asserts the rendered profile numbers are FAITHFUL to a direct SQL aggregate over the raw
# match tables, and that the dormant paths (Steam enrichment without a key, OpenID login) are
# present-but-inert.
#
# Runs the backend docker-compose stack (db/api/worker) under the `bf-p2` project (same one the
# pytest suite uses) and, on the HOST, a Godot dedicated server (--stats-endpoint) + a separate
# bot-driver process. Small bot count on the canonical gameplay map — this is a correctness gate.
#
# Usage:  ./run-stats-p2-gate.sh
# Env:    PORT BOTS TICKETS TIME_LIMIT MAX_WAIT MAP INGEST_TOKEN GODOT ROLLUP_WAIT
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$(pwd)"

GODOT="${GODOT:-godot}"
PORT="${PORT:-28223}"            # distinct from the P1 gate (28123) to avoid a concurrent agent
BOTS="${BOTS:-24}"
TICKETS="${TICKETS:-30}"
TIME_LIMIT="${TIME_LIMIT:-240}"
MAX_WAIT="${MAX_WAIT:-260}"
MAP="${MAP:-conquest_town}"
TOKEN="${INGEST_TOKEN:-dev-secret}"
ROLLUP_WAIT="${ROLLUP_WAIT:-70}"   # worker cadence is 30s; allow up to ~2 cycles
ENDPOINT="http://localhost:8000"
SPOOL="$HOME/.local/share/godot/app_userdata/Blockfire/stats_spool.ndjson"
PROJECT="bf-p2"
BE=(docker compose -p "$PROJECT" -f "$ROOT/backend/docker-compose.yml")
PSQL=("${BE[@]}" exec -T db psql -U blockfire -d blockfire_stats)
PSQLT=("${PSQL[@]}" -tAc)

srv_pids=()
cleanup() { for p in "${srv_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

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

echo "[stats-p2] bringing up full backend stack (db+api+worker) under project $PROJECT…"
INGEST_TOKEN="$TOKEN" "${BE[@]}" up --build -d >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null || { echo "FAIL: backend not healthy"; exit 1; }

echo "[stats-p2] clearing spool + truncating tables for a clean gate…"
rm -f "$SPOOL" 2>/dev/null || true
"${PSQL[@]}" -q -c "TRUNCATE matches, match_players, match_player_weapons, events, ingested_batches, players, player_profiles, player_weapon_totals;" >/dev/null 2>&1

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

log="$(mktemp --suffix=.log)"
echo "[stats-p2] playing match on :$PORT map=$MAP (bots=$BOTS)…"
over="$(play_match "$PORT" "$log")"
echo "  $over"
[ -n "$over" ] || { echo "FAIL: match produced no winner"; sed -n '$p' "$log"; exit 1; }
scripterr="$(grep -icE 'SCRIPT ERROR|Parse Error' "$log" || true)"
[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: server SCRIPT/Parse errors"; grep -m3 -E 'SCRIPT ERROR|Parse Error' "$log"; exit 1; }

echo "[stats-p2] waiting up to ${ROLLUP_WAIT}s for the worker to roll up profiles…"
profiles=0; waited=0
while [ "$waited" -lt "$ROLLUP_WAIT" ]; do
	profiles="$("${PSQLT[@]}" 'SELECT count(*) FROM player_profiles;' 2>/dev/null || echo 0)"
	[ "${profiles:-0}" -ge 1 ] && break
	sleep 5; waited=$((waited+5))
done
echo "  player_profiles rows: $profiles (after ${waited}s)"
[ "${profiles:-0}" -ge 1 ] || { echo "FAIL: worker never produced rollups"; exit 1; }

echo "--- DB snapshot ---"
"${PSQL[@]}" -c "SELECT count(*) matches, (SELECT count(*) FROM match_players) match_players, (SELECT count(*) FROM player_profiles) profiles, (SELECT count(*) FROM player_weapon_totals) weapon_totals FROM matches;"
"${PSQL[@]}" -c "SELECT player_key, total_kills, total_deaths, kd_ratio, wins, losses, matches_played, overall_hit_rate, favorite_weapon_id FROM player_profiles ORDER BY total_kills DESC LIMIT 8;"

ok=1

# 1. leaderboard JSON has players with non-zero kills
echo "--- /api/leaderboard ---"
lb="$(curl -sf --max-time 5 "$ENDPOINT/api/leaderboard?sort=kills&limit=5")"
echo "$lb" | head -c 600; echo
topkills="$(echo "$lb" | python3 -c 'import sys,json; d=json.load(sys.stdin); ps=d["players"]; print(ps[0]["total_kills"] if ps else 0)')"
[ "${topkills:-0}" -ge 1 ] || { echo "FAIL: leaderboard top player has 0 kills"; ok=0; }
KEY="$(echo "$lb" | python3 -c 'import sys,json; d=json.load(sys.stdin); ps=d["players"]; print(ps[0]["player_key"] if ps else "")')"
echo "  top player_key=$KEY topkills=$topkills"
[ -n "$KEY" ] || { echo "FAIL: no player_key from leaderboard"; ok=0; }

# 2. profile JSON total_kills == direct SQL aggregate over match_players for that key (faithful rollup)
if [ -n "$KEY" ]; then
	sqlk="$("${PSQLT[@]}" "SELECT COALESCE(sum(kills),0) FROM match_players WHERE player_key='$KEY';" 2>/dev/null || echo -1)"
	apik="$(curl -sf --max-time 5 "$ENDPOINT/api/players/$KEY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_kills"])' 2>/dev/null || echo -2)"
	echo "  faithfulness: SQL sum(kills)=$sqlk  API total_kills=$apik"
	[ "$sqlk" = "$apik" ] && [ "$sqlk" != "-1" ] || { echo "FAIL: rollup total_kills != SQL aggregate"; ok=0; }
fi

# 3. web pages render 200 HTML with the player + a weapon
echo "--- web pages ---"
idx_code="$(curl -s -o /tmp/p2_index.html -w '%{http_code}' --max-time 5 "$ENDPOINT/")"
prof_code="$(curl -s -o /tmp/p2_profile.html -w '%{http_code}' --max-time 5 "$ENDPOINT/players/$KEY")"
echo "  GET / -> $idx_code ; GET /players/$KEY -> $prof_code"
[ "$idx_code" = "200" ] || { echo "FAIL: / not 200"; ok=0; }
[ "$prof_code" = "200" ] || { echo "FAIL: profile not 200"; ok=0; }
grep -q "$KEY" /tmp/p2_index.html || echo "  (note: top key not literally on index — display_name may differ)"
wcount="$("${PSQLT[@]}" "SELECT count(*) FROM player_weapon_totals WHERE player_key='$KEY';" 2>/dev/null || echo 0)"
if [ "${wcount:-0}" -ge 1 ]; then
	wid="$("${PSQLT[@]}" "SELECT weapon_id FROM player_weapon_totals WHERE player_key='$KEY' ORDER BY shots DESC LIMIT 1;" 2>/dev/null)"
	grep -q "$wid" /tmp/p2_profile.html || { echo "FAIL: weapon '$wid' not on profile page"; ok=0; }
	echo "  profile page shows weapon: $wid"
fi

# 4. dormant paths: enrichment no-op (no Steam key) + OpenID login present
echo "--- dormant paths ---"
enriched_log="$("${BE[@]}" logs worker 2>/dev/null | grep -c 'enriched' || true)"
echo "  worker 'enriched' log lines (expect 0 without a key): $enriched_log"
[ "${enriched_log:-1}" -eq 0 ] || { echo "FAIL: enrichment ran without a Steam key"; ok=0; }
login_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT/login")"
login_loc="$(curl -s -o /dev/null -D - --max-time 5 "$ENDPOINT/login" | grep -i '^location:' | tr -d '\r')"
echo "  GET /login -> $login_code ($login_loc)"
[ "$login_code" = "307" ] || [ "$login_code" = "302" ] || { echo "FAIL: /login did not redirect"; ok=0; }
echo "$login_loc" | grep -qi 'steamcommunity.com/openid/login' || { echo "FAIL: /login not pointing at Steam OpenID"; ok=0; }

echo "----------------"
if [ "$ok" -eq 1 ]; then echo "STATS P2 GATE: PASS"; exit 0; else echo "STATS P2 GATE: FAIL"; exit 1; fi
