"""Admin JSON API (`app.admin_api`): route wiring + the admin auth gate.

Two apps share the same sessionmaker/DB from `app_and_sessionmaker`:
  - the default `client` fixture (admin_dev_open=False, no cookie) -> proves
    every /admin/api/* route 403s for a non-admin caller.
  - a second app built here with admin_dev_open=True -> proves the routes
    return correctly-shaped JSON once the caller IS an admin.
A third case signs a real bf_session cookie for an allowlisted steam_id
against an admin_dev_open=False app, proving the cookie path also works.
"""

import datetime as dt

from httpx import ASGITransport, AsyncClient
from itsdangerous import URLSafeSerializer

from app.config import Settings
from app.main import create_app
from app.models import Event, Match, MatchPlayerWeapon, Player

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)
ADMIN_ID = 76561198000000001


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


ADMIN_ROUTES = [
    "/admin/api/weapons",
    "/admin/api/combat",
    "/admin/api/events",
    "/admin/api/outliers",
]


async def test_admin_routes_403_for_non_admin(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    for path in ADMIN_ROUTES:
        r = await client.get(path)
        assert r.status_code == 403, path


async def test_admin_weapons_route(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/weapons")
    assert r.status_code == 200
    body = r.json()
    assert "weapons" in body
    assert len(body["weapons"]) == 2
    ids = {w["weapon_id"] for w in body["weapons"]}
    assert ids == {"ar", "smg"}


async def test_admin_combat_route(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/combat")
    assert r.status_code == 200
    body = r.json()
    assert set(body.keys()) == {"kill_distance", "hitzone", "longest_kills"}
    assert body["kill_distance"]["count"] == 3
    assert body["hitzone"]["total"] == 3
    assert len(body["longest_kills"]) == 3


async def test_admin_events_route_filters_by_query_param(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/events", params={"weapon_id": "ar"})
    assert r.status_code == 200
    body = r.json()
    assert "events" in body
    assert len(body["events"]) == 2
    assert all(e["weapon_id"] == "ar" for e in body["events"])


async def test_admin_events_route_defaults(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/events")
    assert r.status_code == 200
    assert len(r.json()["events"]) == 3


async def test_admin_outliers_route(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/outliers")
    assert r.status_code == 200
    body = r.json()
    assert "weapons" in body
    assert len(body["weapons"]) == 2


async def test_admin_routes_200_with_valid_allowlisted_cookie(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    settings = Settings(ingest_token="test-token", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    app = create_app(settings=settings, sessionmaker=sm)
    cookie = URLSafeSerializer(settings.session_secret, salt="session").dumps(
        {"steam_id": ADMIN_ID})
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        c.cookies.set("bf_session", cookie)
        for path in ADMIN_ROUTES:
            r = await c.get(path)
            assert r.status_code == 200, path
