import datetime as dt

import pytest
from sqlalchemy import select

from app.config import Settings
from app.db import Base, init_db, make_engine, make_sessionmaker
from app.models import Match, MatchPlayer, Player


@pytest.fixture
async def session():
    engine = make_engine()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db(engine)
    sm = make_sessionmaker(engine)
    async with sm() as s:
        yield s
    await engine.dispose()


@pytest.fixture
def settings():
    return Settings()


def _parse(ts):
    # accept "...Z" ISO strings
    return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))


_DEFAULT_NOW = dt.datetime(2026, 7, 12, tzinfo=dt.timezone.utc)


async def _insert_match(session, match_id, *, trusted, complete, team_a, team_b,
                        winner, ended=None, started=None):
    """Insert a Match + its MatchPlayer rows (auto-creating Player rows to satisfy
    the FK). `team_a`/`team_b` are lists of (player_key, stats_dict)."""
    started_at = _parse(started) if started else _DEFAULT_NOW
    ended_at = _parse(ended) if ended else _DEFAULT_NOW
    session.add(Match(
        match_id=match_id, server_id="s", map="conquest_town", mode="conquest",
        report_version=1, complete=complete, ingested_at=_DEFAULT_NOW,
        trusted=trusted, winner=winner, started_at=started_at, ended_at=ended_at))
    await session.flush()  # satisfy match_players FK to matches
    for team_label, roster in (("team_a", team_a), ("team_b", team_b)):
        for key, stats in roster:
            if await session.get(Player, key) is None:
                session.add(Player(player_key=key, name=key,
                                   first_seen=_DEFAULT_NOW, last_seen=_DEFAULT_NOW))
                await session.flush()  # satisfy match_players FK to players
            session.add(MatchPlayer(match_id=match_id, player_key=key,
                                    team=team_label, **stats))
    await session.commit()


async def test_only_trusted_complete_matches_rated(session, settings):
    from app.rating_apply import update_ratings
    from app.models import PlayerRating
    await _insert_match(session, "m1", trusted=True, complete=True,
                        team_a=[("name:A", dict(kills=10, captures=2))],
                        team_b=[("name:B", dict(kills=1))], winner="team_a")
    await _insert_match(session, "m2", trusted=False, complete=True,
                        team_a=[("name:C", {})], team_b=[("name:D", {})],
                        winner="team_a")
    n = await update_ratings(session, settings)
    assert n == 1
    assert await session.get(PlayerRating, "name:A") is not None
    assert await session.get(PlayerRating, "name:C") is None
    assert (await session.get(Match, "m1")).rated is True
    assert (await session.get(Match, "m2")).rated is False


async def test_exactly_once_second_cycle_rates_zero(session, settings):
    from app.rating_apply import update_ratings
    await _insert_match(session, "m1", trusted=True, complete=True,
                        team_a=[("name:A", dict(kills=5))],
                        team_b=[("name:B", {})], winner="team_a")
    assert await update_ratings(session, settings) == 1
    assert await update_ratings(session, settings) == 0


async def test_two_team_requirement_skips_malformed(session, settings):
    from app.rating_apply import update_ratings
    from app.models import PlayerRating
    # single team -> skipped, no rating rows, and NOT marked rated
    await _insert_match(session, "m1", trusted=True, complete=True,
                        team_a=[("name:A", {}), ("name:B", {})], team_b=[],
                        winner="team_a")
    assert await update_ratings(session, settings) == 0
    assert await session.get(PlayerRating, "name:A") is None
    assert (await session.get(Match, "m1")).rated is False


async def test_rebuild_matches_incremental(session, settings):
    from app.rating_apply import update_ratings, rebuild_ratings
    from app.models import PlayerRating
    await _insert_match(session, "m1", trusted=True, complete=True,
                        ended="2026-07-12T00:00:00Z",
                        team_a=[("name:A", dict(kills=9, captures=3))],
                        team_b=[("name:B", dict(kills=1))], winner="team_a")
    await _insert_match(session, "m2", trusted=True, complete=True,
                        ended="2026-07-12T00:05:00Z",
                        team_a=[("name:A", dict(kills=8, captures=2))],
                        team_b=[("name:B", dict(kills=2))], winner="team_a")
    await update_ratings(session, settings)
    inc = {r.player_key: (round(r.mu, 9), round(r.sigma, 9))
           for r in (await session.execute(select(PlayerRating))).scalars()}
    await rebuild_ratings(session, settings)
    reb = {r.player_key: (round(r.mu, 9), round(r.sigma, 9))
           for r in (await session.execute(select(PlayerRating))).scalars()}
    assert inc == reb
    # both players rated exactly twice after the rebuild
    assert all(r.matches_rated == 2
               for r in (await session.execute(select(PlayerRating))).scalars())


async def test_require_trusted_false_rates_untrusted(session, settings):
    from app.rating_apply import update_ratings
    settings2 = settings.model_copy(update={"rating_require_trusted": False})
    await _insert_match(session, "m1", trusted=False, complete=True,
                        team_a=[("name:A", dict(kills=3))],
                        team_b=[("name:B", {})], winner="team_a")
    assert await update_ratings(session, settings2) == 1
