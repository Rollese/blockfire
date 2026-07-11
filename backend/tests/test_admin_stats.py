import datetime as dt

from app.admin_stats import (
    admin_summary,
    hitzone_breakdown,
    kill_distance_stats,
    longest_kills,
    query_kill_events,
    weapon_balance,
    weapon_outliers,
)
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


async def _seed(sm):
    """2 matches, 3 players, 4 weapons with hand-checkable numbers.

    weapon_id "ar": P1 in m1+m2, P2 in m1 -> shots=300 hits=110 kills=14
        headshots=4 damage=2400; users=2 (P1,P2); matches=2 (m1,m2)
    weapon_id "smg": P1 in m1, P3 in m2 -> shots=200 hits=70 kills=5
        headshots=3 damage=900; users=2 (P1,P3); matches=2 (m1,m2)
    weapon_id "dmr": P2 in m1 only -> shots=20 hits=18 kills=14
        headshots=10 damage=3000; users=1; matches=1
        -> TIES ar on total_kills(14) to prove the weapon_id ASC tiebreak
           ("ar" sorts before "dmr")
    weapon_id "pistol": P1 in m2 only, all zeros except shots=5 -> proves
        the hits==0 / matches>0 zero-safe branches (headshot_rate,
        damage_per_hit, kills_per_match, hit_rate all present)
    grand_total_shots = 300+200+20+5 = 525
    """
    async with sm() as s:
        s.add(_match("m1"))
        s.add(_match("m2"))
        s.add(_player("name:P1", "P1"))
        s.add(_player("name:P2", "P2"))
        s.add(_player("name:P3", "P3"))
        await s.flush()

        s.add(_mpw("m1", "name:P1", "ar", shots=150, hits=50, kills=6,
                   headshots=2, damage=1200))
        s.add(_mpw("m2", "name:P1", "ar", shots=100, hits=40, kills=5,
                   headshots=1, damage=900))
        s.add(_mpw("m1", "name:P2", "ar", shots=50, hits=20, kills=3,
                   headshots=1, damage=300))

        s.add(_mpw("m1", "name:P1", "smg", shots=170, hits=60, kills=4,
                   headshots=3, damage=800))
        s.add(_mpw("m2", "name:P3", "smg", shots=30, hits=10, kills=1,
                   headshots=0, damage=100))

        s.add(_mpw("m1", "name:P2", "dmr", shots=20, hits=18, kills=14,
                   headshots=10, damage=3000))

        s.add(_mpw("m2", "name:P1", "pistol", shots=5, hits=0, kills=0,
                   headshots=0, damage=0))

        await s.commit()


async def test_weapon_balance_sums_and_distinct_counts(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await weapon_balance(s)

    by_id = {r["weapon_id"]: r for r in rows}

    ar = by_id["ar"]
    assert ar["total_shots"] == 300
    assert ar["total_hits"] == 110
    assert ar["total_kills"] == 14
    assert ar["total_headshots"] == 4
    assert ar["total_damage"] == 2400
    assert ar["users"] == 2
    assert ar["matches"] == 2

    smg = by_id["smg"]
    assert smg["total_shots"] == 200
    assert smg["total_hits"] == 70
    assert smg["total_kills"] == 5
    assert smg["total_headshots"] == 3
    assert smg["total_damage"] == 900
    assert smg["users"] == 2
    assert smg["matches"] == 2

    dmr = by_id["dmr"]
    assert dmr["total_shots"] == 20
    assert dmr["total_hits"] == 18
    assert dmr["total_kills"] == 14
    assert dmr["total_headshots"] == 10
    assert dmr["total_damage"] == 3000
    assert dmr["users"] == 1
    assert dmr["matches"] == 1

    pistol = by_id["pistol"]
    assert pistol["total_shots"] == 5
    assert pistol["total_hits"] == 0
    assert pistol["total_kills"] == 0
    assert pistol["total_headshots"] == 0
    assert pistol["total_damage"] == 0
    assert pistol["users"] == 1
    assert pistol["matches"] == 1


async def test_weapon_balance_derived_ratios(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await weapon_balance(s)
    by_id = {r["weapon_id"]: r for r in rows}
    grand_total_shots = 300 + 200 + 20 + 5

    ar = by_id["ar"]
    assert ar["hit_rate"] == round(110 / 300, 4)
    assert ar["headshot_rate"] == round(4 / 110, 4)
    assert ar["damage_per_hit"] == round(2400 / 110, 2)
    assert ar["kills_per_match"] == round(14 / 2, 3)
    assert ar["usage_pct"] == round(300 / grand_total_shots, 4)

    smg = by_id["smg"]
    assert smg["hit_rate"] == round(70 / 200, 4)
    assert smg["headshot_rate"] == round(3 / 70, 4)
    assert smg["damage_per_hit"] == round(900 / 70, 2)
    assert smg["kills_per_match"] == round(5 / 2, 3)
    assert smg["usage_pct"] == round(200 / grand_total_shots, 4)

    dmr = by_id["dmr"]
    assert dmr["hit_rate"] == round(18 / 20, 4)
    assert dmr["headshot_rate"] == round(10 / 18, 4)
    assert dmr["damage_per_hit"] == round(3000 / 18, 2)
    assert dmr["kills_per_match"] == round(14 / 1, 3)
    assert dmr["usage_pct"] == round(20 / grand_total_shots, 4)

    # pistol: hits==0 and kills==0 exercise every zero-safe branch except
    # hit_rate (shots=5 > 0, hits=0 -> hit_rate legitimately 0.0)
    pistol = by_id["pistol"]
    assert pistol["hit_rate"] == 0.0
    assert pistol["headshot_rate"] == 0.0
    assert pistol["damage_per_hit"] == 0.0
    assert pistol["kills_per_match"] == 0.0
    assert pistol["usage_pct"] == round(5 / grand_total_shots, 4)


async def test_weapon_balance_ordering_kills_desc_weapon_id_tiebreak(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await weapon_balance(s)
    # kills: ar=14, dmr=14 (TIE -> "ar" < "dmr" wins), smg=5, pistol=0
    assert [r["weapon_id"] for r in rows] == ["ar", "dmr", "smg", "pistol"]


async def test_weapon_balance_returns_plain_dicts(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        rows = await weapon_balance(s)
    assert all(isinstance(r, dict) for r in rows)
    expected_keys = {
        "weapon_id", "total_shots", "total_hits", "total_kills",
        "total_headshots", "total_damage", "users", "matches", "hit_rate",
        "headshot_rate", "damage_per_hit", "kills_per_match", "usage_pct",
    }
    assert set(rows[0].keys()) == expected_keys


async def test_weapon_balance_empty_db_returns_empty_list(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        rows = await weapon_balance(s)
    assert rows == []


async def test_admin_summary_counts(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    await _seed_kills(sm)
    async with sm() as s:
        summary = await admin_summary(s)
    assert summary["matches"] == 2       # m1, m2
    assert summary["players"] == 3       # P1, P2, P3
    # sum of every _mpw kills in _seed: ar(6+5+3) + smg(4+1) + dmr(14) + pistol(0)
    assert summary["total_kills"] == 33
    assert summary["kill_events"] == 5   # _seed_kills' 5 "kill" rows (1 "damage" excluded)


async def test_admin_summary_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        summary = await admin_summary(s)
    assert summary == {"matches": 0, "players": 0, "total_kills": 0, "kill_events": 0}


def _kill_event(mid, tick, actor, target, wid, distance, hitzone, created_at=NOW):
    return Event(match_id=mid, tick=tick, type="kill", actor_key=actor, target_key=target,
                 weapon_id=wid,
                 payload={"distance_m": distance, "hitzone": hitzone,
                          "actor_pos": [0, 0, 0], "target_pos": [0, 0, 0]},
                 created_at=created_at)


async def _seed_kills(sm):
    """5 kill events with hand-checkable distances [5, 12, 40, 150, 300] m,
    hitzones head/body/head/body/head -> head=3, body=2, headshot_rate=0.6,
    plus 1 non-kill "damage" event (distance=999) to prove the `type=="kill"`
    filter excludes it from every helper.
    """
    async with sm() as s:
        s.add(_kill_event("m1", 10, "name:P1", "name:P2", "smg", 5.0, "head"))
        s.add(_kill_event("m1", 20, "name:P2", "name:P1", "ar", 12.0, "body"))
        s.add(_kill_event("m1", 30, "name:P1", "name:P3", "ar", 40.0, "head"))
        s.add(_kill_event("m2", 40, "name:P3", "name:P1", "dmr", 150.0, "body"))
        s.add(_kill_event("m2", 50, "name:P1", "name:P2", "dmr", 300.0, "head"))
        s.add(Event(match_id="m1", tick=99, type="damage", actor_key="name:P1",
                     target_key="name:P2", weapon_id="ar",
                     payload={"distance_m": 999.0, "hitzone": "head"}, created_at=NOW))
        await s.commit()


async def test_kill_distance_stats_basic(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kills(sm)
    async with sm() as s:
        stats = await kill_distance_stats(s)

    assert stats["count"] == 5
    assert stats["avg_m"] == round((5 + 12 + 40 + 150 + 300) / 5, 1)
    assert stats["min_m"] == 5.0
    assert stats["max_m"] == 300.0
    # nearest-rank on sorted [5, 12, 40, 150, 300] (n=5):
    # p50 -> rank=ceil(2.5)=3 -> 40.0; p90 -> rank=ceil(4.5)=5 -> 300.0;
    # p99 -> rank=ceil(4.95)=5 -> 300.0
    assert stats["p50_m"] == 40.0
    assert stats["p90_m"] == 300.0
    assert stats["p99_m"] == 300.0

    hist = {b["bucket"]: b["count"] for b in stats["histogram"]}
    assert hist == {
        "0-10": 1, "10-25": 1, "25-50": 1, "50-100": 0, "100-200": 1, "200+": 1,
    }
    assert [b["bucket"] for b in stats["histogram"]] == [
        "0-10", "10-25", "25-50", "50-100", "100-200", "200+",
    ]


async def test_kill_distance_stats_histogram_boundaries(app_and_sessionmaker):
    """Each band boundary must fall in the HIGHER band ([lo,hi) semantics).
    Locks banding against a future </<= regression."""
    _, sm = app_and_sessionmaker
    async with sm() as s:
        for i, d in enumerate((10.0, 25.0, 50.0, 100.0, 200.0)):
            s.add(_kill_event("m1", i, "name:P1", "name:P2", "ar", d, "head"))
        await s.commit()
    async with sm() as s:
        stats = await kill_distance_stats(s)
    hist = {b["bucket"]: b["count"] for b in stats["histogram"]}
    assert hist == {
        "0-10": 0,      # 10.0 excluded (upper-exclusive)
        "10-25": 1,     # 10.0
        "25-50": 1,     # 25.0
        "50-100": 1,    # 50.0
        "100-200": 1,   # 100.0
        "200+": 1,      # 200.0 (>= 200)
    }


async def test_kill_distance_stats_empty_returns_zeroed_dict(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        stats = await kill_distance_stats(s)
    assert stats == {
        "count": 0, "avg_m": 0.0, "min_m": 0.0, "max_m": 0.0,
        "p50_m": 0.0, "p90_m": 0.0, "p99_m": 0.0, "histogram": [],
    }


async def test_hitzone_breakdown_basic(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kills(sm)
    async with sm() as s:
        hz = await hitzone_breakdown(s)
    assert hz == {"total": 5, "head": 3, "body": 2, "headshot_rate": round(3 / 5, 4)}


async def test_hitzone_breakdown_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        hz = await hitzone_breakdown(s)
    assert hz == {"total": 0, "head": 0, "body": 0, "headshot_rate": 0.0}


async def test_longest_kills_ordering_and_shape(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kills(sm)
    async with sm() as s:
        rows = await longest_kills(s, limit=20)

    assert [r["distance_m"] for r in rows] == [300.0, 150.0, 40.0, 12.0, 5.0]
    assert rows[0] == {
        "match_id": "m2", "weapon_id": "dmr", "actor_key": "name:P1",
        "target_key": "name:P2", "distance_m": 300.0, "hitzone": "head", "tick": 50,
    }


async def test_longest_kills_limit_clamp(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kills(sm)
    async with sm() as s:
        top1 = await longest_kills(s, limit=1)
        many = await longest_kills(s, limit=999)
    assert len(top1) == 1
    assert top1[0]["distance_m"] == 300.0
    assert len(many) == 5  # limit clamps to 100, but only 5 kill rows exist


async def test_longest_kills_clamp_upper_and_lower(app_and_sessionmaker):
    """With >100 kill rows, limit=999 must clamp to exactly 100; limit=0 and
    negative must clamp UP to 1 (never error, never return 0/all rows)."""
    _, sm = app_and_sessionmaker
    async with sm() as s:
        for i in range(150):
            s.add(_kill_event("m1", i, "name:P1", "name:P2", "ar", float(i), "head"))
        await s.commit()
    async with sm() as s:
        clamped_high = await longest_kills(s, limit=999)
        clamped_zero = await longest_kills(s, limit=0)
        clamped_neg = await longest_kills(s, limit=-5)
    assert len(clamped_high) == 100
    # highest distance (149.0) leads the DESC ordering
    assert clamped_high[0]["distance_m"] == 149.0
    assert len(clamped_zero) == 1
    assert clamped_zero[0]["distance_m"] == 149.0
    assert len(clamped_neg) == 1


async def test_longest_kills_tiebreak_by_event_id_asc(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(_kill_event("m1", 1, "name:P1", "name:P2", "ar", 77.0, "head"))
        s.add(_kill_event("m1", 2, "name:P2", "name:P1", "ar", 77.0, "body"))
        await s.commit()
    async with sm() as s:
        rows = await longest_kills(s, limit=20)
    # equal distance -> tiebreak by event_id ASC (insertion order): tick=1 first
    assert [r["tick"] for r in rows] == [1, 2]


async def test_longest_kills_empty_db_returns_empty_list(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        rows = await longest_kills(s)
    assert rows == []


async def _seed_kill_explorer(sm):
    """4 kill events with hand-checkable (event_id, tick, weapon, distance,
    hitzone, created_at) tuples, plus 1 non-kill "damage" event to prove the
    `type == "kill"` filter still applies in the explorer.

    event_id=1 tick=100 "ar"  distance=10.0 head created_at=NOW
    event_id=2 tick=200 "ar"  distance=90.0 body created_at=NOW+10s (latest tick)
    event_id=3 tick=50  "smg" distance=45.0 head created_at=NOW+20s (latest created_at)
    event_id=4 tick=300 "dmr" distance=45.0 body created_at=NOW+5s
    -> event_id=3 and event_id=4 TIE on distance_m(45.0) to prove the
       event_id ASC final tiebreak (3 sorts before 4).
    """
    async with sm() as s:
        s.add(_kill_event("m1", 100, "name:P1", "name:P2", "ar", 10.0, "head", created_at=NOW))
        s.add(_kill_event("m1", 200, "name:P2", "name:P1", "ar", 90.0, "body",
                           created_at=NOW + dt.timedelta(seconds=10)))
        s.add(_kill_event("m2", 50, "name:P3", "name:P1", "smg", 45.0, "head",
                           created_at=NOW + dt.timedelta(seconds=20)))
        s.add(_kill_event("m2", 300, "name:P1", "name:P3", "dmr", 45.0, "body",
                           created_at=NOW + dt.timedelta(seconds=5)))
        s.add(Event(match_id="m1", tick=999, type="damage", actor_key="name:P1",
                     target_key="name:P2", weapon_id="ar",
                     payload={"distance_m": 999.0, "hitzone": "head"}, created_at=NOW))
        await s.commit()


async def test_query_kill_events_filter_weapon_id(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, weapon_id="ar")
    assert [r["tick"] for r in rows] == [200, 100]
    assert all(r["weapon_id"] == "ar" for r in rows)


async def test_query_kill_events_filter_min_distance(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, min_distance_m=45.0)
    # distance >= 45: tick200(90), tick50(45,event_id3), tick300(45,event_id4)
    assert [r["tick"] for r in rows] == [200, 50, 300]


async def test_query_kill_events_filter_hitzone(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, hitzone="head")
    assert [r["tick"] for r in rows] == [50, 100]
    assert all(r["hitzone"] == "head" for r in rows)


async def test_query_kill_events_filter_combined(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        only_dmr_body = await query_kill_events(s, weapon_id="dmr", hitzone="body")
        none_match = await query_kill_events(s, weapon_id="smg", hitzone="body")
    assert [r["tick"] for r in only_dmr_body] == [300]
    assert none_match == []


async def test_query_kill_events_order_distance_leading_row(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, order="distance")
    assert rows[0]["tick"] == 200  # distance 90.0 is the max


async def test_query_kill_events_order_recent_leading_row(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, order="recent")
    assert rows[0]["tick"] == 50  # created_at = NOW+20s is the most recent


async def test_query_kill_events_unknown_order_falls_back_to_distance(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, order="bogus")
    assert rows[0]["tick"] == 200  # same leading row as order="distance"


async def test_query_kill_events_tiebreak_by_event_id_asc(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s)
    # distance DESC: 90(tick200), 45/45 tie -> event_id ASC (tick50 before
    # tick300), then 10(tick100)
    assert [r["tick"] for r in rows] == [200, 50, 300, 100]


async def test_query_kill_events_row_shape(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_kill_explorer(sm)
    async with sm() as s:
        rows = await query_kill_events(s, limit=1)
    assert set(rows[0].keys()) == {
        "match_id", "weapon_id", "actor_key", "target_key", "distance_m",
        "hitzone", "tick", "created_at",
    }


async def test_query_kill_events_limit_clamp(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        for i in range(250):
            s.add(_kill_event("m1", i, "name:P1", "name:P2", "ar", float(i), "head"))
        await s.commit()
    async with sm() as s:
        clamped_high = await query_kill_events(s, limit=500)
        clamped_zero = await query_kill_events(s, limit=0)
        clamped_neg = await query_kill_events(s, limit=-10)
    assert len(clamped_high) == 200
    assert clamped_high[0]["distance_m"] == 249.0
    assert len(clamped_zero) == 1
    assert clamped_zero[0]["distance_m"] == 249.0
    assert len(clamped_neg) == 1


async def test_query_kill_events_empty_db_returns_empty_list(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        rows = await query_kill_events(s)
    assert rows == []


async def _seed_outliers(sm):
    """5 weapons, all shot=100 for easy fractions, hand-checkable
    (hit_rate, headshot_rate) pairs:

    e_gun: hits=60 headshots=30 -> hit_rate=0.6 headshot_rate=0.5 (highest
        headshot_rate tier, highest hit_rate within it -> ranks #1)
    a_gun: hits=50 headshots=25 -> hit_rate=0.5 headshot_rate=0.5 (TIES
        b_gun on both fields -> weapon_id ASC tiebreak: "a_gun" < "b_gun")
    b_gun: hits=50 headshots=25 -> hit_rate=0.5 headshot_rate=0.5
    c_gun: hits=100 headshots=10 -> hit_rate=1.0 headshot_rate=0.1 (proves
        headshot_rate, not hit_rate, is the PRIMARY sort key)
    d_gun: hits=0 headshots=0 -> hit_rate=0.0 headshot_rate=0.0 (zero-safe)

    Expected order: e_gun, a_gun, b_gun, c_gun, d_gun.
    """
    async with sm() as s:
        s.add(_match("m1"))
        s.add(_player("name:P1", "P1"))
        await s.flush()

        s.add(_mpw("m1", "name:P1", "e_gun", shots=100, hits=60, kills=5, headshots=30, damage=1000))
        s.add(_mpw("m1", "name:P1", "a_gun", shots=100, hits=50, kills=5, headshots=25, damage=1000))
        s.add(_mpw("m1", "name:P1", "b_gun", shots=100, hits=50, kills=5, headshots=25, damage=1000))
        s.add(_mpw("m1", "name:P1", "c_gun", shots=100, hits=100, kills=5, headshots=10, damage=1000))
        s.add(_mpw("m1", "name:P1", "d_gun", shots=100, hits=0, kills=0, headshots=0, damage=0))
        await s.commit()


async def test_weapon_outliers_ordering_and_shape(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_outliers(sm)
    async with sm() as s:
        rows = await weapon_outliers(s)
    assert [r["weapon_id"] for r in rows] == ["e_gun", "a_gun", "b_gun", "c_gun", "d_gun"]
    assert rows[0]["headshot_rate"] == 0.5
    assert rows[0]["hit_rate"] == 0.6
    assert set(rows[0].keys()) == {
        "weapon_id", "hit_rate", "headshot_rate", "kills_per_match", "users", "total_kills",
    }


async def test_weapon_outliers_empty_db_returns_empty_list(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        rows = await weapon_outliers(s)
    assert rows == []
