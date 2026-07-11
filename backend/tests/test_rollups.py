import datetime as dt

from sqlalchemy import select

from app.models import (
    Match, MatchPlayer, MatchPlayerWeapon, Player, PlayerProfile, PlayerWeaponTotal,
)
from app.rollups import recompute_profiles

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)


def _match(mid: str) -> Match:
    return Match(match_id=mid, server_id="s1", map="dust", mode="conquest",
                 report_version=1, complete=True, ingested_at=NOW)


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
        s.add(_match("m1"))
        s.add(_match("m2"))
        s.add(_player("name:P1", "P1"))
        s.add(_player("name:P2", "P2"))
        s.add(_player("name:P3", "P3", steam_id=770))
        await s.flush()  # satisfy match_players FK before child inserts

        # ---- P1: plays both matches -------------------------------------
        # totals: kills 20, deaths 8 -> kd 2.5; win + loss; matches 2
        s.add(_mp("m1", "name:P1", kills=12, deaths=5, assists=3, downs=4,
                  revives=1, captures=2, neutralizes=1, xp_earned=3000,
                  longest_kill_m=180.0, playtime_s=1000, result="win"))
        s.add(_mp("m2", "name:P1", kills=8, deaths=3, assists=1, downs=2,
                  revives=0, captures=1, neutralizes=0, xp_earned=2000,
                  longest_kill_m=250.0, playtime_s=900, result="loss"))
        # weapons -> total shots 420, hits 150 -> hit_rate 0.3571
        # ar: shots 250 (150+100) most -> favorite; used in 2 matches
        s.add(_mpw("m1", "name:P1", "ar", shots=150, hits=50, kills=6,
                   headshots=2, damage=1200, time_used_s=600))
        s.add(_mpw("m2", "name:P1", "ar", shots=100, hits=40, kills=5,
                   headshots=1, damage=900, time_used_s=400))
        # smg: shots 170, only m1
        s.add(_mpw("m1", "name:P1", "smg", shots=170, hits=60, kills=4,
                   headshots=3, damage=800, time_used_s=300))

        # ---- P2: one match, tie on shots -> kills tiebreak --------------
        s.add(_mp("m1", "name:P2", kills=5, deaths=10, result="loss"))
        s.add(_mpw("m1", "name:P2", "wpn_a", shots=100, hits=30, kills=2))
        s.add(_mpw("m1", "name:P2", "wpn_b", shots=100, hits=40, kills=9))

        # ---- P3: one match, NO weapon rows -----------------------------
        s.add(_mp("m2", "name:P3", kills=1, deaths=1, result="win"))
        await s.commit()


async def test_recompute_aggregates_and_derives(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        n = await recompute_profiles(s, now=NOW)
    assert n == 3

    async with sm() as s:
        p1 = (await s.execute(
            select(PlayerProfile).where(PlayerProfile.player_key == "name:P1")
        )).scalar_one()
        assert p1.total_kills == 20
        assert p1.total_deaths == 8
        assert p1.kd_ratio == 2.5
        assert p1.total_assists == 4
        assert p1.total_downs == 6
        assert p1.total_revives == 1
        assert p1.total_captures == 3
        assert p1.total_neutralizes == 1
        assert p1.xp_total == 5000
        assert p1.total_playtime_s == 1900
        assert p1.longest_kill_m == 250.0
        assert p1.wins == 1
        assert p1.losses == 1
        assert p1.matches_played == 2
        assert p1.total_shots == 420
        assert p1.total_hits == 150
        assert p1.total_headshots == 6
        assert p1.overall_hit_rate == 0.3571
        assert p1.favorite_weapon_id == "ar"
        assert p1.display_name == "P1"
        assert p1.updated_at == NOW

        # per-weapon totals for P1
        ar = (await s.execute(select(PlayerWeaponTotal).where(
            PlayerWeaponTotal.player_key == "name:P1",
            PlayerWeaponTotal.weapon_id == "ar"))).scalar_one()
        assert ar.shots == 250 and ar.hits == 90 and ar.kills == 11
        assert ar.headshots == 3 and ar.matches_used == 2
        smg = (await s.execute(select(PlayerWeaponTotal).where(
            PlayerWeaponTotal.player_key == "name:P1",
            PlayerWeaponTotal.weapon_id == "smg"))).scalar_one()
        assert smg.shots == 170 and smg.matches_used == 1

        # P2: tie on shots (100/100) -> kills tiebreak picks wpn_b
        p2 = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P2"))).scalar_one()
        assert p2.favorite_weapon_id == "wpn_b"
        assert p2.total_shots == 200
        assert p2.kd_ratio == 0.5

        # P3: no weapon rows -> favorite None, hit_rate 0.0, steam_id copied
        p3 = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P3"))).scalar_one()
        assert p3.favorite_weapon_id is None
        assert p3.total_shots == 0
        assert p3.overall_hit_rate == 0.0
        assert p3.steam_id == 770
        wcount = (await s.execute(select(PlayerWeaponTotal).where(
            PlayerWeaponTotal.player_key == "name:P3"))).all()
        assert wcount == []


async def test_recompute_is_idempotent(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        await recompute_profiles(s, now=NOW)
    async with sm() as s:
        n2 = await recompute_profiles(s, now=NOW)
    assert n2 == 3
    async with sm() as s:
        profiles = (await s.execute(select(PlayerProfile))).scalars().all()
        assert len(profiles) == 3
        weps = (await s.execute(select(PlayerWeaponTotal))).scalars().all()
        # P1: ar,smg ; P2: wpn_a,wpn_b ; P3: none  -> 4 rows, no dups
        assert len(weps) == 4
        p1 = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P1"))).scalar_one()
        assert p1.total_kills == 20 and p1.total_shots == 420


async def test_steam_enrichment_fields_survive_recompute(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed(sm)
    async with sm() as s:
        await recompute_profiles(s, now=NOW)
    # Simulate a later Steam-enrichment task setting avatar + display_name.
    async with sm() as s:
        p1 = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P1"))).scalar_one()
        p1.avatar_url = "https://avatars.example/p1.jpg"
        p1.display_name = "SteamNameP1"
        await s.commit()
    later = NOW + dt.timedelta(hours=1)
    async with sm() as s:
        await recompute_profiles(s, now=later)
    async with sm() as s:
        p1 = (await s.execute(select(PlayerProfile).where(
            PlayerProfile.player_key == "name:P1"))).scalar_one()
        assert p1.avatar_url == "https://avatars.example/p1.jpg"
        assert p1.display_name == "SteamNameP1"
        assert p1.updated_at == later
        # stats still refreshed
        assert p1.total_kills == 20
