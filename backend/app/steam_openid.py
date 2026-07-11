"""Steam OpenID 2.0 "Sign in through Steam" login (dormant-ready).

Flow:
  GET /login         -> 302 to steamcommunity.com/openid/login (checkid_setup)
  GET /login/return  -> verify openid.* params with Steam (check_authentication),
                        extract steamid64, set a signed session cookie, 302 to
                        the player's profile.
  GET /logout        -> delete the cookie, 302 to /.

The session cookie (`bf_session`) is an itsdangerous URLSafeSerializer payload
({"steam_id": <int>}) signed with settings.session_secret. A tampered or absent
cookie yields no identity. No production data is steam-keyed yet, so this is
dormant but must be correct: verification is always enforced against Steam.
"""

import re
from urllib.parse import urlencode

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from itsdangerous import BadData, BadSignature, URLSafeSerializer

COOKIE_NAME = "bf_session"
_SALT = "session"
_STEAM_LOGIN_URL = "https://steamcommunity.com/openid/login"
_OPENID_NS = "http://specs.openid.net/auth/2.0"
_IDENTIFIER_SELECT = "http://specs.openid.net/auth/2.0/identifier_select"
_CLAIMED_ID_RE = re.compile(r"https://steamcommunity\.com/openid/id/(\d+)$")


def _serializer(secret: str) -> URLSafeSerializer:
    return URLSafeSerializer(secret, salt=_SALT)


def current_steam_id(request: Request) -> int | None:
    """Return the signed-in steamid64 from the session cookie, or None.

    None for an absent, tampered, or otherwise unreadable cookie.
    """
    raw = request.cookies.get(COOKIE_NAME)
    if not raw:
        return None
    secret = request.app.state.settings.session_secret
    try:
        data = _serializer(secret).loads(raw)
    except (BadSignature, BadData):
        return None
    steam_id = data.get("steam_id") if isinstance(data, dict) else None
    return steam_id if isinstance(steam_id, int) else None


async def _verify_with_steam(params: dict) -> bool:
    """POST the returned openid.* params back to Steam for authentication.

    Factored out so tests can monkeypatch it (no real network in tests).
    """
    payload = dict(params)
    payload["openid.mode"] = "check_authentication"
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(_STEAM_LOGIN_URL, data=payload)
    return "is_valid:true" in resp.text


def register_auth_routes(app: FastAPI) -> None:
    @app.get("/login")
    async def login(request: Request) -> RedirectResponse:
        base = request.app.state.settings.site_base_url
        params = {
            "openid.ns": _OPENID_NS,
            "openid.mode": "checkid_setup",
            "openid.return_to": f"{base}/login/return",
            "openid.realm": base,
            "openid.identity": _IDENTIFIER_SELECT,
            "openid.claimed_id": _IDENTIFIER_SELECT,
        }
        return RedirectResponse(f"{_STEAM_LOGIN_URL}?{urlencode(params)}",
                                status_code=302)

    @app.get("/login/return")
    async def login_return(request: Request) -> RedirectResponse:
        params = {k: v for k, v in request.query_params.items()
                  if k.startswith("openid.")}
        claimed_id = params.get("openid.claimed_id", "")
        m = _CLAIMED_ID_RE.search(claimed_id)
        if m is None or not await _verify_with_steam(params):
            return RedirectResponse("/", status_code=302)

        steam_id = int(m.group(1))
        secret = request.app.state.settings.session_secret
        cookie = _serializer(secret).dumps({"steam_id": steam_id})
        resp = RedirectResponse(f"/players/steam:{steam_id}", status_code=302)
        resp.set_cookie(COOKIE_NAME, cookie, httponly=True, samesite="lax")
        return resp

    @app.get("/logout")
    async def logout() -> RedirectResponse:
        resp = RedirectResponse("/", status_code=302)
        resp.delete_cookie(COOKIE_NAME)
        return resp
