#!/usr/bin/env bash
# M20 Stats & Analytics — P3 live gate (dev admin dashboards).
#
# Proves the full P3 admin surface end-to-end on a real bot match:
#   game-server StatsReporter -> P1 ingest API -> Postgres -> admin read layer -> /admin dashboards.
# Asserts:
#   - kill events + weapon counters landed in Postgres;
#   - /admin/api/weapons (weapon balance) has non-zero kills and a sane hit_rate;
#   - /admin/api/combat has kill-distance stats (count>0, non-empty histogram) + hitzone totals;
#   - FAITHFULNESS: Σ weapon_balance.total_kills == SQL Σ match_player_weapons.kills, and
#     /admin/api/combat kill_distance.count == SQL count(kill events);
#   - the admin HTML pages render 200 with a seeded weapon;
#   - the AUTH GATE holds: with ADMIN_DEV_OPEN off and no session cookie, /admin* -> 403.
#
# Runs the backend docker-compose stack (db/api/worker) under the `bf-p3` project (same one the
# pytest suite uses) with ADMIN_DEV_OPEN=1, and on the HOST a Godot dedicated server
# (--stats-endpoint) + a separate bot-driver process. Small bot count on the canonical gameplay
# map — this is a correctness gate.
#
# Usage:  ./run-stats-p3-gate.sh
# Env:    PORT BOTS TICKETS TIME_LIMIT MAX_WAIT MAP INGEST_TOKEN GODOT INGEST_WAIT
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$(pwd)"

GODOT="${GODOT:-godot}"
PORT="${PORT:-28323}"           # distinct from P1 (28123) / P2 (28223) to avoid a concurrent agent
BOTS="${BOTS:-24}"
TICKETS="${TICKETS:-30}"
TIME_LIMIT="${TIME_LIMIT:-240}"
MAX_WAIT="${MAX_WAIT:-260}"
MAP="${MAP:-conquest_town}"
TOKEN="${INGEST_TOKEN:-dev-secret}"
INGEST_WAIT="${INGEST_WAIT:-30}"   # events flush ~1Hz + match report at end; allow a margin
ENDPOINT="http://localhost:8000"
SPOOL="$HOME/.local/share/godot/app_userdata/Blockfire/stats_spool.ndjson"
PROJECT="bf-p3"
BE=(docker compose -p "$PROJECT" -f "$ROOT/backend/docker-compose.yml")
PSQL=("${BE[@]}" exec -T db psql -U blockfire -d blockfire_stats)
PSQLT=("${PSQL[@]}" -tAc)

srv_pids=()
cleanup() { for p in "${srv_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

api_up() {  # bring up (or recreate) the api with a given ADMIN_DEV_OPEN value, wait healthy
	local devopen="$1"
	ADMIN_DEV_OPEN="$devopen" INGEST_TOKEN="$TOKEN" "${BE[@]}" up -d --no-deps api >/dev/null 2>&1
	local ok=""
	for _ in $(seq 1 30); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && { ok=1; break; }; sleep 1; done
	[ -n "$ok" ]
}

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

echo "[stats-p3] bringing up full backend stack (db+api+worker) under project $PROJECT with ADMIN_DEV_OPEN=1…"
ADMIN_DEV_OPEN=1 INGEST_TOKEN="$TOKEN" "${BE[@]}" up --build -d >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null || { echo "FAIL: backend not healthy"; exit 1; }

echo "[stats-p3] clearing spool + truncating tables for a clean gate…"
rm -f "$SPOOL" 2>/dev/null || true
"${PSQL[@]}" -q -c "TRUNCATE matches, match_players, match_player_weapons, events, ingested_batches, players, player_profiles, player_weapon_totals;" >/dev/null 2>&1

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

log="$(mktemp --suffix=.log)"
echo "[stats-p3] playing match on :$PORT map=$MAP (bots=$BOTS)…"
over="$(play_match "$PORT" "$log")"
echo "  $over"
[ -n "$over" ] || { echo "FAIL: match produced no winner"; sed -n '$p' "$log"; exit 1; }
scripterr="$(grep -icE 'SCRIPT ERROR|Parse Error' "$log" || true)"
[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: server SCRIPT/Parse errors"; grep -m3 -E 'SCRIPT ERROR|Parse Error' "$log"; exit 1; }

echo "[stats-p3] waiting up to ${INGEST_WAIT}s for kill events to land…"
kev=0; waited=0
while [ "$waited" -lt "$INGEST_WAIT" ]; do
	kev="$("${PSQLT[@]}" "SELECT count(*) FROM events WHERE type='kill';" 2>/dev/null || echo 0)"
	[ "${kev:-0}" -ge 1 ] && break
	sleep 3; waited=$((waited+3))
done
echo "  kill events: $kev (after ${waited}s)"
[ "${kev:-0}" -ge 1 ] || { echo "FAIL: no kill events ingested"; exit 1; }

echo "--- DB snapshot ---"
"${PSQL[@]}" -c "SELECT (SELECT count(*) FROM matches) matches, (SELECT count(*) FROM match_players) match_players, (SELECT count(*) FROM match_player_weapons) mpw, (SELECT count(*) FROM events WHERE type='kill') kill_events;"
"${PSQL[@]}" -c "SELECT weapon_id, sum(shots) shots, sum(hits) hits, sum(kills) kills, sum(headshots) hs FROM match_player_weapons GROUP BY weapon_id ORDER BY sum(kills) DESC LIMIT 8;"

ok=1

# 1. /admin/api/weapons (dev-open) has weapons with non-zero kills + sane hit_rate
echo "--- /admin/api/weapons (ADMIN_DEV_OPEN=1) ---"
wj="$(curl -sf --max-time 5 "$ENDPOINT/admin/api/weapons")"
echo "$wj" | head -c 500; echo
read -r api_kills top_hr wcount < <(echo "$wj" | python3 -c '
import sys,json
d=json.load(sys.stdin); ws=d["weapons"]
tot=sum(w["total_kills"] for w in ws)
top_hr=ws[0]["hit_rate"] if ws else 0
print(tot, top_hr, len(ws))')
echo "  weapons=$wcount  Σtotal_kills=$api_kills  top_weapon.hit_rate=$top_hr"
[ "${wcount:-0}" -ge 1 ] || { echo "FAIL: no weapons in balance"; ok=0; }
[ "${api_kills:-0}" -ge 1 ] || { echo "FAIL: weapon balance has 0 total kills"; ok=0; }

# 2. FAITHFULNESS: Σ weapon_balance.total_kills == SQL Σ match_player_weapons.kills
sql_kills="$("${PSQLT[@]}" "SELECT COALESCE(sum(kills),0) FROM match_player_weapons;" 2>/dev/null || echo -1)"
echo "  faithfulness(kills): API Σ=$api_kills  SQL Σ=$sql_kills"
[ "$api_kills" = "$sql_kills" ] && [ "$sql_kills" != "-1" ] || { echo "FAIL: weapon-balance kills != SQL aggregate"; ok=0; }

# 3. /admin/api/combat kill-distance + histogram + hitzone; count == SQL kill-event count
echo "--- /admin/api/combat (ADMIN_DEV_OPEN=1) ---"
cj="$(curl -sf --max-time 5 "$ENDPOINT/admin/api/combat")"
echo "$cj" | python3 -c 'import sys,json; d=json.load(sys.stdin); kd=d["kill_distance"]; print("  kill_distance:",{k:kd[k] for k in ("count","avg_m","min_m","max_m","p50_m","p90_m","p99_m")}); print("  histogram buckets:",len(kd["histogram"]),kd["histogram"]); print("  hitzone:",d["hitzone"]); print("  longest_kills:",len(d["longest_kills"]))'
read -r kd_count hist_len hz_total < <(echo "$cj" | python3 -c '
import sys,json
d=json.load(sys.stdin); kd=d["kill_distance"]
nonempty=sum(1 for b in kd["histogram"] if b["count"]>0)
print(kd["count"], nonempty, d["hitzone"]["total"])')
echo "  combat: kill_distance.count=$kd_count  non-empty-hist-buckets=$hist_len  hitzone.total=$hz_total"
[ "${kd_count:-0}" -ge 1 ] || { echo "FAIL: kill_distance.count==0"; ok=0; }
[ "${hist_len:-0}" -ge 1 ] || { echo "FAIL: histogram all-empty"; ok=0; }
[ "${hz_total:-0}" -ge 1 ] || { echo "FAIL: hitzone.total==0"; ok=0; }
echo "  faithfulness(events): combat.count=$kd_count  SQL kill events=$kev"
[ "$kd_count" = "$kev" ] || { echo "FAIL: combat kill count != SQL kill-event count"; ok=0; }

# 4. admin HTML pages render 200 with a seeded weapon
echo "--- admin HTML pages (ADMIN_DEV_OPEN=1) ---"
topw="$("${PSQLT[@]}" "SELECT weapon_id FROM match_player_weapons GROUP BY weapon_id ORDER BY sum(kills) DESC LIMIT 1;" 2>/dev/null)"
a_code="$(curl -s -o /tmp/p3_admin.html -w '%{http_code}' --max-time 5 "$ENDPOINT/admin")"
c_code="$(curl -s -o /tmp/p3_combat.html -w '%{http_code}' --max-time 5 "$ENDPOINT/admin/combat")"
e_code="$(curl -s -o /tmp/p3_events.html -w '%{http_code}' --max-time 5 "$ENDPOINT/admin/events")"
echo "  GET /admin -> $a_code ; /admin/combat -> $c_code ; /admin/events -> $e_code ; top weapon=$topw"
[ "$a_code" = "200" ] && [ "$c_code" = "200" ] && [ "$e_code" = "200" ] || { echo "FAIL: an admin page was not 200"; ok=0; }
grep -q "$topw" /tmp/p3_admin.html || { echo "FAIL: top weapon '$topw' not on /admin"; ok=0; }

# 5. AUTH GATE: recreate api with ADMIN_DEV_OPEN off; /admin* with no cookie -> 403
echo "--- auth gate (recreate api with ADMIN_DEV_OPEN=false) ---"
if api_up "false"; then
	g_api="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT/admin/api/weapons")"
	g_html="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT/admin")"
	echo "  no-cookie GET /admin/api/weapons -> $g_api ; GET /admin -> $g_html (expect 403)"
	[ "$g_api" = "403" ] || { echo "FAIL: admin API reachable without auth"; ok=0; }
	[ "$g_html" = "403" ] || { echo "FAIL: admin page reachable without auth"; ok=0; }
else
	echo "FAIL: api did not come back healthy after ADMIN_DEV_OPEN flip"; ok=0
fi

echo "----------------"
if [ "$ok" -eq 1 ]; then echo "STATS P3 GATE: PASS"; exit 0; else echo "STATS P3 GATE: FAIL"; exit 1; fi
