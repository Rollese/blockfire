import time

import pytest
from fastapi import Depends, FastAPI, Request, Response
from httpx import ASGITransport, AsyncClient

from app.auth import require_ingest_token, require_valid_signature
from app.config import Settings
from app.signing import compute_signature


def _app(token: str) -> FastAPI:
    app = FastAPI()
    app.dependency_overrides = {}
    app.state.settings = Settings(database_url="x", ingest_token=token)

    @app.post("/guarded", dependencies=[Depends(require_ingest_token)])
    async def guarded():
        return {"ok": True}

    return app


async def _post(app, headers):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        return await c.post("/guarded", headers=headers)


async def test_valid_token_allows():
    r = await _post(_app("secret"), {"Authorization": "Bearer secret"})
    assert r.status_code == 200


async def test_missing_token_401():
    r = await _post(_app("secret"), {})
    assert r.status_code == 401


async def test_wrong_token_401():
    r = await _post(_app("secret"), {"Authorization": "Bearer nope"})
    assert r.status_code == 401


KEY_ID = "game2-dev-1"
SECRET = "test-secret"


def _sig_app(settings):
    app = FastAPI()
    app.state.settings = settings
    @app.post("/t", dependencies=[Depends(require_valid_signature)])
    async def t(request: Request) -> Response:
        return Response(str(getattr(request.state, "ingest_trusted", "missing")))
    return app


async def _sig_post(app, body: bytes, headers: dict):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        return await c.post("/t", content=body, headers=headers)


def _signed_headers(body: bytes, ts=None):
    ts = ts if ts is not None else int(time.time())
    sig = compute_signature(SECRET, KEY_ID, str(ts), body)
    return {"X-BF-Key-Id": KEY_ID, "X-BF-Timestamp": str(ts), "X-BF-Signature": sig}


async def test_valid_signature_sets_trusted_true():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    body = b'{"x":1}'
    r = await _sig_post(_sig_app(s), body, _signed_headers(body))
    assert r.status_code == 200 and r.text == "True"


async def test_unsigned_sets_trusted_false_by_default():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    r = await _sig_post(_sig_app(s), b'{"x":1}', {})
    assert r.status_code == 200 and r.text == "False"


async def test_unsigned_rejected_when_required():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}",
                 require_signed_ingest=True)
    r = await _sig_post(_sig_app(s), b'{"x":1}', {})
    assert r.status_code == 401


async def test_forged_signature_rejected():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    body = b'{"x":1}'
    h = _signed_headers(body); h["X-BF-Signature"] = "0" * 64
    r = await _sig_post(_sig_app(s), body, h)
    assert r.status_code == 401


async def test_stale_timestamp_rejected():
    s = Settings(ingest_token="t", ingest_signing_keys=f"{KEY_ID}:{SECRET}")
    body = b'{"x":1}'
    r = await _sig_post(_sig_app(s), body, _signed_headers(body, ts=1))
    assert r.status_code == 401
