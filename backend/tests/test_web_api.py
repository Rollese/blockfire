import datetime as dt

from httpx import ASGITransport, AsyncClient

from app.models import Match, MatchPlayer, MatchPlayerWeapon, Player
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
    """Three players / two matches; kills and kd produce different orderings."""
    async with sm() as s:
        s.add(_match("m1", ended_at=NOW))
        s.add(_match("m2", ended_at=NOW + dt.timedelta(hours=1)))
        s.add(_player("name:P1", "P1"))
        s.add(_player("name:P2", "P2"))
        s.add(_player("name:P3", "P3", steam_id=770))
        await s.flush()

        # P1: kills 20, deaths 8 -> kd 2.5
        s.add(_mp("m1", "name:P1", kills=12, deaths=5, result="win"))
        s.add(_mp("m2", "name:P1", kills=8, deaths=3, result="loss"))
        s.add(_mpw("m1", "name:P1", "ar", shots=150, hits=50, kills=6))
        s.add(_mpw("m2", "name:P1", "ar", shots=100, hits=40, kills=5))

        # P2: kills 30 (top kills), deaths 30 -> kd 1.0
        s.add(_mp("m1", "name:P2", kills=30, deaths=30, result="win"))
        s.add(_mpw("m1", "name:P2", "wpn_a", shots=400, hits=40, kills=30))

        # P3: kills 6, deaths 2 -> kd 3.0 (top kd)
        s.add(_mp("m2", "name:P3", kills=6, deaths=2, result="win"))
        s.add(_mpw("m2", "name:P3", "dmr", shots=10, hits=9, kills=6))
        await s.commit()

    async with sm() as s:
        await recompute_profiles(s, now=NOW)


def _public_client(app):
    """A client without the Bearer header (routes are public anyway)."""
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


async def test_leaderboard_default_kills(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/api/leaderboard")
    assert r.status_code == 200
    body = r.json()
    keys = [p["player_key"] for p in body["players"]]
    assert keys == ["name:P2", "name:P1", "name:P3"]


async def test_leaderboard_sort_kd(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/api/leaderboard", params={"sort": "kd"})
    assert r.status_code == 200
    keys = [p["player_key"] for p in r.json()["players"]]
    assert keys == ["name:P3", "name:P1", "name:P2"]


async def test_leaderboard_limit(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/api/leaderboard", params={"limit": 1})
    assert r.status_code == 200
    players = r.json()["players"]
    assert len(players) == 1
    assert players[0]["player_key"] == "name:P2"


async def test_player_profile_colon_key(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/api/players/name:P1")
    assert r.status_code == 200
    body = r.json()
    assert body["player_key"] == "name:P1"
    assert body["total_kills"] == 20
    assert body["kd_ratio"] == 2.5
    assert isinstance(body["weapons"], list)
    assert body["weapons"][0]["weapon_id"] == "ar"
    assert isinstance(body["recent_matches"], list)
    assert {m["match_id"] for m in body["recent_matches"]} == {"m1", "m2"}
    # updated_at is a datetime in the dict; JSON must serialize it cleanly.
    assert body["updated_at"] is not None


async def test_player_profile_not_found(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/api/players/does:not-exist")
    assert r.status_code == 404


async def test_player_profile_datetimes_serialize(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/api/players/name:P1")
    assert r.status_code == 200
    # .json() raising would fail the test; recent match ended_at is a datetime.
    body = r.json()
    ended = [m["ended_at"] for m in body["recent_matches"]]
    assert any(v is not None for v in ended)
