"""Admin HTML dashboards (`app.admin_web`): route wiring + the admin auth
gate, mirroring test_admin_api.py's pattern but asserting on rendered HTML
instead of JSON.

Two apps share the same sessionmaker/DB from `app_and_sessionmaker`:
  - the default `client` fixture (admin_dev_open=False, no cookie) -> proves
    every /admin* page 403s for a non-admin caller.
  - a second app built here with admin_dev_open=True -> proves the pages
    render real data once the caller IS an admin.
"""

import datetime as dt

from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.main import create_app
from app.models import Event, Match, MatchPlayerWeapon, Player

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)


def _match(mid: str) -> Match:
    return Match(match_id=mid, server_id="s1", map="dust", mode="conquest",
                 report_version=1, complete=True, ingested_at=NOW)


def _player(key: str, name: str) -> Player:
    return Player(player_key=key, name=name, first_seen=NOW, last_seen=NOW)


def _mpw(mid: str, key: str, wid: str, **kw) -> MatchPlayerWeapon:
    base = dict(match_id=mid, player_key=key, weapon_id=wid, shots=0, hits=0,
                kills=0, headshots=0, damage=0, time_used_s=0)
    base.update(kw)
    return MatchPlayerWeapon(**base)


def _kill_event(mid, tick, actor, target, wid, distance, hitzone):
    return Event(match_id=mid, tick=tick, type="kill", actor_key=actor, target_key=target,
                 weapon_id=wid,
                 payload={"distance_m": distance, "hitzone": hitzone,
                          "actor_pos": [0, 0, 0], "target_pos": [0, 0, 0]},
                 created_at=NOW)


async def _seed(sm):
    """1 match, 2 players, 2 weapons ("ar" x2 kill events, "smg" x1)."""
    async with sm() as s:
        s.add(_match("m1"))
        s.add(_player("name:P1", "P1"))
        s.add(_player("name:P2", "P2"))
        await s.flush()

        s.add(_mpw("m1", "name:P1", "ar", shots=100, hits=50, kills=6,
                   headshots=2, damage=1200))
        s.add(_mpw("m1", "name:P2", "smg", shots=80, hits=30, kills=3,
                   headshots=1, damage=500))

        s.add(_kill_event("m1", 10, "name:P1", "name:P2", "ar", 5.0, "head"))
        s.add(_kill_event("m1", 20, "name:P2", "name:P1", "smg", 40.0, "body"))
        s.add(_kill_event("m1", 30, "name:P1", "name:P2", "ar", 90.0, "head"))
        await s.commit()


async def _admin_client(sm) -> AsyncClient:
    """Second app over the SAME sessionmaker, admin_dev_open=True."""
    settings = Settings(ingest_token="test-token", admin_dev_open=True)
    app = create_app(settings=settings, sessionmaker=sm)
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


ADMIN_PAGES = ["/admin", "/admin/combat", "/admin/events"]


async def test_admin_pages_403_for_non_admin(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    for path in ADMIN_PAGES:
        r = await client.get(path)
        assert r.status_code == 403, path


async def test_admin_index_page_renders_weapon_data(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Admin Overview" in r.text
    assert "Weapon balance" in r.text
    assert "Usage distribution" in r.text
    assert "ar" in r.text
    assert "smg" in r.text
    # sub-nav present
    assert "Overview" in r.text and "Combat" in r.text and "Events" in r.text
    # headline totals from admin_summary
    assert "Matches" in r.text and "Kill events" in r.text


async def test_admin_index_page_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.get("/admin")
    assert r.status_code == 200
    assert "No weapon data yet." in r.text


async def test_admin_combat_page_renders_sections(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/combat")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Kill distance" in r.text
    assert "Hitzone breakdown" in r.text
    assert "Longest kills" in r.text
    assert "ar" in r.text
    assert "name:P1" in r.text


async def test_admin_combat_page_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/combat")
    assert r.status_code == 200
    assert "No kill-distance data yet." in r.text
    assert "No kills yet." in r.text


async def test_admin_events_page_default_lists_all_kills(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/events")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "ar" in r.text
    assert "smg" in r.text


async def test_admin_events_page_filters_by_weapon_and_preserves_value(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/events", params={"weapon_id": "ar"})
    assert r.status_code == 200
    assert 'value="ar"' in r.text          # filter value preserved in the form
    assert "smg" not in r.text             # the smg kill row is filtered out
    assert r.text.count('<td>ar</td>') == 2  # both "ar" kill events remain


async def test_admin_events_page_filters_by_min_distance(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/events", params={"min_distance_m": 50})
    assert r.status_code == 200
    assert "90.0" in r.text   # tick=30 (distance 90) survives the filter
    assert "40.0" not in r.text  # tick=20 (distance 40) is filtered out
    assert "5.0 m" not in r.text  # tick=10 (distance 5) is filtered out


async def test_admin_events_page_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/events")
    assert r.status_code == 200
    assert "No matching kill events." in r.text
