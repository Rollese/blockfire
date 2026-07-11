import datetime as dt

from app.admin_stats import hitzone_breakdown, kill_distance_stats, longest_kills, weapon_balance
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
