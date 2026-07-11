"""Steam OpenID 2.0 login: URL build, return verification, signed session.

No real network: the Steam verification call (_verify_with_steam) is
monkeypatched. The signed-cookie round-trip is exercised directly via
current_steam_id.
"""

from urllib.parse import parse_qs, urlparse

import app.steam_openid as steam_openid
from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.steam_openid import current_steam_id

RETURN_ID = "https://steamcommunity.com/openid/id/76561198000000000"


def _noredirect_client(app):
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t",
                       follow_redirects=False)


async def test_login_redirects_to_steam(app_and_sessionmaker):
    app, _ = app_and_sessionmaker
    async with _noredirect_client(app) as c:
        r = await c.get("/login")
    assert r.status_code == 302
    loc = r.headers["location"]
    parsed = urlparse(loc)
    assert parsed.scheme == "https"
    assert parsed.netloc == "steamcommunity.com"
    assert parsed.path == "/openid/login"
    q = parse_qs(parsed.query)
    assert q["openid.mode"] == ["checkid_setup"]
    assert q["openid.ns"] == ["http://specs.openid.net/auth/2.0"]
    base = app.state.settings.site_base_url
    assert q["openid.return_to"] == [f"{base}/login/return"]
    assert q["openid.realm"] == [base]
    assert q["openid.identity"] == [
        "http://specs.openid.net/auth/2.0/identifier_select"]


async def test_login_return_success_sets_cookie(app_and_sessionmaker,
                                                monkeypatch):
    app, _ = app_and_sessionmaker

    async def fake_verify(params):
        return True

    monkeypatch.setattr(steam_openid, "_verify_with_steam", fake_verify)
    async with _noredirect_client(app) as c:
        r = await c.get("/login/return", params={
            "openid.mode": "id_res",
            "openid.claimed_id": RETURN_ID,
            "openid.identity": RETURN_ID,
            "openid.sig": "abc",
        })
    assert r.status_code == 302
    assert r.headers["location"] == "/players/steam:76561198000000000"
    assert "bf_session" in r.cookies
    # The cookie decodes to the expected steam id.
    settings = app.state.settings
    from itsdangerous import URLSafeSerializer
    s = URLSafeSerializer(settings.session_secret, salt="session")
    assert s.loads(r.cookies["bf_session"]) == {
        "steam_id": 76561198000000000}


async def test_login_return_invalid_no_cookie(app_and_sessionmaker,
                                              monkeypatch):
    app, _ = app_and_sessionmaker

    async def fake_verify(params):
        return False

    monkeypatch.setattr(steam_openid, "_verify_with_steam", fake_verify)
    async with _noredirect_client(app) as c:
        r = await c.get("/login/return", params={
            "openid.mode": "id_res",
            "openid.claimed_id": RETURN_ID,
        })
    assert r.status_code == 302
    assert r.headers["location"] == "/"
    assert "bf_session" not in r.cookies


async def test_logout_clears_cookie(app_and_sessionmaker):
    app, _ = app_and_sessionmaker
    async with _noredirect_client(app) as c:
        r = await c.get("/logout")
    assert r.status_code == 302
    assert r.headers["location"] == "/"
    # Cookie is deleted (empty value / max-age 0 in Set-Cookie).
    set_cookie = r.headers.get("set-cookie", "")
    assert "bf_session=" in set_cookie


def _fake_request(settings, cookies):
    from types import SimpleNamespace
    app = SimpleNamespace(state=SimpleNamespace(settings=settings))
    return SimpleNamespace(app=app, cookies=cookies)


def test_current_steam_id_roundtrip_and_tamper():
    settings = Settings(ingest_token="t", session_secret="topsecret")
    from itsdangerous import URLSafeSerializer

    s = URLSafeSerializer(settings.session_secret, salt="session")
    good = s.dumps({"steam_id": 76561198000000000})
    assert current_steam_id(
        _fake_request(settings, {"bf_session": good})) == 76561198000000000

    # No cookie -> None.
    assert current_steam_id(_fake_request(settings, {})) is None

    # Tampered / garbage cookie -> None.
    assert current_steam_id(
        _fake_request(settings, {"bf_session": good + "x"})) is None
    assert current_steam_id(
        _fake_request(settings, {"bf_session": "garbage"})) is None
