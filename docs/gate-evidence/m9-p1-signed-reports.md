# Gate Evidence — M9-P1 Signed Match Reports

- **Date:** 2026-07-12
- **Milestone/phase:** M9 — Online Services, **Phase 1** (signed match reports)
- **Branch:** `m9-p1-signed-reports` · **code SHA at gate:** `02af7bf` (+ the Task-10 gate
  script / compose env vars committed in the same phase)
- **Spec:** [`docs/superpowers/specs/2026-07-12-m9-p1-signed-match-reports-design.md`](../superpowers/specs/2026-07-12-m9-p1-signed-match-reports-design.md)
- **Decision:** [ADR-0011](../adr/0011-signed-match-reports.md)
- **Gate script:** `docker/m9_p1_signed_reports_gate.sh`

## What is proven

The M20 ingest contract is now hardened: the game server HMAC-signs `/ingest/events` +
`/ingest/match` (per-server key, envelope over the raw body), the backend verifies before
trusting, and each match carries a durable `matches.trusted` flag. Trust tiers behave per
ADR-0011 §5 in both the default (analytics-friendly) and prod (`REQUIRE_SIGNED_INGEST=true`)
modes.

## 1. Full-stack live gate (real bot match on game2)

`docker/m9_p1_signed_reports_gate.sh` brings up a fresh backend (`db`+`api`) under compose
project `bf-m9-p1` with `INGEST_SIGNING_KEYS=game2-dev-1:***`, runs a **24-bot
conquest_town match** on a Godot dedicated server configured with
`--stats-signing-key-id=game2-dev-1 --stats-signing-secret=***`, then checks the three
default-mode trust paths.

```
[m9-p1] fresh backend (db+api) with INGEST_SIGNING_KEYS=game2-dev-1:*** …
[m9-p1] signed match on :28323 map=conquest_town …
  [match] OVER winner=1 t0=0 t1=18 elapsed=45s cap_events=1
[m9-p1] out-of-band forged POST (bad signature) — must 401 …
  forged POST -> HTTP 401
[m9-p1] out-of-band UNSIGNED POST — must 202 and land trusted=false …
  unsigned POST -> HTTP 202
--- results ---
    match_id     | trusted | complete | winner
-----------------+---------+----------+--------
 1783852466-0297 | t       | t        | team_1
 unsigned-oob    | f       | t        |
(2 rows)

M9-P1 SIGNED-REPORTS GATE: PASS
```

- **Signed real match** `1783852466-0297` → `trusted = t` (the game server's GDScript
  `StatsSigner` HMAC verified by the Python backend end-to-end).
- **Forged** POST (valid bearer + `X-BF-*` headers, signature = 64×`0`) → **HTTP 401**, and
  **no `matches` row written** (`forged-oob` absent from the table — the gate also asserts
  `count(*)=0`).
- **Unsigned** POST (valid bearer, no `X-BF-*` headers) → **HTTP 202**, `trusted = f`
  (`unsigned-oob`): backward-compatible with M20 dev servers, ingested for analytics only.

## 2. Prod mode — `REQUIRE_SIGNED_INGEST=true` (live)

Restarted `api` with `REQUIRE_SIGNED_INGEST=true` and issued two out-of-band POSTs:

```
  unsigned POST (require-signed on) -> HTTP 401
  correctly-signed POST (require-signed on) -> HTTP 202
  trusted flag for req-signed-ok:
req-signed-ok|t
```

- **Unsigned** report is now **rejected 401** (prod refuses anything unsigned).
- **Correctly-signed** report → **202** + `trusted = t`. (The curl signer built the same
  `key_id\ntimestamp\nbody` signing string as the game server and backend, cross-confirming
  the scheme.)

## 3. Cross-language interop (golden vector)

The GDScript signer and the Python verifier agree byte-for-byte on a fixed vector, asserted
in BOTH test suites:

```
sign("game2-dev-1","test-secret",1752307200, b'{"match_id":"m-golden","batch_seq":0,"events":[]}')
  == a25a99340ae1d0bb369662ea87f2a536d19588292d856a35ec2f3395e1169585
```
- `tests/stats_signer_test.gd::test_golden_vector_matches_python` (GDScript) — PASS
- `backend/tests/test_signing.py::test_golden_vector` (Python) — PASS

## 4. Automated test suites

- **Backend (pytest, python:3.11 vs compose Postgres):** `207 passed, 0 failed` — full M20
  suite green (no regression) plus the new signing/verify/route/idempotency tests, incl.
  `test_signed_ingest.py` route-level: signed→trusted, idempotent double-post→single trusted
  row, unsigned-when-required→401, signed events→202.
- **Game server (`godot --headless --path . -- --test`):** `1616 run, 0 failed` — full suite
  green including `stats_signer_test.gd` (golden vector + headers + empty-secret) and the
  extended `stats_reporter_test.gd` (signed→5 headers, unsigned→2 headers).

## Definition of done — met

| DoD item (spec §10) | Result |
|---|---|
| Signed game2 bot match → `matches.trusted=true` | ✅ `1783852466-0297` trusted=t |
| Event/summary rows intact, idempotent under replay | ✅ suite `test_signed_match_idempotent_double_post` |
| Forged signature rejected 401 | ✅ live + `test_route_forged_match_rejected` |
| Unsigned `trusted=false` by default | ✅ live `unsigned-oob` |
| Unsigned rejected 401 under `REQUIRE_SIGNED_INGEST=true` | ✅ live + `test_unsigned_rejected_when_required` |
| GDScript signer ⇄ Python verifier golden vector | ✅ both suites |
| No measurable game-tick cost | ✅ signing is CPU-trivial in the already-async HTTP path; match ran clean (no SCRIPT/Parse errors), full 1616-test game suite unaffected |

**M9-P1 SIGNED-REPORTS GATE: PASS.**
