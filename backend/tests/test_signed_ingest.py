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


async def _make_app(require_signed: bool):
    engine = make_engine()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db(engine)
    sm = make_sessionmaker(engine)
    settings = Settings(ingest_token="test-token",
                        ingest_signing_keys=f"{KEY_ID}:{SECRET}",
                        require_signed_ingest=require_signed)
    return create_app(settings=settings, sessionmaker=sm), sm, engine


@pytest.fixture
async def signed_app():
    app, sm, engine = await _make_app(require_signed=False)
    yield app, sm
    await engine.dispose()


@pytest.fixture
async def signed_app_required():
    app, sm, engine = await _make_app(require_signed=True)
    yield app, sm
    await engine.dispose()


async def _client(app):
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://t")


async def test_signed_match_is_trusted(signed_app):
    app, sm = signed_app
    raw = _raw("m-signed")
    async with await _client(app) as c:
        r = await c.post("/ingest/match", content=raw, headers=_headers(raw))
    assert r.status_code == 202
    async with sm() as s:
        row = (await s.execute(select(Match).where(Match.match_id == "m-signed"))).scalar_one()
        assert row.trusted is True


async def test_signed_match_idempotent_double_post(signed_app):
    app, sm = signed_app
    raw = _raw("m-idem")
    async with await _client(app) as c:
        await c.post("/ingest/match", content=raw, headers=_headers(raw))
        await c.post("/ingest/match", content=raw, headers=_headers(raw))
    async with sm() as s:
        rows = (await s.execute(select(Match).where(Match.match_id == "m-idem"))).scalars().all()
        assert len(rows) == 1 and rows[0].trusted is True


async def test_unsigned_rejected_when_required(signed_app_required):
    app, sm = signed_app_required
    raw = _raw("m-req")
    async with await _client(app) as c:
        r = await c.post("/ingest/match", content=raw,
                         headers={"Authorization": "Bearer test-token",
                                  "Content-Type": "application/json"})
    assert r.status_code == 401


async def test_signed_events_accepted(signed_app):
    app, sm = signed_app
    raw = json.dumps({"match_id": "m-ev", "batch_seq": 0,
                      "events": [{"tick": 1, "type": "kill"}]}).encode()
    async with await _client(app) as c:
        r = await c.post("/ingest/events", content=raw, headers=_headers(raw))
    assert r.status_code == 202
