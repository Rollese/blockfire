import datetime as dt

from sqlalchemy import func, select

from app.config import Settings
from app.models import (
    Event, Match, MatchPlayer, MatchPlayerWeapon, Player, PlayerProfile,
)
from worker import run

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)


def _settings() -> Settings:
    # database_url picked up from env (DATABASE_URL); steam key absent -> enrich no-op.
    return Settings(ingest_token="test-token", steam_web_api_key=None)


async def _seed_match(sm):
    async with sm() as s:
        s.add(Match(match_id="m1", server_id="s1", map="dust", mode="conquest",
                    report_version=1, complete=True, ingested_at=NOW))
        s.add(Player(player_key="name:P1", steam_id=None, name="P1",
                     first_seen=NOW, last_seen=NOW))
        await s.flush()
        s.add(MatchPlayer(match_id="m1", player_key="name:P1", team="team_a",
                          kills=10, deaths=4, result="win"))
        s.add(MatchPlayerWeapon(match_id="m1", player_key="name:P1",
                                weapon_id="ar", shots=100, hits=40, kills=10))
        await s.commit()


async def test_run_cycle_prunes_rolls_up_no_enrich(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_match(sm)

    result = await run.run_cycle(sm, _settings())

    assert result["profiles"] >= 1
    assert result["enriched"] == 0

    async with sm() as s:
        n = (await s.execute(
            select(func.count()).select_from(PlayerProfile)
        )).scalar_one()
        assert n >= 1
        p1 = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P1"))).scalar_one()
        assert p1.total_kills == 10


async def test_run_cycle_step_isolation(app_and_sessionmaker, monkeypatch):
    _, sm = app_and_sessionmaker
    # An old event so prune has real work to do.
    async with sm() as s:
        s.add(Event(match_id="m1", tick=1, type="kill", payload={},
                    created_at=dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=200)))
        await s.commit()

    async def _boom(*args, **kwargs):
        raise RuntimeError("rollup blew up")

    monkeypatch.setattr(run, "recompute_profiles", _boom)

    # Must not propagate: rollup failure is isolated from prune + enrich.
    result = await run.run_cycle(sm, _settings())

    assert result["pruned"] == 1   # prune still succeeded
    assert result["profiles"] == 0  # rollup raised -> 0
    assert result["enriched"] == 0

    async with sm() as s:
        remaining = (await s.execute(
            select(func.count()).select_from(Event))).scalar_one()
        assert remaining == 0
