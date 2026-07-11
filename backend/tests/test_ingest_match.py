from sqlalchemy import select
from app.models import Match, MatchPlayer, MatchPlayerWeapon, Player

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
