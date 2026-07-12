#!/usr/bin/env bash
# M9-P2 Skill Rating — full-stack live gate (ADR-0012).
# Proves end-to-end that the rating service only rates TRUSTED matches, rates each
# exactly once, and is deterministically rebuildable:
#   * brings up a FRESH backend stack (db + api + worker) under compose project bf-m9-p2
#   * plays 3 SIGNED 24-bot conquest_town matches -> ingested trusted=TRUE
#   * plays 1 UNSIGNED match               -> ingested trusted=FALSE
#   * lets the worker rating cycle run, then asserts in Postgres:
#       (a) player_ratings populated
#       (b) every trusted+complete match is rated
#       (c) the untrusted match is NOT rated
#       (d) tiers are assigned (no null/empty)
#       (e) exactly-once: an idle cycle does not re-rate (updated_at does not advance)
#       (f) rebuild determinism: a one-shot rebuild reproduces identical mu/sigma
#       (g) convergence: ordinal spread widened + mean sigma below the seed sigma
#
# Correctness/data-flow gate on the canonical gameplay map (small bot count), same
# posture as the M9-P1 signed-reports gate it mirrors — NOT the 128-bot perf fleet.
#
# Usage:  GODOT=/usr/bin/godot ./docker/m9_p2_rating_gate.sh
# Env:    PORT BOTS TICKETS TIME_LIMIT MAX_WAIT MAP GODOT
set -uo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$(pwd)"

GODOT="${GODOT:-godot}"
PORT="${PORT:-28423}"
BOTS="${BOTS:-24}"
TICKETS="${TICKETS:-20}"
TIME_LIMIT="${TIME_LIMIT:-150}"
MAX_WAIT="${MAX_WAIT:-180}"
MAP="${MAP:-conquest_town}"
PROJECT="bf-m9-p2"
TOKEN="gate-token"
KEY_ID="game2-dev-1"
SECRET="gate-secret"
ENDPOINT="http://localhost:8000"
BE=(docker compose -p "$PROJECT" -f "$ROOT/backend/docker-compose.yml")
PSQL=("${BE[@]}" exec -T db psql -U blockfire -d blockfire_stats)
Q() { "${PSQL[@]}" -tAc "$1" | tr -d '[:space:]'; }   # scalar query -> trimmed

srv_pids=()
cleanup() {
	for p in "${srv_pids[@]:-}"; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	echo "[m9-p2] tearing down stack (down -v) …"
	"${BE[@]}" down -v >/dev/null 2>&1
}
trap cleanup EXIT

# --- one match: $1=port $2=log $3=signed(1)/unsigned(0). Returns when the server
#     logs [match] OVER (or after MAX_WAIT). Echoes the winner line. ---
play_match() {
	local port="$1" log="$2" signed="$3"
	local sign_args=()
	[ "$signed" = "1" ] && sign_args=(--stats-signing-key-id="$KEY_ID" --stats-signing-secret="$SECRET")
	"$GODOT" --headless --path "$ROOT" -- --server --port="$port" --map="$MAP" \
		--tickets="$TICKETS" --time-limit="$TIME_LIMIT" \
		--stats-endpoint="$ENDPOINT" --stats-token="$TOKEN" \
		"${sign_args[@]}" >"$log" 2>&1 &
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

ok=1
fail() { echo "  FAIL: $1"; ok=0; }
pass() { echo "  PASS: $1"; }

echo "[m9-p2] fresh backend (db+api+worker) with INGEST_SIGNING_KEYS=$KEY_ID:*** …"
"${BE[@]}" down -v >/dev/null 2>&1
INGEST_TOKEN="$TOKEN" INGEST_SIGNING_KEYS="$KEY_ID:$SECRET" REQUIRE_SIGNED_INGEST=false \
	"${BE[@]}" up --build -d db api worker >/dev/null 2>&1
for _ in $(seq 1 40); do curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null && break; sleep 1; done
curl -sf --max-time 3 "$ENDPOINT/healthz" >/dev/null || { echo "FAIL: backend not healthy"; exit 1; }
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true

# --- 3 signed + 1 unsigned match --------------------------------------------
for i in 1 2 3; do
	log="$(mktemp --suffix=.log)"
	echo "[m9-p2] SIGNED match $i/3 on :$PORT map=$MAP …"
	over="$(play_match "$PORT" "$log" 1)"; echo "  $over"
	[ -n "$over" ] || { echo "FAIL: signed match $i produced no winner"; sed -n '1,40p' "$log"; exit 1; }
	scripterr="$(grep -icE 'SCRIPT ERROR|Parse Error' "$log" || true)"
	[ "${scripterr:-1}" -eq 0 ] || { echo "FAIL: server SCRIPT/Parse errors in signed match $i"; exit 1; }
done

log="$(mktemp --suffix=.log)"
echo "[m9-p2] UNSIGNED match on :$PORT map=$MAP (must land trusted=false) …"
over="$(play_match "$PORT" "$log" 0)"; echo "  $over"
[ -n "$over" ] || { echo "FAIL: unsigned match produced no winner"; sed -n '1,40p' "$log"; exit 1; }

# --- wait for ingest + a worker rating cycle --------------------------------
echo "[m9-p2] waiting for all 4 reports ingested + trusted matches rated …"
rated_ok=""
for _ in $(seq 1 30); do   # up to ~150s (worker cycle is every 30s)
	complete="$(Q 'SELECT count(*) FROM matches WHERE complete;')"
	unrated="$(Q 'SELECT count(*) FROM matches WHERE trusted AND complete AND NOT rated;')"
	nratings="$(Q 'SELECT count(*) FROM player_ratings;')"
	echo "  complete=$complete trusted-unrated=$unrated ratings=$nratings"
	if [ "${complete:-0}" -ge 4 ] && [ "${unrated:-1}" = "0" ] && [ "${nratings:-0}" -gt 0 ]; then
		rated_ok=1; break
	fi
	sleep 5
done
[ -n "$rated_ok" ] || { echo "FAIL: worker did not rate all trusted matches in time"; "${BE[@]}" logs --tail 40 worker; exit 1; }

echo "=== rating cycle observed in worker log ==="
"${BE[@]}" logs worker 2>&1 | grep -E '\[worker\] rated [0-9]+ matches' | tail -5

echo "--- matches table ---"
"${PSQL[@]}" -c "SELECT match_id, trusted, complete, rated, winner FROM matches ORDER BY ingested_at;"
echo "--- player_ratings sample (10) ---"
"${PSQL[@]}" -c "SELECT player_key, round(mu::numeric,4) mu, round(sigma::numeric,4) sigma, round(ordinal::numeric,4) ordinal, tier, matches_rated FROM player_ratings ORDER BY ordinal DESC LIMIT 10;"

echo "=== assertions ==="
# (a) player_ratings populated
n_ratings="$(Q 'SELECT count(*) FROM player_ratings;')"
[ "${n_ratings:-0}" -gt 0 ] && pass "(a) player_ratings populated ($n_ratings rows)" || fail "(a) player_ratings empty"

# (b) every trusted+complete match rated
b_unrated="$(Q 'SELECT count(*) FROM matches WHERE trusted AND complete AND NOT rated;')"
[ "${b_unrated:-1}" = "0" ] && pass "(b) all trusted+complete matches rated (0 unrated)" || fail "(b) $b_unrated trusted+complete matches NOT rated"

# (c) the untrusted match exists, is trusted=f, and is NOT rated
n_untrusted="$(Q 'SELECT count(*) FROM matches WHERE NOT trusted AND complete;')"
c_rated="$(Q 'SELECT count(*) FROM matches WHERE NOT trusted AND rated;')"
[ "${n_untrusted:-0}" -ge 1 ] && pass "(c1) untrusted match present ($n_untrusted trusted=f rows)" || fail "(c1) no untrusted match row"
[ "${c_rated:-1}" = "0" ] && pass "(c2) untrusted match NOT rated (0)" || fail "(c2) $c_rated untrusted matches were rated"

# (d) tiers assigned — no null/empty, at least one distinct tier
d_bad="$(Q "SELECT count(*) FROM player_ratings WHERE tier IS NULL OR tier='';")"
d_tiers="$(Q 'SELECT count(DISTINCT tier) FROM player_ratings;')"
[ "${d_bad:-1}" = "0" ] && pass "(d1) no null/empty tiers" || fail "(d1) $d_bad rows with null/empty tier"
[ "${d_tiers:-0}" -ge 1 ] && pass "(d2) distinct tiers present ($d_tiers)" || fail "(d2) no tiers assigned"

# (g) convergence — ordinal spread widened + mean sigma below the seed sigma.
#     Seed sigma = rating_sigma_init = 25/3 = 8.33333.  Deterministic signal
#     (per plan): a monotonic-ordinal "dominant cohort" is ambiguous here because
#     bots rotate teams across matches, so we assert spread>0 and mean σ<seed.
g_spread="$(Q 'SELECT round((max(ordinal)-min(ordinal))::numeric,4) FROM player_ratings;')"
g_avgsigma="$(Q 'SELECT round(avg(sigma)::numeric,5) FROM player_ratings;')"
SEED_SIGMA="8.33333"
echo "  ordinal spread=$g_spread  avg(sigma)=$g_avgsigma  seed sigma=$SEED_SIGMA"
awk "BEGIN{exit !($g_spread>0)}" && pass "(g1) ordinal spread widened (>0): $g_spread" || fail "(g1) ordinal spread not >0: $g_spread"
awk "BEGIN{exit !($g_avgsigma<$SEED_SIGMA)}" && pass "(g2) mean sigma below seed: $g_avgsigma < $SEED_SIGMA" || fail "(g2) mean sigma NOT below seed: $g_avgsigma"

# (e) exactly-once — an idle worker cycle must NOT re-rate. Method: capture
#     max(updated_at) now, wait a full worker cycle (~35s), confirm it did not
#     advance AND no trusted match became unrated. (The worker only logs
#     'rated N matches' when N>0, so an idle cycle prints nothing to grep.)
echo "[m9-p2] exactly-once: idle-cycle check (waiting ~35s for another worker cycle) …"
e_before="$(Q 'SELECT COALESCE(max(updated_at),to_timestamp(0))::text FROM player_ratings;')"
sleep 35
e_after="$(Q 'SELECT COALESCE(max(updated_at),to_timestamp(0))::text FROM player_ratings;')"
e_unrated="$(Q 'SELECT count(*) FROM matches WHERE trusted AND complete AND NOT rated;')"
echo "  max(updated_at) before=$e_before after=$e_after ; trusted-unrated after idle=$e_unrated"
[ "$e_before" = "$e_after" ] && [ "${e_unrated:-1}" = "0" ] \
	&& pass "(e) idle cycle did not re-rate (updated_at unchanged, 0 unrated)" \
	|| fail "(e) idle cycle mutated ratings (before=$e_before after=$e_after unrated=$e_unrated)"

# (f) rebuild determinism — a one-shot rebuild_ratings() must reproduce identical
#     per-player mu/sigma. Dump BEFORE, rebuild in the worker container, dump AFTER,
#     assert byte-identical.
echo "[m9-p2] rebuild determinism: dump -> rebuild_ratings() -> dump, assert identical …"
DUMPQ="SELECT player_key, round(mu::numeric,6), round(sigma::numeric,6), round(ordinal::numeric,6), tier FROM player_ratings ORDER BY player_key;"
before_dump="$(mktemp)"; after_dump="$(mktemp)"
"${PSQL[@]}" -tAF, -c "$DUMPQ" >"$before_dump"
PYREBUILD="import asyncio
from app.config import get_settings
from app.db import make_engine, make_sessionmaker, init_db
from app.rating_apply import rebuild_ratings
import app.models  # register ORM tables for init_db create_all
async def m():
    s = get_settings()
    e = make_engine(s.database_url)
    await init_db(e)
    sm = make_sessionmaker(e)
    async with sm() as ses:
        n = await rebuild_ratings(ses, s)
        print('rebuilt', n)
asyncio.run(m())"
"${BE[@]}" exec -T worker python -c "$PYREBUILD"
"${PSQL[@]}" -tAF, -c "$DUMPQ" >"$after_dump"
if diff -q "$before_dump" "$after_dump" >/dev/null; then
	pass "(f) rebuild reproduced identical mu/sigma ($(wc -l <"$before_dump") players, byte-identical)"
else
	fail "(f) rebuild changed ratings — diff:"; diff "$before_dump" "$after_dump" | head -20
fi

echo "======================================================================"
if [ "$ok" -eq 1 ]; then echo "M9-P2 RATING GATE: GATE PASS"; exit 0; else echo "M9-P2 RATING GATE: GATE FAIL"; exit 1; fi
