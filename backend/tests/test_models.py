import datetime as dt
import pytest
from sqlalchemy import select

from app.db import Base, init_db, make_engine, make_sessionmaker
from app.models import AnomalyFlag, Player, PlayerProfile, PlayerWeaponTotal


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


async def test_player_profile_roundtrips(sessionmaker_fixture):
    now = dt.datetime(2026, 7, 11, tzinfo=dt.timezone.utc)
    async with sessionmaker_fixture() as s:
        s.add(PlayerProfile(player_key="steam:76561198000000000", steam_id=76561198000000000,
                            display_name="Ace", avatar_url="http://x/a.png",
                            total_kills=42, total_deaths=17, kd_ratio=2.47,
                            total_shots=200, total_hits=90, overall_hit_rate=0.45,
                            longest_kill_m=312.5, favorite_weapon_id="m16",
                            total_playtime_s=3600, updated_at=now))
        await s.commit()
    async with sessionmaker_fixture() as s:
        got = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "steam:76561198000000000"))).scalar_one()
        assert got.steam_id == 76561198000000000
        assert got.display_name == "Ace"
        assert got.total_kills == 42
        assert got.kd_ratio == 2.47
        assert got.longest_kill_m == 312.5
        assert got.favorite_weapon_id == "m16"
        # defaults applied for columns not supplied
        assert got.total_assists == 0
        assert got.matches_played == 0
        assert got.xp_total == 0


async def test_player_profile_defaults(sessionmaker_fixture):
    now = dt.datetime(2026, 7, 11, tzinfo=dt.timezone.utc)
    async with sessionmaker_fixture() as s:
        s.add(PlayerProfile(player_key="name:Bot_B", updated_at=now))
        await s.commit()
    async with sessionmaker_fixture() as s:
        got = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:Bot_B"))).scalar_one()
        assert got.steam_id is None
        assert got.display_name is None
        assert got.favorite_weapon_id is None
        assert got.total_kills == 0
        assert got.kd_ratio == 0.0
        assert got.overall_hit_rate == 0.0
        assert got.total_playtime_s == 0


async def test_player_weapon_total_composite_pk(sessionmaker_fixture):
    async with sessionmaker_fixture() as s:
        s.add(PlayerWeaponTotal(player_key="name:Bot_A", weapon_id="m16",
                                shots=100, hits=40, kills=10, headshots=3,
                                damage=1200, time_used_s=300, matches_used=5))
        s.add(PlayerWeaponTotal(player_key="name:Bot_A", weapon_id="ak74",
                                shots=50, hits=20, kills=4, matches_used=2))
        await s.commit()
    async with sessionmaker_fixture() as s:
        rows = (await s.execute(select(PlayerWeaponTotal).where(
            PlayerWeaponTotal.player_key == "name:Bot_A").order_by(
            PlayerWeaponTotal.weapon_id))).scalars().all()
        assert [r.weapon_id for r in rows] == ["ak74", "m16"]
        ak, m16 = rows
        assert ak.shots == 50
        assert ak.headshots == 0  # default
        assert ak.time_used_s == 0  # default
        assert m16.kills == 10
        assert m16.matches_used == 5


async def test_anomaly_flag_defaults(sessionmaker_fixture):
    now = dt.datetime(2026, 7, 11, tzinfo=dt.timezone.utc)
    async with sessionmaker_fixture() as s:
        s.add(AnomalyFlag(player_key="steam:76561198000000000", metric="kd",
                          value=8.3, threshold=4.0, sample_size=42, severity="high",
                          created_at=now, last_seen_at=now))
        await s.commit()
    async with sessionmaker_fixture() as s:
        got = (await s.execute(select(AnomalyFlag).where(
            AnomalyFlag.player_key == "steam:76561198000000000"))).scalar_one()
        assert got.metric == "kd"
        assert got.value == 8.3
        assert got.threshold == 4.0
        assert got.sample_size == 42
        assert got.severity == "high"
        # defaults applied for columns not supplied
        assert got.status == "open"
        assert got.detector_version == 1
        assert got.context == {}
        # nullable review fields default to None
        assert got.reviewed_at is None
        assert got.reviewed_by is None
        assert got.notes is None
