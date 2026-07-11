"""Admin auth guard: is_admin / require_admin truth table.

Cookies are real itsdangerous-signed bf_session payloads (built the same way
app.steam_openid does it), so these tests genuinely exercise
current_steam_id -- nothing about the cookie mechanics is mocked.
"""

from types import SimpleNamespace

import pytest
from fastapi import Depends, FastAPI, HTTPException
from httpx import ASGITransport, AsyncClient
from itsdangerous import URLSafeSerializer

from app.admin_auth import is_admin, require_admin
from app.config import Settings

ADMIN_ID = 76561198000000001
OTHER_ID = 76561198000000002


def _signed_cookie(secret: str, steam_id: int) -> str:
    return URLSafeSerializer(secret, salt="session").dumps({"steam_id": steam_id})


def _fake_request(settings: Settings, cookies: dict) -> SimpleNamespace:
    app = SimpleNamespace(state=SimpleNamespace(settings=settings))
    return SimpleNamespace(app=app, cookies=cookies)


def test_dev_open_true_admits_with_no_cookie():
    settings = Settings(ingest_token="t", admin_dev_open=True,
                        admin_steam_ids="")
    request = _fake_request(settings, {})
    assert is_admin(request) is True
    require_admin(request)  # does not raise


def test_dev_open_false_no_cookie_denied():
    settings = Settings(ingest_token="t", admin_dev_open=False,
                        admin_steam_ids=str(ADMIN_ID))
    request = _fake_request(settings, {})
    assert is_admin(request) is False
    with pytest.raises(HTTPException) as exc_info:
        require_admin(request)
    assert exc_info.value.status_code == 403


def test_dev_open_false_valid_cookie_allowlisted_admitted():
    settings = Settings(ingest_token="t", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    cookie = _signed_cookie(settings.session_secret, ADMIN_ID)
    request = _fake_request(settings, {"bf_session": cookie})
    assert is_admin(request) is True
    require_admin(request)  # does not raise


def test_dev_open_false_valid_cookie_not_allowlisted_denied():
    settings = Settings(ingest_token="t", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    cookie = _signed_cookie(settings.session_secret, OTHER_ID)
    request = _fake_request(settings, {"bf_session": cookie})
    assert is_admin(request) is False
    with pytest.raises(HTTPException) as exc_info:
        require_admin(request)
    assert exc_info.value.status_code == 403


# --- End-to-end wiring: require_admin as a real FastAPI dependency --------

async def _client_for(settings: Settings) -> AsyncClient:
    app = FastAPI()
    app.state.settings = settings

    @app.get("/admin/ping")
    async def admin_ping(_: None = Depends(require_admin)) -> dict:
        return {"ok": True}

    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


async def test_require_admin_route_dev_open_no_cookie_returns_200():
    settings = Settings(ingest_token="t", admin_dev_open=True)
    async with await _client_for(settings) as c:
        r = await c.get("/admin/ping")
    assert r.status_code == 200


async def test_require_admin_route_denies_without_valid_cookie():
    settings = Settings(ingest_token="t", admin_dev_open=False,
                        admin_steam_ids=str(ADMIN_ID))
    async with await _client_for(settings) as c:
        r = await c.get("/admin/ping")
    assert r.status_code == 403


async def test_require_admin_route_admits_allowlisted_cookie():
    settings = Settings(ingest_token="t", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    cookie = _signed_cookie(settings.session_secret, ADMIN_ID)
    async with await _client_for(settings) as c:
        c.cookies.set("bf_session", cookie)
        r = await c.get("/admin/ping")
    assert r.status_code == 200


async def test_require_admin_route_denies_non_allowlisted_cookie():
    settings = Settings(ingest_token="t", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    cookie = _signed_cookie(settings.session_secret, OTHER_ID)
    async with await _client_for(settings) as c:
        c.cookies.set("bf_session", cookie)
        r = await c.get("/admin/ping")
    assert r.status_code == 403
