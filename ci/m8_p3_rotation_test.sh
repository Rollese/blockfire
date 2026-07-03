#!/usr/bin/env bash
# M8-P3 rotation smoke: server with a 2-map rotation config + 8s time limit plays
# match 1 (dev_arena), rotates, plays match 2 (proving_grounds), rotates again —
# and never exits. Botless: time-limit expiry ends a 0-player match.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=${PORT:-28151}
LOG=/tmp/m8p3-rotation-$$.log
CFG=/tmp/m8p3-rotation-cfg-$$.json

cat > "$CFG" <<'EOF'
{"maps": ["conquest_dev_arena", "conquest_proving_grounds"], "time_limit": 8, "tickets": 500}
EOF

SRV_PID=""   # pre-init: the trap must survive an exit before the launch line under set -u
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true; rm -f "$CFG"; }
trap cleanup EXIT

"$GODOT" --headless --path . -- --server --port="$PORT" --config="$CFG" > "$LOG" 2>&1 &
SRV_PID=$!

# Wait (bounded) for two completed matches + two rotation lines.
for i in $(seq 1 90); do
  overs=$(grep -c "\[match\] OVER" "$LOG" 2>/dev/null || true)
  rots=$(grep -c "rotating to" "$LOG" 2>/dev/null || true)
  if [ "${overs:-0}" -ge 2 ] && [ "${rots:-0}" -ge 2 ]; then break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "FAIL: server exited early (rotation should keep it alive)"; tail -30 "$LOG"; exit 1
  fi
  sleep 1
done

fail() { echo "FAIL: $1"; tail -40 "$LOG"; exit 1; }
[ "$(grep -c '\[match\] OVER' "$LOG")" -ge 2 ] || fail "expected >=2 match completions"
grep -q "rotating to conquest_proving_grounds" "$LOG" || fail "missing rotation to map 2"
grep -q "rotating to conquest_dev_arena" "$LOG" || fail "missing wrap-around rotation to map 1"
grep -q "map rotation active" "$LOG" || fail "missing rotation-active boot line"
kill -0 "$SRV_PID" 2>/dev/null || fail "server not alive after two rotations"
if grep -q "SCRIPT ERROR" "$LOG"; then fail "script errors in server log"; fi

echo "M8-P3 ROTATION SMOKE: PASS (matches=$(grep -c '\[match\] OVER' "$LOG"), rotations=$(grep -c 'rotating to' "$LOG"))"
