# M9-P1 — Signed match reports — design

- **Date:** 2026-07-12
- **Status:** approved (design)
- **Milestone:** **M9 — Online Services**, **Phase 1** (first phase of M9). M9 was
  deferred post-1.0 ([ADR-0007](../../adr/0007-battlebit-divergences.md) §4); the owner
  elected to start it now, attaching trust-hardening to the M20 stats datastore.
- **Decision record:** [ADR-0011](../../adr/0011-signed-match-reports.md) (signature primitive + envelope).
- **Builds on:** [M20 Stats & Analytics](2026-07-11-stats-analytics-backend-design.md) — the
  ingest API (`backend/app/ingest.py`, `routes.py`, `auth.py`) and the game-server
  `StatsReporter` (`server/stats/stats_reporter.gd`) shipped there. Nothing there is
  rewritten; this hardens the ingest contract in place.
- **Realizes:** [ADR-0004](../../adr/0004-anti-cheat-and-skill-matchmaking.md) decision #5
  ("only official, authenticated servers report rating-affecting results — signed match
  reports") and [`anti-cheat-matchmaking.md`](../../specs/anti-cheat-matchmaking.md)
  Subsystem B "Trust model". §9 of the M20 design lists signed match reports as M9-deferred;
  this is that item.

## 1. Goal and scope

Today any holder of the single shared **ingest bearer token** can POST a match report or
event batch and the backend trusts it implicitly — every ingested match is, in effect,
rating-grade. That is fine for M20 analytics but unacceptable for the rating (M9-P2) and
Layer-4 detection (M9-P3) that will consume this data: those must only ever trust results
that a **specific, authenticated official server** actually produced.

This phase upgrades the ingest contract from "shared password" to **per-server signed
requests**:

- Each official game server holds its own **signing key** (`key_id` + secret).
- The server signs an **envelope over the exact request body bytes** of both
  `POST /ingest/events` and `POST /ingest/match`.
- The backend **verifies** the signature (known key, correct HMAC, fresh timestamp)
  before trusting, and records a durable **`trusted` flag** on the match.
- Downstream phases (rating, Layer-4) filter on `trusted = true`. Anything not validly
  signed is still ingested for analytics but never affects rating.

### In scope
- A signing envelope (headers) + HMAC-SHA256 over the raw body, both endpoints.
- Backend verification module + a `trusted` column on `matches`.
- Backward-compatible trust tiers + an opt-in `REQUIRE_SIGNED_INGEST` hard-reject mode.
- Game-server signer wired into `StatsReporter`.
- Cross-language golden-vector test (GDScript signer ⇄ Python verifier byte-identical).
- Full-stack gate: signed match → `trusted=true`; forged/unsigned → rejected/untrusted.

### Out of scope (later M9 phases / deferred)
- Rating (Glicko-2/OpenSkill) — M9-P2; consumes `trusted`.
- Layer-4 statistical detection — M9-P3.
- Steam auth / ownership tickets / VAC — M9-P4 (the `steam:` key provenance).
- Asymmetric signatures (RSA/Ed25519), key rotation tooling, an HSM/secret-manager — see
  ADR-0011 "Alternatives" and "Consequences"; a superseding ADR if untrusted community
  servers ever submit reports.
- Per-request nonce replay store — see §4 (idempotency already neutralizes verbatim replay).

## 2. Decision: signature primitive (see ADR-0011)

**HMAC-SHA256 with a per-server shared secret.** Rationale:

- The game server is **our own trusted infrastructure**, not the untrusted client. The
  client's Steam session ticket is validated *by the server*; the server is what POSTs to
  the backend. A symmetric secret shared between two systems we both operate is a sound
  posture and a strict upgrade over today's single global token (per-server identity +
  payload binding + replay window + trust tiering).
- **Native on both sides:** Godot `HMACContext` (`HashingContext.HASH_SHA256`) and Python
  `hmac`/`hashlib` — no PEM parsing, no RSA keygen in GDScript, no new dependency. Keeps P1
  genuinely small and self-contained.
- **Alternative — asymmetric (RSA via Godot `Crypto.sign`, or Ed25519):** backend never
  holds signing capability (survives a backend compromise) and models untrusted community
  hosts more cleanly. Heavier: Godot exposes no Ed25519, and RSA means PEM/key-format
  handling in GDScript. Deferred to a superseding ADR **if/when** untrusted community
  servers actually submit rating-affecting reports. For P1 both endpoints are ours.

## 3. Wire format — the signing envelope

The signature is carried in **HTTP headers**, over the **raw request body bytes exactly as
sent**. This deliberately avoids JSON canonicalization (key ordering / float formatting /
whitespace are a cross-language footgun): the signer signs the same bytes it transmits, and
the verifier HMACs the same bytes it received *before* Pydantic parsing. The JSON body and
the M20 Pydantic schemas are **unchanged**.

### Headers (all four required for a signed request)
| Header | Value |
|---|---|
| `X-BF-Key-Id` | The server's key identifier, e.g. `game2-dev-1`. ASCII, `[A-Za-z0-9._-]{1,64}`. |
| `X-BF-Timestamp` | Unix seconds (integer, UTC) at signing time. |
| `X-BF-Signature` | Lowercase hex HMAC-SHA256 (64 chars) of the signing string (below). |

The existing `Authorization: Bearer <ingest_token>` header **stays** — it remains the
coarse gate on *who may POST at all*. Signing adds *which server* + *integrity* + *trust*.

### Signing string (the HMAC message)
Constructed as the UTF-8 bytes of:

```
<key_id> "\n" <timestamp> "\n"
```

…**concatenated with the raw request body bytes**. Concretely, the HMAC input is:

```
key_id_bytes + b"\n" + timestamp_ascii_bytes + b"\n" + raw_body_bytes
```

- `key_id` and `timestamp` are bound into the signature so neither can be swapped by an
  attacker who captured a valid signature.
- The HMAC **key** is the per-server secret's UTF-8 bytes (same convention as the bearer
  token — an opaque ASCII string).
- Output encoding is lowercase hex (matches `hmac.hexdigest()` and a straightforward
  Godot `PackedByteArray` → hex conversion).

### Verification algorithm (backend)
1. Read raw body bytes (`await request.body()`; FastAPI caches so Pydantic still parses).
2. If **none** of the `X-BF-*` headers are present → request is **unsigned** (see §5 trust
   tiers). If *some but not all* → malformed signed request → **401**.
3. Look up `key_id` in the configured key map. Unknown → **401**.
4. Parse `X-BF-Timestamp`; reject if non-integer or `abs(now - ts) > INGEST_MAX_SKEW_S`
   (default 300 s) → **401** (bounds the replay window + rejects clock-broken servers).
5. Recompute HMAC over `key_id + "\n" + ts + "\n" + body`; compare to `X-BF-Signature`
   with `hmac.compare_digest` (constant-time). Mismatch → **401**.
6. Valid → mark `request.state.ingest_trusted = True`.

An **unsigned** request sets `request.state.ingest_trusted = False`. A **present-but-invalid**
signature is an attack signal, not a legacy client → hard **401** (never silently downgraded
to untrusted).

## 4. Replay & idempotency

The M20 contract is already idempotent: `/ingest/events` dedupes on `(match_id, batch_seq)`
and `/ingest/match` upserts on `match_id`. A **verbatim replay** of a captured signed
request therefore injects no new data — it is deduped. The signature binds the body, so a
captured signature **cannot** be reused with a *different* body. The `X-BF-Timestamp` +
`INGEST_MAX_SKEW_S` window further bounds how long a captured request is even accepted.

Given that, a **server-side nonce store is YAGNI for P1** and is explicitly deferred:
idempotency neutralizes replay of identical bodies, and body-binding prevents altered
replays. Revisit if a future phase ingests non-idempotent, rating-affecting side effects.

**Trust is monotonic under re-POST.** `/ingest/match` is an idempotent upsert, so a bearer-token
holder could re-POST an existing `match_id` *unsigned* and would otherwise flip a previously
`trusted=true` match to `false`, evicting it from rating. `ingest_match_report` therefore sets
`trusted = new OR existing` — trust only ever moves up, never down. NDJSON replay re-POSTs the
identical signed report (still `trusted=true`), so this never blocks a legit flow; correcting an
erroneously-trusted match is an admin/DB action, not an ingest path. (Prod `REQUIRE_SIGNED_INGEST`
already 401s the unsigned re-POST before it reaches this code; monotonicity is defense-in-depth
for the default mode.)

## 5. Trust tiers & backward compatibility

`matches.trusted` (new `BOOLEAN NOT NULL DEFAULT FALSE`) is the durable output. Behavior is
governed by one new setting, `REQUIRE_SIGNED_INGEST` (default **False** — backward
compatible with M20 dev servers that send no signature):

| Request | `REQUIRE_SIGNED_INGEST=False` (default) | `REQUIRE_SIGNED_INGEST=True` (prod) |
|---|---|---|
| Valid signature, known key | **202**, `trusted=true` | **202**, `trusted=true` |
| No signature headers (M20 legacy) | **202**, `trusted=false` (analytics only) | **401** |
| Present-but-invalid signature (bad HMAC / unknown key / stale ts / partial headers) | **401** | **401** |

- **`trusted` lives on the match**, set from the `/ingest/match` POST's signature validity
  (the match summary is the rating-grade artifact). It is written in `ingest_match_report`
  from `request.state.ingest_trusted`.
- **Events** are verified by the *same* dependency (so forged/invalid event batches are
  rejected identically), but do not independently set a trust flag: there is no `matches`
  row at mid-match event time (M20 §5), and events are consumed downstream **joined to their
  match**, so an untrusted match's events are inert for rating regardless. Under
  `REQUIRE_SIGNED_INGEST=True`, forged/unsigned event batches are rejected outright, so no
  forged events land at all.
- **Bearer token unchanged:** every request still needs the valid `Authorization` bearer;
  signing is layered *on top*, evaluated after the bearer check.

This makes the rollout safe: M20 servers keep ingesting (as `trusted=false`); a server
gains `trusted=true` only once it is issued a key and configured to sign; prod flips
`REQUIRE_SIGNED_INGEST=True` to refuse everything unsigned.

## 6. Architecture & components

Small, single-purpose units with clear interfaces:

### Backend (`backend/app/`)
- **`signing.py` (new)** — pure verification logic, no FastAPI/DB coupling:
  - `parse_signing_keys(raw: str) -> dict[str, str]` — parse the `INGEST_SIGNING_KEYS` env
    (format below) into `{key_id: secret}`. Skips malformed tokens like `admin_steam_id_set` does.
  - `compute_signature(secret, key_id, timestamp, body: bytes) -> str` — the canonical
    hex HMAC (shared by tests + any future signer tooling).
  - `verify(headers, body, keys, now, max_skew) -> SignatureResult` — returns an enum-ish
    result: `TRUSTED` / `UNSIGNED` / `INVALID` (+ reason). No I/O; unit-testable in isolation.
- **`auth.py`** — add `require_valid_signature(request)` FastAPI dependency: reads body,
  calls `verify`, applies the §5 table (raise 401 or set `request.state.ingest_trusted`),
  honoring `settings.require_signed_ingest`. Registered **alongside** `require_ingest_token`
  on both routes.
- **`ingest.py`** — `ingest_match_report` gains a `trusted: bool` param; writes
  `match_row.trusted = trusted`. `routes.py` passes `request.state.ingest_trusted`.
- **`models.py`** — `Match.trusted` column.
- **`db.py`** — after `create_all`, an idempotent guard:
  `ALTER TABLE matches ADD COLUMN IF NOT EXISTS trusted BOOLEAN NOT NULL DEFAULT FALSE`
  (create_all covers fresh DBs but never adds columns to an existing `matches`; Alembic was
  never actually introduced despite the P2 note, and one boolean does not justify adopting
  it now — the `IF NOT EXISTS` guard is the proportionate, idempotent migration).
- **`config.py`** — new settings: `ingest_signing_keys: str = ""`,
  `require_signed_ingest: bool = False`, `ingest_max_skew_s: int = 300`; plus a
  `signing_key_map()` accessor (mirrors `admin_steam_id_set`).

**`INGEST_SIGNING_KEYS` format:** space/comma-separated `key_id:secret` pairs, e.g.
`INGEST_SIGNING_KEYS="game2-dev-1:s3cr3t-aaa unraid-prod-1:s3cr3t-bbb"`. Any configured
key is an official/trusted key. (Consistent with the existing CSV-ish `ADMIN_STEAM_IDS`.)

### Game server (`server/`)
- **`stats/stats_signer.gd` (new)** — a tiny, pure helper:
  `StatsSigner.sign(key_id, secret, timestamp, body_utf8: PackedByteArray) -> String`
  (hex HMAC via `HMACContext`), and a header-assembly helper. No `StatsReporter` coupling →
  unit-testable against the golden vector.
- **`stats/stats_reporter.gd`** — `configure()` gains optional `signing_key_id` +
  `signing_secret`; `_send_next()` computes the timestamp, signs
  `JSON.stringify(body)` bytes, and appends the three `X-BF-*` headers when a key is set.
  When no key is configured it behaves exactly as today (unsigned).
- **`server_main.gd`** — read `signing_key_id`/`signing_secret` from the same env/CLI
  surface as `_stats_endpoint`/`_stats_token`, pass into `configure()`.

## 7. Data flow

```
GAME SERVER (StatsReporter._send_next)
  body = JSON.stringify(payload)                       # exact bytes
  ts   = unix_seconds()
  sig  = hex_hmac_sha256(secret, key_id + "\n" + ts + "\n" + body)
  POST endpoint
    Authorization: Bearer <ingest_token>               # unchanged coarse gate
    X-BF-Key-Id: <key_id>  X-BF-Timestamp: <ts>  X-BF-Signature: <sig>
    <body>
        │ https
BACKEND (require_ingest_token → require_valid_signature → route)
  raw = await request.body()
  result = verify(headers, raw, key_map, now, max_skew)
    → 401 on INVALID (or UNSIGNED when REQUIRE_SIGNED_INGEST)
    → request.state.ingest_trusted = (result == TRUSTED)
  ingest_match_report(session, report, trusted=request.state.ingest_trusted)
    → matches.trusted persisted
DOWNSTREAM (M9-P2 rating, M9-P3 Layer-4)  … WHERE matches.trusted  (later phases)
```

## 8. Error handling

- **Missing bearer** → 401 (unchanged, `require_ingest_token` runs first).
- **Partial `X-BF-*` headers / unknown key / bad HMAC / stale timestamp** → 401, logged;
  nothing written.
- **Unsigned + `REQUIRE_SIGNED_INGEST=True`** → 401.
- **Unsigned + default** → 202, ingested `trusted=false`.
- **Malformed body** → Pydantic 422 as today (signature is checked first; a valid signature
  over a malformed body still fails validation and writes nothing — acceptable, no partial write).
- **Game server:** if signing is misconfigured (key set, secret empty) the signer treats it
  as unsigned rather than crashing the tick; logged once. Signing is CPU-trivial and happens
  in the already-async HTTP path → no game-tick cost (same async send as today).

## 9. Testing

**Backend (pytest, python:3.11 vs compose Postgres):**
- `verify` unit matrix: valid → TRUSTED; no headers → UNSIGNED; partial headers → INVALID;
  unknown key → INVALID; bad HMAC → INVALID; stale/future timestamp → INVALID; non-integer ts → INVALID.
- Route/integration: valid sig → 202 + `matches.trusted is True`; unsigned (default) → 202 +
  `trusted is False`; unsigned + `REQUIRE_SIGNED_INGEST` → 401; forged sig → 401; events
  endpoint mirrors the same accept/reject.
- Idempotency preserved: signed double-POST → single row, still `trusted`.
- `parse_signing_keys` / `signing_key_map` parsing incl. malformed tokens skipped.
- **Golden vector:** a fixed `(secret, key_id, timestamp, body)` → a hard-coded expected hex
  digest, asserted in Python.

**Game server (`tests/*_test.gd`):**
- `stats_signer_test.gd` — `StatsSigner.sign(...)` for the **same** fixed
  `(secret, key_id, timestamp, body)` equals the **same** hard-coded hex digest (byte-identical
  cross-language interop proof), and header assembly is well-formed.
- `stats_reporter_test.gd` — extend: with a key configured, a flushed request carries the
  three `X-BF-*` headers; with no key, it carries none (unchanged path).

**Gate (full-stack, `docker/` + `docs/gate-evidence/`):**
- Fresh compose project `bf-m9-p1`; native snapshot-encoder `.so` copied into the worktree
  before the match. A bot match on game2 with `StatsReporter` signing-configured → POSTs flow
  to the compose backend → assert the `matches` row is `trusted=true` and rows are present.
- A forged POST (wrong secret) and an unsigned POST are issued out-of-band → assert 401
  (forged) and `trusted=false` (unsigned, default) / 401 (unsigned under
  `REQUIRE_SIGNED_INGEST=True`). Captured as `docs/gate-evidence/m9-p1-signed-reports.md`.

## 10. Definition of done (gate)

A signing-configured game2 bot match lands a `matches` row with `trusted = true` in
compose Postgres, with event/summary rows intact and idempotent under replay; a forged
signature is rejected 401; an unsigned report is `trusted=false` by default and 401 under
`REQUIRE_SIGNED_INGEST=True`; the GDScript signer and Python verifier agree on the golden
vector; `StatsReporter` adds no measurable game-tick cost. Evidence committed under
`docs/gate-evidence/`. ADR-0011 + this spec + the M9 milestone-doc phase note are landed.

## 11. References
- [ADR-0011 — Signed match reports](../../adr/0011-signed-match-reports.md) (this phase's decision record)
- [ADR-0004 — Anti-cheat & skill-tier matchmaking](../../adr/0004-anti-cheat-and-skill-matchmaking.md) (decision #5)
- [anti-cheat-matchmaking spec](../../specs/anti-cheat-matchmaking.md) — Subsystem B trust model
- [M20 Stats & Analytics design](2026-07-11-stats-analytics-backend-design.md) — the datastore this hardens (§9 defers this item)
- [M9 — Online Services milestone](../../milestones/M9-online-services.md)
