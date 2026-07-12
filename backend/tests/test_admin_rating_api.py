"""Admin JSON API for the rating leaderboard (`app.admin_api`, Task 6).

Mirrors test_admin_anomaly_api.py's three-app pattern over ONE shared
sessionmaker:
  - default `client` fixture (admin_dev_open=False, no cookie) -> every new
    /admin/api rating route 403s for a non-admin caller.
  - a second app (admin_dev_open=True) -> proves the routes work + shapes.
  - a cookie-signed app (admin_dev_open=False, allowlisted steam_id) -> proves
    the cookie path works too.
"""

import datetime as dt

from httpx import ASGITransport, AsyncClient
from itsdangerous import URLSafeSerializer

from app.config import Settings
from app.main import create_app
from app.models import PlayerRating

NOW = dt.datetime(2026, 7, 12, 12, 0, 0, tzinfo=dt.timezone.utc)
ADMIN_ID = 76561198000000001


def _rating(player_key: str, *, mu: float, sigma: float, ordinal: float,
            tier: str, matches_rated: int, last_match_id: str | None = None
            ) -> PlayerRating:
    return PlayerRating(
        player_key=player_key, mu=mu, sigma=sigma, ordinal=ordinal,
        tier=tier, matches_rated=matches_rated, last_match_id=last_match_id,
        updated_at=NOW,
    )


async def _seed_ratings(sm) -> None:
    async with sm() as s:
        s.add(_rating("name:High", mu=30.0, sigma=5.0, ordinal=15.0,
                      tier="gold", matches_rated=10, last_match_id="m2"))
        s.add(_rating("name:Low", mu=20.0, sigma=6.0, ordinal=2.0,
                      tier="bronze", matches_rated=3, last_match_id="m1"))
        await s.commit()


async def _admin_client(sm) -> AsyncClient:
    """Second app over the SAME sessionmaker, admin_dev_open=True."""
    settings = Settings(ingest_token="test-token", admin_dev_open=True)
    app = create_app(settings=settings, sessionmaker=sm)
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


# ---- 1. auth gate -----------------------------------------------------------

async def test_rating_routes_403_for_non_admin(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)

    assert (await client.get("/admin/api/ratings")).status_code == 403
    assert (await client.get("/admin/api/ratings/summary")).status_code == 403


# ---- 2. dev-open happy paths ------------------------------------------------

async def test_ratings_list_and_shape(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/ratings")
    assert r.status_code == 200
    body = r.json()
    assert isinstance(body["players"], list)
    assert len(body["players"]) == 2
    # ordered by ordinal desc
    assert [p["player_key"] for p in body["players"]] == ["name:High", "name:Low"]
    top = body["players"][0]
    assert set(top.keys()) == {
        "player_key", "mu", "sigma", "ordinal", "tier",
        "matches_rated", "last_match_id",
    }
    assert top["ordinal"] == 15.0
    assert top["tier"] == "gold"
    assert top["matches_rated"] == 10
    assert top["last_match_id"] == "m2"


async def test_ratings_list_limit_offset(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/ratings", params={"limit": 1, "offset": 1})
    assert r.status_code == 200
    players = r.json()["players"]
    assert len(players) == 1
    assert players[0]["player_key"] == "name:Low"


async def test_ratings_summary(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/ratings/summary")
    assert r.status_code == 200
    body = r.json()
    assert set(body.keys()) == {
        "total_rated_players", "total_rating_applications", "tiers",
    }
    assert body["total_rated_players"] == 2
    assert body["total_rating_applications"] == 13
    assert body["tiers"] == {"gold": 1, "bronze": 1}


# ---- 3. cookie path ---------------------------------------------------------

async def test_rating_routes_cookie_path(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)

    settings = Settings(ingest_token="test-token", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    app = create_app(settings=settings, sessionmaker=sm)
    cookie = URLSafeSerializer(settings.session_secret, salt="session").dumps(
        {"steam_id": ADMIN_ID})
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        c.cookies.set("bf_session", cookie)
        r_list = await c.get("/admin/api/ratings")
        r_summary = await c.get("/admin/api/ratings/summary")
    assert r_list.status_code == 200
    assert r_summary.status_code == 200
    assert len(r_list.json()["players"]) == 2
