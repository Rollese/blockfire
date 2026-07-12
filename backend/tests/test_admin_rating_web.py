"""Admin rating leaderboard HTML page (`app.admin_web` Task 6): the auth
gate, the rendered leaderboard + summary, paging, the empty state, and
autoescape/XSS safety.

Mirrors test_admin_anomaly_web.py: the default `client` fixture
(admin_dev_open=False, no cookie) proves the 403 gate; a second app built
here with admin_dev_open=True over the SAME sessionmaker proves the page
renders.
"""

import datetime as dt

from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.main import create_app
from app.models import PlayerRating

NOW = dt.datetime(2026, 7, 12, 12, 0, 0, tzinfo=dt.timezone.utc)


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
    settings = Settings(ingest_token="test-token", admin_dev_open=True)
    app = create_app(settings=settings, sessionmaker=sm)
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


# --- 1. gate -----------------------------------------------------------------

async def test_ratings_page_403_for_non_admin(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)
    assert (await client.get("/admin/ratings")).status_code == 403


# --- 2. dev-open GET ----------------------------------------------------------

async def test_ratings_page_renders_leaderboard(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/ratings")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Rating Leaderboard" in r.text
    assert "name:High" in r.text
    assert "name:Low" in r.text
    assert "gold" in r.text
    # ordinal-desc ordering: High appears before Low in the markup
    assert r.text.index("name:High") < r.text.index("name:Low")
    # summary block present
    assert "Rated players" in r.text


async def test_ratings_page_limit_offset(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ratings(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/ratings", params={"limit": 1, "offset": 1})
    assert r.status_code == 200
    assert "name:Low" in r.text
    assert "name:High" not in r.text


# --- 3. nav --------------------------------------------------------------

async def test_ratings_link_present_in_admin_nav(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.get("/admin")
    assert r.status_code == 200
    assert '/admin/ratings' in r.text


# --- 4. empty DB ---------------------------------------------------------

async def test_ratings_page_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/ratings")
    assert r.status_code == 200
    assert "No rated players yet." in r.text


# --- 5. autoescape / XSS --------------------------------------------------

async def test_ratings_player_key_is_autoescaped(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    payload = '"><script>alert(1)</script>'
    async with sm() as s:
        s.add(_rating(payload, mu=25.0, sigma=5.0, ordinal=9.0,
                      tier="silver", matches_rated=1))
        await s.commit()
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/ratings")
    assert r.status_code == 200
    assert "<script>alert(1)</script>" not in r.text   # not injected raw
    assert "&lt;script&gt;" in r.text                   # escaped instead
