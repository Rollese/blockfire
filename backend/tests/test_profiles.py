import datetime as dt

from app.models import Match, MatchPlayer, MatchPlayerWeapon, Player
from app.profiles import (
    get_profile, get_recent_matches, get_weapon_totals, list_leaderboard,
)
from app.rollups import recompute_profiles

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)


def _match(mid: str, ended_at, **kw) -> Match:
    base = dict(match_id=mid, server_id="s1", map="dust", mode="conquest",
                started_at=NOW, ended_at=ended_at, report_version=1,
                complete=True, ingested_at=NOW)
    base.update(kw)
    return Match(**base)


def _player(key: str, name: str, steam_id: int | None = None) -> Player:
    return Player(player_key=key, steam_id=steam_id, name=name,
                  first_seen=NOW, last_seen=NOW)


def _mp(mid: str, key: str, **kw) -> MatchPlayer:
    base = dict(match_id=mid, player_key=key, team="team_a", kills=0, deaths=0,
                assists=0, downs=0, revives=0, captures=0, neutralizes=0,
                xp_earned=0, longest_kill_m=0.0, playtime_s=0, result="")
    base.update(kw)
    return MatchPlayer(**base)


def _mpw(mid: str, key: str, wid: str, **kw) -> MatchPlayerWeapon:
    base = dict(match_id=mid, player_key=key, weapon_id=wid, shots=0, hits=0,
                kills=0, headshots=0, damage=0, time_used_s=0)
    base.update(kw)
    return MatchPlayerWeapon(**base)


async def _seed(sm):
    """Two matches, three players. Designed so the leaderboard sort columns
    each produce a *different* ordering, so ties/tiebreaks are testable."""
    async with sm() as s:
        # m1 ended earlier, m2 later; m3 has NULL ended_at (should sort last)
        s.add(_match("m1", ended_at=NOW))
        s.add(_match("m2", ended_at=NOW + dt.timedelta(hours=1)))
        s.add(_match("m3", ended_at=None))
        s.add(_player("name:P1", "P1"))
        s.add(_player("name:P2", "P2"))
        s.add(_player("name:P3", "P3", steam_id=770))
        await s.flush()

        # ---- P1: kills 20, deaths 8 -> kd 2.5; win + loss; matches 2 -------
        s.add(_mp("m1", "name:P1", kills=12, deaths=5, result="win"))
        s.add(_mp("m2", "name:P1", kills=8, deaths=3, result="loss"))
        # ar shots 250 hits 90 (favorite); smg shots 170 hits 60
        s.add(_mpw("m1", "name:P1", "ar", shots=150, hits=50, kills=6,
                   headshots=2, damage=1200, time_used_s=600))
        s.add(_mpw("m2", "name:P1", "ar", shots=100, hits=40, kills=5,
                   headshots=1, damage=900, time_used_s=400))
        s.add(_mpw("m1", "name:P1", "smg", shots=170, hits=60, kills=4,
                   headshots=3, damage=800, time_used_s=300))

        # ---- P2: kills 30 (top kills), deaths 30 -> kd 1.0; 2 wins ---------
        s.add(_mp("m1", "name:P2", kills=15, deaths=15, result="win"))
        s.add(_mp("m3", "name:P2", kills=15, deaths=15, result="win"))
        # low hit rate: 400 shots / 40 hits = 0.1
        s.add(_mpw("m1", "name:P2", "wpn_a", shots=400, hits=40, kills=30))

        # ---- P3: kills 6, deaths 2 -> kd 3.0 (top kd); high hit rate ------
        s.add(_mp("m2", "name:P3", kills=6, deaths=2, result="win"))
        # 10 shots / 9 hits = 0.9 (top hit rate)
        s.add(_mpw("m2", "name:P3", "dmr", shots=10, hits=9, kills=6))
        await s.commit()

    async with sm() as s:
        await recompute_profiles(s, now=NOW)


async def test_get_profile_returns_dict(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        p1 = await get_profile(s, "name:P1")
    assert isinstance(p1, dict)
    assert p1["player_key"] == "name:P1"
    assert p1["total_kills"] == 20
    assert p1["total_deaths"] == 8
    assert p1["kd_ratio"] == 2.5
    assert p1["favorite_weapon_id"] == "ar"
    assert p1["overall_hit_rate"] == round(150 / 420, 4)
    assert p1["display_name"] == "P1"


async def test_get_profile_unknown_returns_none(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        assert await get_profile(s, "name:NOBODY") is None


async def test_leaderboard_default_kills(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await list_leaderboard(s)
    keys = [r["player_key"] for r in rows]
    # kills: P2=30, P1=20, P3=6
    assert keys == ["name:P2", "name:P1", "name:P3"]
    assert all(isinstance(r, dict) for r in rows)


async def test_leaderboard_sort_kd(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await list_leaderboard(s, sort="kd")
    # kd: P3=3.0, P1=2.5, P2=1.0
    assert [r["player_key"] for r in rows] == ["name:P3", "name:P1", "name:P2"]


async def test_leaderboard_sort_hit_rate(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await list_leaderboard(s, sort="hit_rate")
    # hit_rate: P3=0.9, P1~0.357, P2=0.1
    assert [r["player_key"] for r in rows] == ["name:P3", "name:P1", "name:P2"]


async def test_leaderboard_sort_wins(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await list_leaderboard(s, sort="wins")
    # wins: P2=2, then P1=1 & P3=1 tie -> player_key ASC tiebreak
    assert [r["player_key"] for r in rows] == ["name:P2", "name:P1", "name:P3"]


async def test_leaderboard_unknown_sort_falls_back_to_kills(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await list_leaderboard(s, sort="bogus")
    assert [r["player_key"] for r in rows] == ["name:P2", "name:P1", "name:P3"]


async def test_leaderboard_respects_limit(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await list_leaderboard(s, limit=1)
    assert len(rows) == 1
    assert rows[0]["player_key"] == "name:P2"


async def test_weapon_totals_ordering_and_hit_rate(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        weps = await get_weapon_totals(s, "name:P1")
    # shots: ar=250, smg=170 -> ar first
    assert [w["weapon_id"] for w in weps] == ["ar", "smg"]
    assert weps[0]["hit_rate"] == round(90 / 250, 4)
    assert weps[1]["hit_rate"] == round(60 / 170, 4)


async def test_weapon_totals_zero_shots_hit_rate(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    # give P3 a weapon row with zero shots via a fresh recompute path:
    # instead insert directly into player_weapon_totals is easier — use model.
    from app.models import PlayerWeaponTotal
    async with sm() as s:
        s.add(PlayerWeaponTotal(player_key="name:P3", weapon_id="knife",
                                shots=0, hits=0))
        await s.commit()
    async with sm() as s:
        weps = await get_weapon_totals(s, "name:P3")
    knife = next(w for w in weps if w["weapon_id"] == "knife")
    assert knife["hit_rate"] == 0.0


async def test_weapon_totals_empty(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        assert await get_weapon_totals(s, "name:NOBODY") == []


async def test_recent_matches_newest_first(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await get_recent_matches(s, "name:P1")
    # P1 played m1 (NOW) and m2 (NOW+1h) -> m2 newest first
    assert [r["match_id"] for r in rows] == ["m2", "m1"]
    first = rows[0]
    assert first["map"] == "dust"
    assert first["mode"] == "conquest"
    assert first["result"] == "loss"
    assert first["kills"] == 8
    assert first["deaths"] == 3
    assert "ended_at" in first


async def test_recent_matches_nulls_last(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await get_recent_matches(s, "name:P2")
    # P2 played m1 (NOW) and m3 (NULL ended_at) -> m1 first, m3 last
    assert [r["match_id"] for r in rows] == ["m1", "m3"]


async def test_recent_matches_respects_limit(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await get_recent_matches(s, "name:P1", limit=1)
    assert len(rows) == 1
    assert rows[0]["match_id"] == "m2"
