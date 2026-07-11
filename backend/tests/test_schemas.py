import pytest
from pydantic import ValidationError

from app.schemas import EventBatchIn, MatchReportIn


def test_event_batch_parses():
    b = EventBatchIn.model_validate({
        "match_id": "m1", "batch_seq": 7,
        "events": [{"tick": 1234, "type": "kill", "actor": "name:A", "target": "name:B",
                    "weapon_id": "ar", "payload": {"distance_m": 142.3, "hitzone": "head"}}],
    })
    assert b.batch_seq == 7
    assert b.events[0].type == "kill"
    assert b.events[0].payload["distance_m"] == 142.3


def test_event_batch_rejects_negative_seq():
    with pytest.raises(ValidationError):
        EventBatchIn.model_validate({"match_id": "m1", "batch_seq": -1, "events": []})


def test_match_report_parses():
    r = MatchReportIn.model_validate({
        "report_version": 1,
        "match": {"match_id": "m1", "server_id": "game2-dev-1", "map": "dust",
                  "mode": "conquest", "started_at": "2026-07-11T10:00:00Z",
                  "ended_at": "2026-07-11T10:20:00Z", "winner": "team_a"},
        "players": [{"name": "Bot_A", "steam_id": None, "team": "team_a", "kills": 12,
                     "deaths": 8, "assists": 3, "downs": 5, "revives": 2, "captures": 2,
                     "neutralizes": 0, "xp_earned": 3400, "longest_kill_m": 214.5,
                     "playtime_s": 1180, "result": "win",
                     "weapons": [{"weapon_id": "ar", "shots": 420, "hits": 150, "kills": 8,
                                  "headshots": 3, "damage": 2100, "time_used_s": 800}]}],
    })
    assert r.match.match_id == "m1"
    assert r.players[0].weapons[0].weapon_id == "ar"


def test_match_report_rejects_missing_match_id():
    with pytest.raises(ValidationError):
        MatchReportIn.model_validate({"report_version": 1,
            "match": {"server_id": "s", "map": "m", "mode": "conquest"}, "players": []})
