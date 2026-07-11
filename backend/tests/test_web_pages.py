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
    async with sm() as s:
        s.add(_match("m1", ended_at=NOW))
        s.add(_match("m2", ended_at=NOW + dt.timedelta(hours=1)))
        s.add(_player("name:BotAlpha", "BotAlpha"))
        s.add(_player("name:P2", "P2"))
        await s.flush()

        s.add(_mp("m1", "name:BotAlpha", kills=12, deaths=5, result="win"))
        s.add(_mp("m2", "name:BotAlpha", kills=8, deaths=3, result="loss"))
        s.add(_mpw("m1", "name:BotAlpha", "ar", shots=150, hits=50, kills=6))
        s.add(_mpw("m2", "name:BotAlpha", "ar", shots=100, hits=40, kills=5))

        s.add(_mp("m1", "name:P2", kills=30, deaths=30, result="win"))
        s.add(_mpw("m1", "name:P2", "wpn_a", shots=400, hits=40, kills=30))
        await s.commit()

    async with sm() as s:
        await recompute_profiles(s, now=NOW)


def _public_client(app):
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


async def test_index_leaderboard_page(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "BotAlpha" in r.text
    assert "/players/name:BotAlpha" in r.text


async def test_profile_page_colon_key(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/players/name:BotAlpha")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "BotAlpha" in r.text
    assert "ar" in r.text          # weapon_id in breakdown table
    assert "20" in r.text          # total kills stat value


async def test_profile_page_not_found(app_and_sessionmaker):
    app, sm = app_and_sessionmaker
    await _seed(sm)
    async with _public_client(app) as c:
        r = await c.get("/players/does:not-exist")
    assert r.status_code == 404
