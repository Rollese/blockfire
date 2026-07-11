import datetime as dt

from app.admin_stats import weapon_balance
from app.models import Match, MatchPlayerWeapon, Player

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
