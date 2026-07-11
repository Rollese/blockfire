import pytest
from fastapi import Depends, FastAPI
from httpx import ASGITransport, AsyncClient

from app.auth import require_ingest_token
from app.config import Settings


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
