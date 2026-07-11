import datetime as dt
import pytest
from sqlalchemy import select

from app.db import Base, init_db, make_engine, make_sessionmaker
from app.models import Player


@pytest.fixture
async def sessionmaker_fixture():
    engine = make_engine()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db(engine)
    yield make_sessionmaker(engine)
    await engine.dispose()


async def test_player_roundtrips(sessionmaker_fixture):
    now = dt.datetime(2026, 7, 11, tzinfo=dt.timezone.utc)
    async with sessionmaker_fixture() as s:
        s.add(Player(player_key="name:Bot_A", steam_id=None, name="Bot_A",
                     first_seen=now, last_seen=now))
        await s.commit()
    async with sessionmaker_fixture() as s:
        got = (await s.execute(select(Player).where(Player.player_key == "name:Bot_A"))).scalar_one()
        assert got.name == "Bot_A"
        assert got.steam_id is None
