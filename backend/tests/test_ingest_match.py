import datetime as dt

from sqlalchemy import select
from app.ingest import ingest_match_report
from app.models import Match, MatchPlayer, MatchPlayerWeapon, Player
from app.schemas import MatchMetaIn, MatchReportIn, PlayerReportIn

REPORT = {
    "report_version": 1,
    "match": {"match_id": "m1", "server_id": "game2-dev-1", "map": "dust",
              "mode": "conquest", "started_at": "2026-07-11T10:00:00Z",
              "ended_at": "2026-07-11T10:20:00Z", "winner": "team_a"},
    "players": [{"name": "Bot_A", "steam_id": None, "team": "team_a", "kills": 12,
                 "deaths": 8, "assists": 3, "downs": 5, "revives": 2, "captures": 2,
                 "neutralizes": 0, "xp_earned": 3400, "longest_kill_m": 214.5,
                 "playtime_s": 1180, "result": "win",
                 "weapons": [{"weapon_id": "ar", "shots": 420, "hits": 150, "kills": 8,
                              "headshots": 3, "damage": 2100, "time_used_s": 800}]}]}


async def test_match_report_persists_all_layers(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    r = await client.post("/ingest/match", json=REPORT)
    assert r.status_code == 202
    async with sm() as s:
        m = (await s.execute(select(Match).where(Match.match_id == "m1"))).scalar_one()
        assert m.winner == "team_a" and m.complete is True and m.duration_s == 1200
        p = (await s.execute(select(Player).where(Player.player_key == "name:Bot_A"))).scalar_one()
        assert p.name == "Bot_A"
        mp = (await s.execute(select(MatchPlayer))).scalar_one()
        assert mp.kills == 12 and mp.longest_kill_m == 214.5
        w = (await s.execute(select(MatchPlayerWeapon))).scalar_one()
        assert w.weapon_id == "ar" and w.hits == 150


async def test_hit_rate_query_is_correct(client, app_and_sessionmaker):
    """The P1 gate's sample balancing query: hit-rate = hits/shots per weapon."""
    _, sm = app_and_sessionmaker
    await client.post("/ingest/match", json=REPORT)
    async with sm() as s:
        w = (await s.execute(select(MatchPlayerWeapon))).scalar_one()
        assert round(w.hits / w.shots, 4) == round(150 / 420, 4)


def _trust_report(match_id="m-trust"):
    return MatchReportIn(
        report_version=1,
        match=MatchMetaIn(match_id=match_id, server_id="s1", map="town",
                          mode="conquest",
                          started_at=dt.datetime(2026, 7, 12, tzinfo=dt.timezone.utc),
                          ended_at=dt.datetime(2026, 7, 12, 0, 20, tzinfo=dt.timezone.utc),
                          winner="team_a"),
        players=[PlayerReportIn(name="BotAlpha", kills=1)],
    )


async def test_ingest_match_records_trusted_true(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        await ingest_match_report(s, _trust_report("m-t"), trusted=True)
    async with sm() as s:
        row = (await s.execute(select(Match).where(Match.match_id == "m-t"))).scalar_one()
        assert row.trusted is True


async def test_ingest_match_defaults_untrusted(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        await ingest_match_report(s, _trust_report("m-u"))  # trusted defaults False
    async with sm() as s:
        row = (await s.execute(select(Match).where(Match.match_id == "m-u"))).scalar_one()
        assert row.trusted is False


import time as _time
from app.signing import compute_signature as _sig

_SKEY_ID = "game2-dev-1"
_SSECRET = "test-secret"


def _sign_headers(body_bytes: bytes):
    ts = int(_time.time())
    return {"X-BF-Key-Id": _SKEY_ID, "X-BF-Timestamp": str(ts),
            "X-BF-Signature": _sig(_SSECRET, _SKEY_ID, str(ts), body_bytes)}


async def test_route_unsigned_match_is_accepted(client):
    import json
    raw = json.dumps(_trust_report("m-route-u").model_dump(mode="json")).encode()
    r = await client.post("/ingest/match", content=raw,
                          headers={"Content-Type": "application/json"})
    assert r.status_code == 202  # unsigned accepted under default settings


async def test_route_forged_match_rejected(client):
    import json
    raw = json.dumps(_trust_report("m-route-f").model_dump(mode="json")).encode()
    h = _sign_headers(raw); h["X-BF-Signature"] = "0" * 64
    h["Content-Type"] = "application/json"
    r = await client.post("/ingest/match", content=raw, headers=h)
    assert r.status_code == 401
