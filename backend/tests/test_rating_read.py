"""Unit tests for `app.rating_read` (Task 6, spec §6): pure read-layer
functions over `PlayerRating`, no HTTP/admin gating involved here (that's
covered by test_admin_rating_api.py / test_admin_rating_web.py).
"""

import datetime as dt

from app.models import PlayerRating
from app.rating_read import leaderboard, rating_summary

NOW = dt.datetime(2026, 7, 12, 12, 0, 0, tzinfo=dt.timezone.utc)


def _rating(player_key: str, *, mu: float, sigma: float, ordinal: float,
            tier: str, matches_rated: int, last_match_id: str | None = None
            ) -> PlayerRating:
    return PlayerRating(
        player_key=player_key, mu=mu, sigma=sigma, ordinal=ordinal,
        tier=tier, matches_rated=matches_rated, last_match_id=last_match_id,
        updated_at=NOW,
    )


async def _seed(sm) -> None:
    async with sm() as s:
        s.add(_rating("name:Low", mu=20.0, sigma=6.0, ordinal=2.0,
                      tier="bronze", matches_rated=3, last_match_id="m1"))
        s.add(_rating("name:High", mu=30.0, sigma=5.0, ordinal=15.0,
                      tier="gold", matches_rated=10, last_match_id="m2"))
        s.add(_rating("name:Mid", mu=25.0, sigma=5.5, ordinal=8.5,
                      tier="silver", matches_rated=6, last_match_id="m3"))
        # ties on ordinal -> broken by player_key ascending
        s.add(_rating("name:TieB", mu=25.0, sigma=5.0, ordinal=8.5,
                      tier="silver", matches_rated=4, last_match_id="m4"))
        await s.commit()


async def test_leaderboard_orders_by_ordinal_desc(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await leaderboard(s)

    assert [r.player_key for r in rows] == [
        "name:High", "name:Mid", "name:TieB", "name:Low",
    ]
    assert rows[0].ordinal == 15.0
    assert rows[0].tier == "gold"


async def test_leaderboard_limit_offset(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await leaderboard(s, limit=1, offset=1)

    assert len(rows) == 1
    assert rows[0].player_key == "name:Mid"


async def test_rating_summary_counts_and_tiers(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        summary = await rating_summary(s)

    assert summary["total_rated_players"] == 4
    assert summary["total_rating_applications"] == 3 + 10 + 6 + 4
    assert summary["tiers"] == {"bronze": 1, "gold": 1, "silver": 2}


async def test_rating_summary_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        summary = await rating_summary(s)

    assert summary == {
        "total_rated_players": 0,
        "total_rating_applications": 0,
        "tiers": {},
    }
