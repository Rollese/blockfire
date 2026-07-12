#!/usr/bin/env bash
# M20 Stats & Analytics — P4 live gate (anomaly / cheat detection + review queue).
#
# Proves the full P4 pipeline end-to-end on a real bot match plus a controlled cheater:
#   game-server StatsReporter -> ingest API -> Postgres -> worker rollup -> player_profiles
#   -> detect_anomalies -> anomaly_flags review queue -> admin JSON/HTML triage.
# Asserts:
#   - a real bot match lands kill events + rolls up player_profiles (pipeline still flows);
#   - detection is DISCRIMINATING: an injected egregious-cheater profile is flagged HIGH on all
#     three metrics (kd, headshot_rate, hit_rate) while NOT every profile is flagged;
#   - the admin review queue renders (JSON + HTML) with the cheater;
#   - a triage round-trip works: confirm a flag -> it leaves the open queue, appears confirmed
#     with reviewed_by recorded;
#   - IDEMPOTENCY: a second scan writes no duplicate rows and never resurrects a confirmed flag;
#   - the AUTH GATE holds: with ADMIN_DEV_OPEN off and no cookie, the anomaly API/scan -> 403.
#
# The worker is FROZEN (stopped) before the anomaly-assertion phase so only explicit /scan calls
# mutate flags — the periodic 30s worker cycle would otherwise race the assertions.
#
# Runs the backend docker-compose stack (db/api/worker) under the `bf-p4` project with
# ADMIN_DEV_OPEN=1, and on the HOST a Godot dedicated server (--stats-endpoint) + a bot driver.
#
# Usage:  ./run-stats-p4-gate.sh
# Env:    PORT BOTS TICKETS TIME_LIMIT MAX_WAIT MAP INGEST_TOKEN GODOT INGEST_WAIT ROLLUP_WAIT
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$(pwd)"

GODOT="${GODOT:-godot}"
PORT="${PORT:-28423}"           # distinct from P1 (28123)/P2 (28223)/P3 (28323): concurrent-agent safe
BOTS="${BOTS:-24}"
TICKETS="${TICKETS:-30}"
TIME_LIMIT="${TIME_LIMIT:-240}"
MAX_WAIT="${MAX_WAIT:-260}"
MAP="${MAP:-conquest_town}"
TOKEN="${INGEST_TOKEN:-dev-secret}"
INGEST_WAIT="${INGEST_WAIT:-30}"
ROLLUP_WAIT="${ROLLUP_WAIT:-45}"   # worker rollup cadence is 30s; allow a margin
ENDPOINT="http://localhost:8000"
SPOOL="$HOME/.local/share/godot/app_userdata/Blockfire/stats_spool.ndjson"
PROJECT="bf-p4"
BE=(docker compose -p "$PROJECT" -f "$ROOT/backend/docker-compose.yml")
PSQL=("${BE[@]}" exec -T db psql -U blockfire -d blockfire_stats)
PSQLT=("${PSQL[@]}" -tAc)
CHEAT="name:GATE_CHEATER"

srv_pids=()
cleanup() { for p in "${srv_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

api_up() {  # (re)create the api with a given ADMIN_DEV_OPEN value, wait healthy
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

# jq-free JSON field read via python3
pyget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

echo "[stats-p4] bringing up full backend stack (db+api+worker) under project $PROJECT with ADMIN_DEV_OPEN=1…"
ADMIN_DEV_OPEN=1 INGEST_TOKEN="$TOKEN" "${BE[@]}" up --build -d >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null || { echo "FAIL: backend not healthy"; exit 1; }

echo "[stats-p4] clearing spool + truncating tables for a clean gate…"
rm -f "$SPOOL" 2>/dev/null || true
"${PSQL[@]}" -q -c "TRUNCATE matches, match_players, match_player_weapons, events, ingested_batches, players, player_profiles, player_weapon_totals, anomaly_flags;" >/dev/null 2>&1

"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

log="$(mktemp --suffix=.log)"
echo "[stats-p4] playing match on :$PORT map=$MAP (bots=$BOTS)…"
over="$(play_match "$PORT" "$log")"
echo "  $over"
[ -n "$over" ] || { echo "FAIL: match produced no winner"; sed -n '$p' "$log"; exit 1; }
scripterr="$(grep -icE 'SCRIPT ERROR|Parse Error' "$log" || true)"
[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: server SCRIPT/Parse errors"; grep -m3 -E 'SCRIPT ERROR|Parse Error' "$log"; exit 1; }

echo "[stats-p4] waiting up to ${INGEST_WAIT}s for kill events to land…"
kev=0; waited=0
while [ "$waited" -lt "$INGEST_WAIT" ]; do
	kev="$("${PSQLT[@]}" "SELECT count(*) FROM events WHERE type='kill';" 2>/dev/null || echo 0)"
	[ "${kev:-0}" -ge 1 ] && break
	sleep 3; waited=$((waited+3))
done
echo "  kill events: $kev (after ${waited}s)"
[ "${kev:-0}" -ge 1 ] || { echo "FAIL: no kill events ingested"; exit 1; }

echo "[stats-p4] waiting up to ${ROLLUP_WAIT}s for the worker to roll up player_profiles…"
prof=0; waited=0
while [ "$waited" -lt "$ROLLUP_WAIT" ]; do
	prof="$("${PSQLT[@]}" "SELECT count(*) FROM player_profiles;" 2>/dev/null || echo 0)"
	[ "${prof:-0}" -ge 1 ] && break
	sleep 3; waited=$((waited+3))
done
echo "  player_profiles: $prof (after ${waited}s)"
[ "${prof:-0}" -ge 1 ] || { echo "FAIL: worker produced no player_profiles"; exit 1; }

# Freeze the worker so ONLY our explicit /scan calls mutate anomaly_flags (no 30s-cycle race).
echo "[stats-p4] freezing worker (stop) for deterministic anomaly assertions…"
"${BE[@]}" stop worker >/dev/null 2>&1
# Clear any flags the worker may already have written during rollup, for a clean slate.
"${PSQL[@]}" -q -c "TRUNCATE anomaly_flags;" >/dev/null 2>&1

# Inject a synthetic egregious cheater profile (real bots won't reliably breach the floors;
# P4 must be PROVEN to flag a cheater). Trips all three detectors well above their floors.
echo "[stats-p4] injecting synthetic cheater profile ($CHEAT)…"
# Supply EVERY NOT NULL column: player_profiles' integer defaults are ORM-side
# (default=0), not DB server defaults, so a raw INSERT must set them all.
"${PSQL[@]}" -c "INSERT INTO player_profiles
  (player_key, total_kills, total_deaths, total_assists, total_downs, total_revives,
   total_captures, total_neutralizes, wins, losses, matches_played, xp_total, kd_ratio,
   total_shots, total_hits, total_headshots, overall_hit_rate, longest_kill_m,
   total_playtime_s, updated_at)
  VALUES ('$CHEAT', 300, 6, 0, 0, 0, 0, 0, 3, 0, 3, 0, 50.0,
          400, 380, 361, 0.95, 250.0, 1800, now());" || { echo "FAIL: cheater INSERT errored"; exit 1; }
[ "$("${PSQLT[@]}" "SELECT count(*) FROM player_profiles WHERE player_key='$CHEAT';")" = "1" ] \
	|| { echo "FAIL: cheater profile did not land"; exit 1; }

total_profiles="$("${PSQLT[@]}" "SELECT count(*) FROM player_profiles;")"

ok=1

# 1. Run detection on demand and confirm the cheater is flagged HIGH on all three metrics.
echo "--- POST /admin/api/anomaly/scan (ADMIN_DEV_OPEN=1) ---"
sj="$(curl -sf --max-time 10 -X POST "$ENDPOINT/admin/api/anomaly/scan")"
written="$(echo "$sj" | pyget 'd["written"]' 2>/dev/null || echo 0)"
echo "  scan wrote/updated: $written flags"
[ "${written:-0}" -ge 3 ] || { echo "FAIL: scan wrote < 3 flags"; ok=0; }

echo "--- GET /admin/api/anomalies?status=open ---"
aj="$(curl -sf --max-time 5 "$ENDPOINT/admin/api/anomalies?status=open")"
echo "$aj" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  summary:",d["summary"]);
import collections
c=collections.Counter((f["metric"],f["severity"]) for f in d["flags"] if f["player_key"]=="'"$CHEAT"'")
print("  cheater flags (metric,severity):",dict(c))'
# cheater must have a HIGH flag for each of the three metrics
read -r cheat_metrics cheat_high open_total < <(echo "$aj" | python3 -c '
import sys,json
d=json.load(sys.stdin)
cf=[f for f in d["flags"] if f["player_key"]=="'"$CHEAT"'"]
metrics=sorted({f["metric"] for f in cf})
high=sum(1 for f in cf if f["severity"]=="high")
print(len(metrics), high, d["summary"]["by_status"]["open"])')
echo "  cheater distinct metrics=$cheat_metrics  high-severity flags=$cheat_high  open_total=$open_total"
[ "${cheat_metrics:-0}" -ge 3 ] || { echo "FAIL: cheater not flagged on all 3 metrics"; ok=0; }
[ "${cheat_high:-0}" -ge 3 ] || { echo "FAIL: cheater flags not all high severity"; ok=0; }

# 2. DISCRIMINATION: not every profile is flagged (detection isn't a blanket flagger).
flagged_players="$("${PSQLT[@]}" "SELECT count(distinct player_key) FROM anomaly_flags;")"
echo "  discrimination: flagged_players=$flagged_players  total_profiles=$total_profiles"
[ "${flagged_players:-0}" -lt "${total_profiles:-0}" ] || { echo "FAIL: every profile was flagged (not discriminating)"; ok=0; }

# 3. HTML review queue renders 200 with the cheater.
echo "--- GET /admin/anomalies (HTML) ---"
h_code="$(curl -s -o /tmp/p4_anom.html -w '%{http_code}' --max-time 5 "$ENDPOINT/admin/anomalies")"
echo "  GET /admin/anomalies -> $h_code"
[ "$h_code" = "200" ] || { echo "FAIL: /admin/anomalies not 200"; ok=0; }
grep -q "$CHEAT" /tmp/p4_anom.html || { echo "FAIL: cheater '$CHEAT' not on /admin/anomalies"; ok=0; }

# 4. TRIAGE round-trip: confirm one cheater flag -> it leaves the open queue, shows confirmed.
echo "--- triage: confirm one cheater flag ---"
fid="$("${PSQLT[@]}" "SELECT flag_id FROM anomaly_flags WHERE player_key='$CHEAT' AND status='open' ORDER BY flag_id LIMIT 1;")"
echo "  confirming flag_id=$fid"
rj="$(curl -sf --max-time 5 -X POST -H 'Content-Type: application/json' \
	-d '{"status":"confirmed","notes":"gate: blatant aimbot"}' \
	"$ENDPOINT/admin/api/anomalies/$fid/review")"
r_status="$(echo "$rj" | pyget 'd["flag"]["status"]' 2>/dev/null || echo '?')"
r_by="$(echo "$rj" | pyget 'd["flag"]["reviewed_by"]' 2>/dev/null || echo '?')"
echo "  review -> status=$r_status reviewed_by=$r_by"
[ "$r_status" = "confirmed" ] || { echo "FAIL: review did not set status=confirmed"; ok=0; }
[ "$r_by" = "dev" ] || { echo "FAIL: reviewed_by not 'dev' under dev-open"; ok=0; }
# the confirmed flag must be gone from the open list and present in the confirmed list
open_has="$(curl -sf --max-time 5 "$ENDPOINT/admin/api/anomalies?status=open" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for f in d["flags"] if f["flag_id"]=='"$fid"'))')"
conf_has="$(curl -sf --max-time 5 "$ENDPOINT/admin/api/anomalies?status=confirmed" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for f in d["flags"] if f["flag_id"]=='"$fid"'))')"
echo "  after confirm: in-open=$open_has  in-confirmed=$conf_has"
[ "$open_has" = "0" ] || { echo "FAIL: confirmed flag still in open queue"; ok=0; }
[ "$conf_has" = "1" ] || { echo "FAIL: confirmed flag not in confirmed queue"; ok=0; }

# 5. IDEMPOTENCY + no-resurrection: rescan -> no new rows; confirmed flag stays confirmed.
echo "--- idempotency: second scan ---"
before="$("${PSQLT[@]}" "SELECT count(*) FROM anomaly_flags;")"
curl -sf --max-time 10 -X POST "$ENDPOINT/admin/api/anomaly/scan" >/dev/null
after="$("${PSQLT[@]}" "SELECT count(*) FROM anomaly_flags;")"
conf_after="$("${PSQLT[@]}" "SELECT status FROM anomaly_flags WHERE flag_id=$fid;")"
echo "  flag rows before=$before after=$after ; flag_id=$fid status=$conf_after"
[ "$before" = "$after" ] || { echo "FAIL: rescan created duplicate rows ($before -> $after)"; ok=0; }
[ "$conf_after" = "confirmed" ] || { echo "FAIL: rescan resurrected a confirmed flag"; ok=0; }

# 6. AUTH GATE: recreate api with ADMIN_DEV_OPEN off; anomaly API/scan with no cookie -> 403.
echo "--- auth gate (recreate api with ADMIN_DEV_OPEN=false) ---"
if api_up "false"; then
	g_list="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT/admin/api/anomalies")"
	g_scan="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$ENDPOINT/admin/api/anomaly/scan")"
	g_html="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$ENDPOINT/admin/anomalies")"
	echo "  no-cookie: GET /admin/api/anomalies -> $g_list ; POST /scan -> $g_scan ; GET /admin/anomalies -> $g_html (expect 403)"
	[ "$g_list" = "403" ] || { echo "FAIL: anomaly API reachable without auth"; ok=0; }
	[ "$g_scan" = "403" ] || { echo "FAIL: anomaly scan reachable without auth"; ok=0; }
	[ "$g_html" = "403" ] || { echo "FAIL: anomaly page reachable without auth"; ok=0; }
else
	echo "FAIL: api did not come back healthy after ADMIN_DEV_OPEN flip"; ok=0
fi

echo "----------------"
if [ "$ok" -eq 1 ]; then echo "STATS P4 GATE: PASS"; exit 0; else echo "STATS P4 GATE: FAIL"; exit 1; fi
