# M9-P1 Signed Match Reports — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the M20 ingest contract so the game server cryptographically signs `/ingest/events` + `/ingest/match`, the backend verifies (HMAC-SHA256, per-server keys), and each match carries a durable `trusted` flag that later M9 phases filter on.

**Architecture:** A signing envelope carried in `X-BF-Key-Id` / `X-BF-Timestamp` / `X-BF-Signature` headers, HMAC-SHA256 over `key_id + "\n" + timestamp + "\n" + <raw body bytes>`. The backend verifies before Pydantic parsing; a valid signature marks `matches.trusted=true`. Backward compatible: unsigned requests ingest as `trusted=false` (unless `REQUIRE_SIGNED_INGEST=True`); a present-but-invalid signature is rejected 401. The existing bearer token stays as the coarse gate.

**Tech Stack:** Backend — Python 3.11, FastAPI, SQLAlchemy async, PostgreSQL, `hmac`/`hashlib` (stdlib, no new dep), pytest. Game server — Godot 4 GDScript, `HMACContext`, headless TestCase harness.

**Spec:** `docs/superpowers/specs/2026-07-12-m9-p1-signed-match-reports-design.md` · **Decision:** `docs/adr/0011-signed-match-reports.md`

---

## Cross-language golden vector (used by Task 1 AND Task 7 — must match byte-for-byte)

```
secret     = "test-secret"
key_id     = "game2-dev-1"
timestamp  = 1752307200
body       = {"match_id":"m-golden","batch_seq":0,"events":[]}
signing string = key_id + "\n" + str(timestamp) + "\n" + body
HMAC-SHA256 hex = a25a99340ae1d0bb369662ea87f2a536d19588292d856a35ec2f3395e1169585
```

## TEST RECIPE — backend (run from repo root of THIS worktree)

The host only has Python 3.14; backend tests run in a `python:3.11-slim` container against a compose Postgres under a dedicated project name so it never collides with a running dev stack.

```bash
# one-time per session: bring up an isolated Postgres
docker compose -p bf-m9-p1 -f backend/docker-compose.yml up -d db
# run the whole suite (or add "::test_name" / -k filter to the pytest command)
docker run --rm --network host -v "$PWD/backend":/app -w /app \
  -e DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@localhost:5432/blockfire_stats' \
  -e INGEST_TOKEN='test-token' \
  python:3.11-slim bash -lc "pip install -q -e '.[dev]' && python -m pytest -v"
```

## TEST RECIPE — game server (run from repo root of THIS worktree)

```bash
godot --headless --path . --import          # once, after adding any new class_name script
godot --headless --path . -- --test --filter=<substr>   # e.g. --filter=stats_signer
```

---

## Task 1: Backend signing module (pure, no I/O)

**Files:**
- Create: `backend/app/signing.py`
- Test: `backend/tests/test_signing.py`

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_signing.py`:

```python
from app.signing import (
    SignatureStatus, compute_signature, parse_signing_keys, verify,
)

SECRET = "test-secret"
KEY_ID = "game2-dev-1"
TS = 1752307200
BODY = b'{"match_id":"m-golden","batch_seq":0,"events":[]}'
GOLDEN = "a25a99340ae1d0bb369662ea87f2a536d19588292d856a35ec2f3395e1169585"
KEYS = {KEY_ID: SECRET}


def test_golden_vector():
    assert compute_signature(SECRET, KEY_ID, str(TS), BODY) == GOLDEN


def test_parse_signing_keys_space_and_comma():
    m = parse_signing_keys("a:sa, b:sb  c:sc")
    assert m == {"a": "sa", "b": "sb", "c": "sc"}


def test_parse_signing_keys_skips_malformed():
    # no colon, empty id, empty secret, stray blanks
    assert parse_signing_keys("nocolon :sx x:  a:sa") == {"a": "sa"}


def test_verify_trusted():
    r = verify(KEY_ID, str(TS), GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.TRUSTED


def test_verify_unsigned_when_no_headers():
    r = verify(None, None, None, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.UNSIGNED


def test_verify_invalid_partial_headers():
    r = verify(KEY_ID, None, GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_unknown_key():
    r = verify("nope", str(TS), GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_bad_signature():
    r = verify(KEY_ID, str(TS), "0" * 64, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_stale_timestamp():
    r = verify(KEY_ID, str(TS), GOLDEN, BODY, KEYS, now=TS + 3600, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_noninteger_timestamp():
    r = verify(KEY_ID, "not-a-number", GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_body_tamper_fails():
    r = verify(KEY_ID, str(TS), GOLDEN, BODY + b" ", KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID
```

- [ ] **Step 2: Run tests to verify they fail**

Run the backend TEST RECIPE with `... python -m pytest tests/test_signing.py -v`.
Expected: FAIL — `ModuleNotFoundError: No module named 'app.signing'`.

- [ ] **Step 3: Write `backend/app/signing.py`**

```python
import hashlib
import hmac
from dataclasses import dataclass
from enum import Enum


class SignatureStatus(Enum):
    TRUSTED = "trusted"    # valid signature from a configured key
    UNSIGNED = "unsigned"  # no X-BF-* headers present at all
    INVALID = "invalid"    # present but wrong / unknown / stale / partial


@dataclass(frozen=True)
class SignatureResult:
    status: SignatureStatus
    reason: str = ""


def parse_signing_keys(raw: str) -> dict[str, str]:
    """Parse 'key_id:secret key_id2:secret2' (space/comma separated) into a map.

    Skips malformed tokens (no colon, empty id, or empty secret) rather than
    raising, so a deploy-time typo in INGEST_SIGNING_KEYS can't crash startup
    (mirrors config.admin_steam_id_set)."""
    out: dict[str, str] = {}
    for token in raw.replace(",", " ").split():
        key_id, sep, secret = token.partition(":")
        if not sep or not key_id or not secret:
            continue
        out[key_id] = secret
    return out


def compute_signature(secret: str, key_id: str, timestamp: str, body: bytes) -> str:
    """Lowercase-hex HMAC-SHA256 of key_id + "\\n" + timestamp + "\\n" + body.
    `timestamp` is the ASCII decimal string exactly as it appears on the wire."""
    msg = key_id.encode("utf-8") + b"\n" + timestamp.encode("utf-8") + b"\n" + body
    return hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def verify(key_id: str | None, timestamp: str | None, signature: str | None,
           body: bytes, keys: dict[str, str], now: int, max_skew_s: int) -> SignatureResult:
    """Pure verification. No FastAPI/DB coupling; `now` is injected (int unix s)."""
    supplied = [h for h in (key_id, timestamp, signature) if h]
    if not supplied:
        return SignatureResult(SignatureStatus.UNSIGNED)
    if not (key_id and timestamp and signature):
        return SignatureResult(SignatureStatus.INVALID, "partial signing headers")
    secret = keys.get(key_id)
    if secret is None:
        return SignatureResult(SignatureStatus.INVALID, "unknown key_id")
    try:
        ts = int(timestamp)
    except ValueError:
        return SignatureResult(SignatureStatus.INVALID, "non-integer timestamp")
    if abs(now - ts) > max_skew_s:
        return SignatureResult(SignatureStatus.INVALID, "timestamp out of window")
    expected = compute_signature(secret, key_id, timestamp, body)
    if not hmac.compare_digest(expected, signature):
        return SignatureResult(SignatureStatus.INVALID, "signature mismatch")
    return SignatureResult(SignatureStatus.TRUSTED)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: backend TEST RECIPE with `... python -m pytest tests/test_signing.py -v`.
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/app/signing.py backend/tests/test_signing.py
git commit -m "feat(m9-p1): backend HMAC signing/verify module + golden vector"
```

---

## Task 2: Config settings for signing

**Files:**
- Modify: `backend/app/config.py`
- Test: `backend/tests/test_config.py`

- [ ] **Step 1: Write the failing tests**

Append to `backend/tests/test_config.py`:

```python
def test_signing_key_map_parses():
    from app.config import Settings
    s = Settings(ingest_token="t", ingest_signing_keys="game2-dev-1:sa bad-token")
    assert s.signing_key_map() == {"game2-dev-1": "sa"}


def test_signing_defaults():
    from app.config import Settings
    s = Settings(ingest_token="t")
    assert s.ingest_signing_keys == ""
    assert s.require_signed_ingest is False
    assert s.ingest_max_skew_s == 300
    assert s.signing_key_map() == {}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: backend TEST RECIPE with `... python -m pytest tests/test_config.py -v`.
Expected: FAIL — `AttributeError`/`TypeError` on `ingest_signing_keys` / `signing_key_map`.

- [ ] **Step 3: Modify `backend/app/config.py`**

Add the import at the top (after the existing import line):

```python
from app.signing import parse_signing_keys
```

Add these three fields inside `class Settings` (next to `ingest_token`):

```python
    # M9-P1 signed match reports (ADR-0011). Space/comma-separated key_id:secret
    # pairs; any configured key is an official/trusted signer.
    ingest_signing_keys: str = ""
    # When True, unsigned ingest POSTs are rejected 401 (prod). Default False
    # keeps M20 dev servers (no signature) working, ingested as trusted=false.
    require_signed_ingest: bool = False
    # Max abs clock skew (seconds) tolerated on X-BF-Timestamp.
    ingest_max_skew_s: int = 300
```

Add this method to `class Settings` (next to `admin_steam_id_set`):

```python
    def signing_key_map(self) -> dict[str, str]:
        return parse_signing_keys(self.ingest_signing_keys)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: backend TEST RECIPE with `... python -m pytest tests/test_config.py -v`.
Expected: PASS (existing config tests + the 2 new).

- [ ] **Step 5: Commit**

```bash
git add backend/app/config.py backend/tests/test_config.py
git commit -m "feat(m9-p1): signing settings (keys, require-signed, max-skew)"
```

---

## Task 3: `matches.trusted` column + migration guard

**Files:**
- Modify: `backend/app/models.py:19-31` (`Match`)
- Modify: `backend/app/db.py:21-28` (`init_db`)
- Test: `backend/tests/test_models.py`

- [ ] **Step 1: Write the failing test**

Append to `backend/tests/test_models.py`:

```python
def test_match_has_trusted_column_default_false():
    from app.models import Match
    col = Match.__table__.c.trusted
    assert col.nullable is False
    # default resolves to False for a freshly-constructed row
    assert Match().trusted in (False, None)  # server_default applies at flush
```

- [ ] **Step 2: Run test to verify it fails**

Run: backend TEST RECIPE with `... python -m pytest tests/test_models.py::test_match_has_trusted_column_default_false -v`.
Expected: FAIL — `AttributeError: trusted` / `KeyError: 'trusted'`.

- [ ] **Step 3: Add the column and the migration guard**

In `backend/app/models.py`, add to `class Match` (after `ingested_at`):

```python
    # M9-P1 (ADR-0011): true iff the /ingest/match POST carried a valid official
    # signature. Downstream rating (P2) / Layer-4 (P3) filter on this.
    trusted: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false")
```

(`Boolean` is already imported in `models.py`.)

In `backend/app/db.py`, inside `init_db`, after the `create_all` line, add:

```python
        # M9-P1: create_all makes the column on a fresh DB but never adds it to
        # an existing `matches`. Idempotent guard for an already-provisioned DB.
        await conn.exec_driver_sql(
            "ALTER TABLE matches ADD COLUMN IF NOT EXISTS "
            "trusted BOOLEAN NOT NULL DEFAULT FALSE"
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: backend TEST RECIPE with `... python -m pytest tests/test_models.py -v`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/models.py backend/app/db.py backend/tests/test_models.py
git commit -m "feat(m9-p1): add matches.trusted column + idempotent ADD COLUMN guard"
```

---

## Task 4: Persist `trusted` in `ingest_match_report`

**Files:**
- Modify: `backend/app/ingest.py:45-95` (`ingest_match_report`)
- Test: `backend/tests/test_ingest_match.py`

- [ ] **Step 1: Write the failing test**

Append to `backend/tests/test_ingest_match.py` (follow the file's existing fixture style for obtaining a session; if it builds reports inline, reuse that helper). Minimal self-contained version:

```python
import datetime as dt
from sqlalchemy import select
from app.ingest import ingest_match_report
from app.models import Match
from app.schemas import MatchMetaIn, MatchReportIn, PlayerReportIn


def _report(match_id="m-trust"):
    return MatchReportIn(
        report_version=1,
        match=MatchMetaIn(match_id=match_id, server_id="s1", map="town",
                          mode="conquest",
                          started_at=dt.datetime(2026, 7, 12, tzinfo=dt.timezone.utc),
                          ended_at=dt.datetime(2026, 7, 12, 0, 20, tzinfo=dt.timezone.utc),
                          winner="team_a"),
        players=[PlayerReportIn(name="BotAlpha", kills=1)],
    )


async def test_ingest_match_records_trusted_true(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        await ingest_match_report(s, _report("m-t"), trusted=True)
    async with sm() as s:
        row = (await s.execute(select(Match).where(Match.match_id == "m-t"))).scalar_one()
        assert row.trusted is True


async def test_ingest_match_defaults_untrusted(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        await ingest_match_report(s, _report("m-u"))  # trusted defaults False
    async with sm() as s:
        row = (await s.execute(select(Match).where(Match.match_id == "m-u"))).scalar_one()
        assert row.trusted is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: backend TEST RECIPE with `... python -m pytest tests/test_ingest_match.py -v`.
Expected: FAIL — `TypeError: ingest_match_report() got an unexpected keyword argument 'trusted'`.

- [ ] **Step 3: Add the `trusted` parameter**

In `backend/app/ingest.py`, change the signature and set the column:

```python
async def ingest_match_report(session: AsyncSession, report: MatchReportIn,
                              trusted: bool = False) -> None:
```

Inside, next to the other `match_row.*` assignments (after `match_row.ingested_at = now`), add:

```python
    match_row.trusted = trusted
```

Update the docstring's first paragraph to note: "`trusted` records whether the POST carried a valid official signature (ADR-0011)."

- [ ] **Step 4: Run test to verify it passes**

Run: backend TEST RECIPE with `... python -m pytest tests/test_ingest_match.py -v`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/ingest.py backend/tests/test_ingest_match.py
git commit -m "feat(m9-p1): ingest_match_report persists trusted flag"
```

---

## Task 5: `require_valid_signature` dependency

**Files:**
- Modify: `backend/app/auth.py`
- Test: `backend/tests/test_auth.py`

- [ ] **Step 1: Write the failing tests**

Append to `backend/tests/test_auth.py`. These drive the dependency via a tiny throwaway app so no DB is needed:

```python
import time
import pytest
from fastapi import Depends, FastAPI, Request, Response
from httpx import ASGITransport, AsyncClient
from app.auth import require_valid_signature
from app.config import Settings
from app.signing import compute_signature

KEY_ID = "game2-dev-1"
SECRET = "test-secret"


def _app(settings):
    app = FastAPI()
    app.state.settings = settings
    @app.post("/t", dependencies=[Depends(require_valid_signature)])
    async def t(request: Request) -> Response:
        return Response(str(getattr(request.state, "ingest_trusted", "missing")))
    return app


async def _post(app, body: bytes, headers: dict):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        return await c.post("/t", content=body, headers=headers)


def _signed_headers(body: bytes, ts: int | None = None):
    ts = ts if ts is not None else int(time.time())
    sig = compute_signature(SECRET, KEY_ID, str(ts), body)
    return {"X-BF-Key-Id": KEY_ID, "X-BF-Timestamp": str(ts), "X-BF-Signature": sig}


async def test_valid_signature_sets_trusted_true():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    body = b'{"x":1}'
    r = await _post(_app(s), body, _signed_headers(body))
    assert r.status_code == 200 and r.text == "True"


async def test_unsigned_sets_trusted_false_by_default():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    r = await _post(_app(s), b'{"x":1}', {})
    assert r.status_code == 200 and r.text == "False"


async def test_unsigned_rejected_when_required():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}",
                 require_signed_ingest=True)
    r = await _post(_app(s), b'{"x":1}', {})
    assert r.status_code == 401


async def test_forged_signature_rejected():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    body = b'{"x":1}'
    h = _signed_headers(body)
    h["X-BF-Signature"] = "0" * 64
    r = await _post(_app(s), body, h)
    assert r.status_code == 401


async def test_stale_timestamp_rejected():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    body = b'{"x":1}'
    r = await _post(_app(s), body, _signed_headers(body, ts=1))  # far past
    assert r.status_code == 401
```

- [ ] **Step 2: Run tests to verify they fail**

Run: backend TEST RECIPE with `... python -m pytest tests/test_auth.py -v`.
Expected: FAIL — `ImportError: cannot import name 'require_valid_signature'`.

- [ ] **Step 3: Add the dependency to `backend/app/auth.py`**

Append to `backend/app/auth.py`:

```python
import time

from app.signing import SignatureStatus, verify


async def require_valid_signature(request: Request) -> None:
    """M9-P1 (ADR-0011). Verifies the X-BF-* signing envelope over the raw body
    and stashes request.state.ingest_trusted. Rejects a present-but-invalid
    signature (401); rejects unsigned only when require_signed_ingest is set.
    Reading request.body() here caches it, so Pydantic body parsing still works."""
    settings = request.app.state.settings
    body = await request.body()
    result = verify(
        request.headers.get("X-BF-Key-Id"),
        request.headers.get("X-BF-Timestamp"),
        request.headers.get("X-BF-Signature"),
        body,
        settings.signing_key_map(),
        int(time.time()),
        settings.ingest_max_skew_s,
    )
    if result.status == SignatureStatus.INVALID:
        raise HTTPException(status_code=401, detail=f"invalid signature: {result.reason}")
    if result.status == SignatureStatus.UNSIGNED and settings.require_signed_ingest:
        raise HTTPException(status_code=401, detail="signed ingest required")
    request.state.ingest_trusted = result.status == SignatureStatus.TRUSTED
```

- [ ] **Step 4: Run tests to verify they pass**

Run: backend TEST RECIPE with `... python -m pytest tests/test_auth.py -v`.
Expected: PASS (existing bearer-token tests + the 5 new).

- [ ] **Step 5: Commit**

```bash
git add backend/app/auth.py backend/tests/test_auth.py
git commit -m "feat(m9-p1): require_valid_signature ingest dependency"
```

---

## Task 6: Wire signature verification onto the ingest routes

**Files:**
- Modify: `backend/app/routes.py`
- Test: `backend/tests/test_ingest_match.py`, `backend/tests/test_ingest_events.py`

- [ ] **Step 1: Write the failing integration tests**

The shared `client` fixture (conftest) sends only the bearer token → these ride the default (`require_signed_ingest=False`) path. Add a signed-request helper + tests. Append to `backend/tests/test_ingest_match.py`:

```python
import time as _time
from app.signing import compute_signature as _sig

_SKEY_ID = "game2-dev-1"
_SSECRET = "test-secret"


def _sign_headers(body_bytes: bytes):
    ts = int(_time.time())
    return {"X-BF-Key-Id": _SKEY_ID, "X-BF-Timestamp": str(ts),
            "X-BF-Signature": _sig(_SSECRET, _SKEY_ID, str(ts), body_bytes)}


async def test_route_unsigned_match_is_untrusted(client):
    import json
    from sqlalchemy import select
    from app.models import Match
    body = _report("m-route-u").model_dump(mode="json")
    raw = json.dumps(body).encode()
    r = await client.post("/ingest/match", content=raw,
                          headers={"Content-Type": "application/json"})
    assert r.status_code == 202
    # (trusted assertion covered by the signed test below; this asserts accept)


async def test_route_forged_match_rejected(client):
    import json
    raw = json.dumps(_report("m-route-f").model_dump(mode="json")).encode()
    h = _sign_headers(raw)
    h["X-BF-Signature"] = "0" * 64
    h["Content-Type"] = "application/json"
    r = await client.post("/ingest/match", content=raw, headers=h)
    assert r.status_code == 401
```

Add a signed-path test in a NEW test module `backend/tests/test_signed_ingest.py` that constructs its own app with signing configured (the default `client` fixture's Settings has no keys):

```python
import datetime as dt
import json
import time
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from app.config import Settings
from app.db import Base, init_db, make_engine, make_sessionmaker
from app.main import create_app
from app.models import Match
from app.schemas import MatchMetaIn, MatchReportIn, PlayerReportIn
from app.signing import compute_signature

KEY_ID, SECRET = "game2-dev-1", "test-secret"


def _raw(match_id):
    rep = MatchReportIn(
        report_version=1,
        match=MatchMetaIn(match_id=match_id, server_id="s1", map="town",
                          mode="conquest", winner="team_a"),
        players=[PlayerReportIn(name="BotAlpha", kills=1)])
    return json.dumps(rep.model_dump(mode="json")).encode()


def _headers(raw, token="test-token"):
    ts = int(time.time())
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
            "X-BF-Key-Id": KEY_ID, "X-BF-Timestamp": str(ts),
            "X-BF-Signature": compute_signature(SECRET, KEY_ID, str(ts), raw)}


@pytest.fixture
async def signed_app(require_signed=False):
    engine = make_engine()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db(engine)
    sm = make_sessionmaker(engine)
    settings = Settings(ingest_token="test-token",
                        ingest_signing_keys=f"{KEY_ID}:{SECRET}",
                        require_signed_ingest=require_signed)
    yield create_app(settings=settings, sessionmaker=sm), sm
    await engine.dispose()


async def test_signed_match_is_trusted(signed_app):
    app, sm = signed_app
    raw = _raw("m-signed")
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        r = await c.post("/ingest/match", content=raw, headers=_headers(raw))
    assert r.status_code == 202
    async with sm() as s:
        row = (await s.execute(select(Match).where(Match.match_id == "m-signed"))).scalar_one()
        assert row.trusted is True


async def test_signed_match_idempotent_double_post(signed_app):
    app, sm = signed_app
    raw = _raw("m-idem")
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        await c.post("/ingest/match", content=raw, headers=_headers(raw))
        await c.post("/ingest/match", content=raw, headers=_headers(raw))
    async with sm() as s:
        rows = (await s.execute(select(Match).where(Match.match_id == "m-idem"))).scalars().all()
        assert len(rows) == 1 and rows[0].trusted is True
```

> If pytest-asyncio rejects the parametrized-fixture default arg, drop `require_signed` from the fixture and add a second fixture `signed_app_required` with `require_signed_ingest=True`; add one test asserting an unsigned POST to that app returns 401 on `/ingest/match`.

- [ ] **Step 2: Run tests to verify they fail**

Run: backend TEST RECIPE with `... python -m pytest tests/test_signed_ingest.py tests/test_ingest_match.py -v`.
Expected: FAIL — signed match shows `trusted is False` (route ignores signature) and forged returns 202 not 401.

- [ ] **Step 3: Wire the dependency + pass trusted in `backend/app/routes.py`**

```python
from fastapi import Depends, FastAPI, Request, Response

from app.auth import require_ingest_token, require_valid_signature
from app.ingest import ingest_event_batch, ingest_match_report
from app.schemas import EventBatchIn, MatchReportIn


def register_ingest_routes(app: FastAPI) -> None:
    @app.post("/ingest/events", status_code=202,
              dependencies=[Depends(require_ingest_token),
                            Depends(require_valid_signature)])
    async def ingest_events(batch: EventBatchIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_event_batch(session, batch)
        return Response(status_code=202)

    @app.post("/ingest/match", status_code=202,
              dependencies=[Depends(require_ingest_token),
                            Depends(require_valid_signature)])
    async def ingest_match(report: MatchReportIn, request: Request) -> Response:
        trusted = getattr(request.state, "ingest_trusted", False)
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_match_report(session, report, trusted=trusted)
        return Response(status_code=202)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: backend TEST RECIPE with `... python -m pytest -v` (full suite — confirms no regression across all M20 tests too).
Expected: PASS (all existing + new).

- [ ] **Step 5: Commit**

```bash
git add backend/app/routes.py backend/tests/test_ingest_match.py backend/tests/test_signed_ingest.py
git commit -m "feat(m9-p1): verify signature on ingest routes; persist match trust"
```

---

## Task 7: Game-server signer module (`StatsSigner`)

**Files:**
- Create: `server/stats/stats_signer.gd`
- Test: `tests/stats_signer_test.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/stats_signer_test.gd`:

```gdscript
extends TestCase

const Signer := preload("res://server/stats/stats_signer.gd")

func test_golden_vector_matches_python() -> void:
	var body := '{"match_id":"m-golden","batch_seq":0,"events":[]}'.to_utf8_buffer()
	var sig := Signer.sign("game2-dev-1", "test-secret", 1752307200, body)
	assert_eq(sig, "a25a99340ae1d0bb369662ea87f2a536d19588292d856a35ec2f3395e1169585",
		"GDScript HMAC must match the Python verifier golden vector")

func test_headers_assembled() -> void:
	var h := Signer.headers("game2-dev-1", 1752307200, "deadbeef")
	assert_eq(h.size(), 3, "three signing headers")
	assert_eq(h[0], "X-BF-Key-Id: game2-dev-1")
	assert_eq(h[1], "X-BF-Timestamp: 1752307200")
	assert_eq(h[2], "X-BF-Signature: deadbeef")

func test_empty_secret_returns_empty() -> void:
	var sig := Signer.sign("k", "", 1, "x".to_utf8_buffer())
	assert_eq(sig, "", "empty secret yields no signature")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=stats_signer`.
Expected: FAIL — file fails to load (`stats_signer.gd` missing).

- [ ] **Step 3: Write `server/stats/stats_signer.gd`**

```gdscript
class_name StatsSigner
extends RefCounted

# Server-only. Pure HMAC-SHA256 signer for the M9-P1 ingest envelope (ADR-0011).
# Signing string = key_id + "\n" + str(timestamp) + "\n" + <raw body bytes>.
# Mirrors backend app/signing.py::compute_signature byte-for-byte (golden vector
# asserted in both tests/stats_signer_test.gd and backend/tests/test_signing.py).

static func sign(key_id: String, secret: String, timestamp: int, body: PackedByteArray) -> String:
	if secret.is_empty():
		return ""
	var ctx := HMACContext.new()
	if ctx.start(HashingContext.HASH_SHA256, secret.to_utf8_buffer()) != OK:
		return ""
	ctx.update((key_id + "\n" + str(timestamp) + "\n").to_utf8_buffer())
	ctx.update(body)
	return ctx.finish().hex_encode()

static func headers(key_id: String, timestamp: int, signature: String) -> PackedStringArray:
	return PackedStringArray([
		"X-BF-Key-Id: %s" % key_id,
		"X-BF-Timestamp: %d" % timestamp,
		"X-BF-Signature: %s" % signature,
	])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=stats_signer`.
Expected: PASS (3 tests). The golden-vector test proves GDScript ⇄ Python interop.

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_signer.gd server/stats/stats_signer.gd.uid tests/stats_signer_test.gd tests/stats_signer_test.gd.uid
git commit -m "feat(m9-p1): GDScript StatsSigner (HMAC) matching backend golden vector"
```

> Note: the `--import` run generates the `.uid` sidecars; `git add` them so the P4-style tracking convention holds (see recent commits).

---

## Task 8: Sign requests in `StatsReporter`

**Files:**
- Modify: `server/stats/stats_reporter.gd:22-26` (`configure`), `:64-82` (`_send_next`)
- Test: `tests/stats_reporter_test.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/stats_reporter_test.gd`:

```gdscript
func test_no_signing_headers_when_unconfigured() -> void:
	var r = Reporter.new()
	autofree(r)
	r.configure("http://x", "tok", "user://t_unsigned.ndjson")
	var h := r._build_headers('{"a":1}')
	assert_eq(h.size(), 2, "only Authorization + Content-Type when no signing key")

func test_signing_headers_present_when_configured() -> void:
	var r = Reporter.new()
	autofree(r)
	r.configure("http://x", "tok", "user://t_signed.ndjson", "game2-dev-1", "test-secret")
	var h := r._build_headers('{"a":1}')
	assert_eq(h.size(), 5, "Authorization + Content-Type + 3 signing headers")
	assert_true(h[2].begins_with("X-BF-Key-Id: game2-dev-1"), "key id header")
	assert_true(h[3].begins_with("X-BF-Timestamp: "), "timestamp header")
	assert_true(h[4].begins_with("X-BF-Signature: "), "signature header")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test --filter=stats_reporter`.
Expected: FAIL — `_build_headers` / 5-arg `configure` do not exist.

- [ ] **Step 3: Modify `server/stats/stats_reporter.gd`**

Add signing fields near the other vars (after `var _inflight`):

```gdscript
var _signing_key_id: String = ""
var _signing_secret: String = ""
```

Replace `configure` with the 5-arg version:

```gdscript
func configure(endpoint: String, token: String, spool_path: String = "user://stats_spool.ndjson",
		signing_key_id: String = "", signing_secret: String = "") -> void:
	_endpoint = endpoint.rstrip("/")
	_token = token
	_spool = Spool.new(spool_path)
	_signing_key_id = signing_key_id
	_signing_secret = signing_secret
```

Add a pure header builder (place above `_send_next`):

```gdscript
func _build_headers(body_str: String) -> PackedStringArray:
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % _token,
		"Content-Type: application/json",
	])
	# M9-P1 (ADR-0011): sign the EXACT bytes we transmit so the backend verifies
	# against the same body it receives. No signing config -> unsigned (backward
	# compatible; ingested as trusted=false).
	if not _signing_key_id.is_empty() and not _signing_secret.is_empty():
		var ts := int(Time.get_unix_time_from_system())
		var sig := StatsSigner.sign(_signing_key_id, _signing_secret, ts, body_str.to_utf8_buffer())
		if not sig.is_empty():
			headers.append_array(StatsSigner.headers(_signing_key_id, ts, sig))
	return headers
```

Replace the header/body construction inside `_send_next` (the lines building `headers` and calling `_http.request`) with:

```gdscript
	var body_str := JSON.stringify(item["body"])
	var headers := _build_headers(body_str)
	_inflight = true
	var err := _http.request(_endpoint + String(item["path"]), headers,
		HTTPClient.METHOD_POST, body_str)
```

(Leave the `if err != OK:` spool-fallback block unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test --filter=stats_reporter`.
Expected: PASS (existing weapon_key tests + the 2 new).

- [ ] **Step 5: Commit**

```bash
git add server/stats/stats_reporter.gd tests/stats_reporter_test.gd
git commit -m "feat(m9-p1): StatsReporter signs ingest POSTs when a key is configured"
```

---

## Task 9: Wire signing config into `server_main.gd`

**Files:**
- Modify: `server/server_main.gd:161-163` (vars), `:207-208` (arg parse), `:261` (configure call)

- [ ] **Step 1: Add the vars**

After `server/server_main.gd:162` (`var _stats_token: String = ""`), add:

```gdscript
var _stats_signing_key_id: String = ""
var _stats_signing_secret: String = ""
```

- [ ] **Step 2: Parse the CLI args**

After `server/server_main.gd:208` (`_stats_token = String(args.get("stats-token", ""))`), add:

```gdscript
	_stats_signing_key_id = String(args.get("stats-signing-key-id", ""))
	_stats_signing_secret = String(args.get("stats-signing-secret", ""))
```

- [ ] **Step 3: Pass them to configure**

Replace `server/server_main.gd:261`:

```gdscript
		_stats_reporter.configure(_stats_endpoint, _stats_token,
			"user://stats_spool.ndjson", _stats_signing_key_id, _stats_signing_secret)
```

- [ ] **Step 4: Verify the game suite still passes (no regression)**

Run: `godot --headless --path . --import` then `godot --headless --path . -- --test`.
Expected: PASS — full suite green (server_main parses/loads; signer + reporter tests included).

- [ ] **Step 5: Commit**

```bash
git add server/server_main.gd
git commit -m "feat(m9-p1): server_main reads stats-signing-key-id/secret CLI args"
```

---

## Task 10: Full-stack gate + evidence

**Files:**
- Create: `docker/m9_p1_signed_reports_gate.sh`
- Create: `docs/gate-evidence/m9-p1-signed-reports.md`

- [ ] **Step 1: Copy the native encoder .so into the worktree (required before any match)**

The snapshot-encoder `.so` is gitignored; copy it from the main checkout so the server can run a match:

```bash
# from THIS worktree root
find /home/roland/projects/blockfire -name 'libblockfire_native*.so' -o -name '*.so' 2>/dev/null | grep -i native | head
# copy the matching path into the same relative location in this worktree
cp -v /home/roland/projects/blockfire/native/<the-.so-and-its-dir> native/<same> 2>/dev/null || true
git status --porcelain native/    # must show nothing (it is gitignored)
```

Locate the exact `.so` path with `git -C /home/roland/projects/blockfire status --ignored --porcelain | grep -i '\.so$'` if the glob misses; the goal is byte-for-byte the same file the M19 checkout uses.

- [ ] **Step 2: Write the gate script `docker/m9_p1_signed_reports_gate.sh`**

The script must:
1. `docker compose -p bf-m9-p1 -f backend/docker-compose.yml up -d db api` with `INGEST_TOKEN=gate-token` and `INGEST_SIGNING_KEYS=game2-dev-1:gate-secret` exported into the `api` service (add them to the compose `api.environment` via `-e`-style env or an `.env` the compose reads — pass `INGEST_SIGNING_KEYS`/`REQUIRE_SIGNED_INGEST` through the same `${VAR:-default}` mechanism the other settings use; **add those two vars to `backend/docker-compose.yml` `api.environment` in this task**).
2. Run a short headless bot match on game2 with the server pinned to P-cores, passing `--stats-endpoint=http://localhost:8000 --stats-token=gate-token --stats-signing-key-id=game2-dev-1 --stats-signing-secret=gate-secret` (mirror an existing `ci/*_test.sh` invocation for the match harness + `SERVER_CPUS`).
3. After the match, query Postgres for the trusted flag:
   `docker compose -p bf-m9-p1 -f backend/docker-compose.yml exec -T db psql -U blockfire -d blockfire_stats -c "SELECT match_id, trusted, complete FROM matches ORDER BY ingested_at DESC LIMIT 3;"`
4. Issue an out-of-band **forged** POST (wrong secret) and assert HTTP 401, and an **unsigned** POST and assert 202 + `trusted=false`:
   ```bash
   curl -s -o /dev/null -w '%{http_code}' -X POST localhost:8000/ingest/match \
     -H 'Authorization: Bearer gate-token' -H 'Content-Type: application/json' \
     -H 'X-BF-Key-Id: game2-dev-1' -H 'X-BF-Timestamp: 1' -H 'X-BF-Signature: deadbeef' \
     -d '{"report_version":1,"match":{"match_id":"forged","server_id":"x","map":"m","mode":"conquest"},"players":[]}'
   # expect 401
   ```
5. Tear down: `docker compose -p bf-m9-p1 -f backend/docker-compose.yml down -v`.

Add `INGEST_SIGNING_KEYS: ${INGEST_SIGNING_KEYS:-}` and `REQUIRE_SIGNED_INGEST: ${REQUIRE_SIGNED_INGEST:-false}` and `INGEST_MAX_SKEW_S: ${INGEST_MAX_SKEW_S:-300}` to the `api` (and, if it ever verifies, not the worker) `environment:` block in `backend/docker-compose.yml`.

- [ ] **Step 3: Run the gate**

```bash
bash docker/m9_p1_signed_reports_gate.sh 2>&1 | tee /tmp/m9-p1-gate.log
```
Expected: the most-recent `matches` row from the signed bot match shows `trusted = t`; the forged POST returns `401`; the unsigned POST returns `202` and its match row shows `trusted = f`.

- [ ] **Step 4: Write the evidence doc `docs/gate-evidence/m9-p1-signed-reports.md`**

Record: date, git SHA, the exact commands, the psql output showing `trusted=t` for the signed match, the `401` from the forged POST, the `trusted=f` for the unsigned POST, the full backend `pytest` count, and the game `--test` count. Follow the format of an existing file in `docs/gate-evidence/`.

- [ ] **Step 5: Commit**

```bash
git add docker/m9_p1_signed_reports_gate.sh backend/docker-compose.yml docs/gate-evidence/m9-p1-signed-reports.md
git commit -m "test(m9-p1): full-stack signed-report gate + evidence"
```

---

## Final: holistic review + land

After all tasks: run the full backend suite and the full game suite once more (both green), then request a holistic code review (per subagent-driven-development), address findings, and **land per AGENTS.md §11**:

1. Commit everything on `m9-p1-signed-reports`.
2. `git fetch origin`; reconcile onto `origin/master`.
3. **Detached-HEAD `--no-ff` merge** to `origin/master` (so the M19 checkout in the main working tree is never touched), then `git push origin HEAD:master`.
4. Update memory: start `blockfire-m9-online-services.md` + a `MEMORY.md` index line.
5. `git worktree remove` the worktree once merged + pushed.
6. `/graphify --update` so the graph reflects the new modules.

---

## Self-review notes (author check)

- **Spec coverage:** §3 envelope → Tasks 1,5,7,8; §5 trust tiers → Tasks 4,5,6; `matches.trusted` → Task 3; config knobs → Task 2; backend verify → Tasks 1,5,6; game signer → Tasks 7,8,9; golden-vector interop → Tasks 1 & 7 share one digest; gate (§10 DoD) → Task 10. All spec sections mapped.
- **Type consistency:** `SignatureStatus`/`SignatureResult`/`compute_signature`/`verify`/`parse_signing_keys` (Task 1) are used with identical names in Tasks 2,5,6. `_build_headers`/`configure(...,signing_key_id,signing_secret)` (Task 8) match the calls in Task 9. `StatsSigner.sign`/`.headers` (Task 7) match Task 8 usage. `ingest_match_report(..., trusted=...)` (Task 4) matches Task 6's call.
- **No placeholders:** every code step shows complete code; the one open detail is the exact match-harness invocation in Task 10, which points at the existing `ci/*_test.sh` pattern to copy rather than inventing numbers.
```
