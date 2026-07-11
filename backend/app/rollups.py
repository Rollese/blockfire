import datetime as dt

from sqlalchemy import case, distinct, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    MatchPlayer, MatchPlayerWeapon, Player, PlayerProfile, PlayerWeaponTotal,
)


async def recompute_profiles(session: AsyncSession, now: dt.datetime | None = None) -> int:
    """Rebuild all rollup tables (player_profiles + player_weapon_totals) from
    the source-of-truth match tables. Idempotent upsert: existing rows are
    updated in place, no duplicates created. Returns the number of profiles
    written (one per player appearing in match_players).

    Steam-enrichment fields (avatar_url and display_name once set) are owned by
    a later task and are NOT clobbered on update.
    """
    now = now or dt.datetime.now(dt.timezone.utc)

    # players: player_key -> (steam_id, name)
    players = {
        p.player_key: p
        for p in (await session.execute(select(Player))).scalars().all()
    }

    # --- per-player match aggregates --------------------------------------
    mp_stmt = select(
        MatchPlayer.player_key,
        func.sum(MatchPlayer.kills),
        func.sum(MatchPlayer.deaths),
        func.sum(MatchPlayer.assists),
        func.sum(MatchPlayer.downs),
        func.sum(MatchPlayer.revives),
        func.sum(MatchPlayer.captures),
        func.sum(MatchPlayer.neutralizes),
        func.sum(MatchPlayer.xp_earned),
        func.sum(MatchPlayer.playtime_s),
        func.max(MatchPlayer.longest_kill_m),
        func.count(distinct(MatchPlayer.match_id)),
        func.sum(case((MatchPlayer.result == "win", 1), else_=0)),
        func.sum(case((MatchPlayer.result == "loss", 1), else_=0)),
    ).group_by(MatchPlayer.player_key)

    match_agg: dict[str, dict] = {}
    for row in (await session.execute(mp_stmt)).all():
        (key, kills, deaths, assists, downs, revives, captures, neutralizes,
         xp, playtime, longest, matches, wins, losses) = row
        match_agg[key] = dict(
            kills=kills or 0, deaths=deaths or 0, assists=assists or 0,
            downs=downs or 0, revives=revives or 0, captures=captures or 0,
            neutralizes=neutralizes or 0, xp=xp or 0, playtime=playtime or 0,
            longest=longest or 0.0, matches=matches or 0,
            wins=wins or 0, losses=losses or 0,
        )

    # --- per-(player, weapon) aggregates ----------------------------------
    w_stmt = select(
        MatchPlayerWeapon.player_key,
        MatchPlayerWeapon.weapon_id,
        func.sum(MatchPlayerWeapon.shots),
        func.sum(MatchPlayerWeapon.hits),
        func.sum(MatchPlayerWeapon.kills),
        func.sum(MatchPlayerWeapon.headshots),
        func.sum(MatchPlayerWeapon.damage),
        func.sum(MatchPlayerWeapon.time_used_s),
        func.count(distinct(MatchPlayerWeapon.match_id)),
    ).group_by(MatchPlayerWeapon.player_key, MatchPlayerWeapon.weapon_id)

    weapons_by_player: dict[str, list[dict]] = {}
    for row in (await session.execute(w_stmt)).all():
        (key, wid, shots, hits, kills, headshots, damage, time_used, used) = row
        weapons_by_player.setdefault(key, []).append(dict(
            weapon_id=wid, shots=shots or 0, hits=hits or 0, kills=kills or 0,
            headshots=headshots or 0, damage=damage or 0,
            time_used_s=time_used or 0, matches_used=used or 0,
        ))

    # --- upsert player_weapon_totals --------------------------------------
    for key, wlist in weapons_by_player.items():
        for w in wlist:
            pwt = await session.get(PlayerWeaponTotal, (key, w["weapon_id"]))
            if pwt is None:
                pwt = PlayerWeaponTotal(player_key=key, weapon_id=w["weapon_id"])
                session.add(pwt)
            pwt.shots = w["shots"]
            pwt.hits = w["hits"]
            pwt.kills = w["kills"]
            pwt.headshots = w["headshots"]
            pwt.damage = w["damage"]
            pwt.time_used_s = w["time_used_s"]
            pwt.matches_used = w["matches_used"]

    # --- upsert player_profiles -------------------------------------------
    count = 0
    for key, agg in match_agg.items():
        wlist = weapons_by_player.get(key, [])
        total_shots = sum(w["shots"] for w in wlist)
        total_hits = sum(w["hits"] for w in wlist)
        total_headshots = sum(w["headshots"] for w in wlist)

        # favorite: most shots, tiebreak most kills, then weapon_id ascending.
        # None only when the player has NO weapon rows at all.
        favorite = None
        if wlist:
            favorite = min(
                wlist, key=lambda w: (-w["shots"], -w["kills"], w["weapon_id"])
            )["weapon_id"]

        kd = round(agg["kills"] / max(agg["deaths"], 1), 3)
        hit_rate = round(total_hits / total_shots, 4) if total_shots > 0 else 0.0

        player = players.get(key)
        prof = await session.get(PlayerProfile, key)
        if prof is None:
            prof = PlayerProfile(player_key=key)
            session.add(prof)
            prof.display_name = player.name if player else None
            prof.avatar_url = None
        else:
            # Steam-enrichment task owns display_name (once set) + avatar_url.
            if prof.display_name is None:
                prof.display_name = player.name if player else None

        prof.steam_id = player.steam_id if player else None
        prof.total_kills = agg["kills"]
        prof.total_deaths = agg["deaths"]
        prof.total_assists = agg["assists"]
        prof.total_downs = agg["downs"]
        prof.total_revives = agg["revives"]
        prof.total_captures = agg["captures"]
        prof.total_neutralizes = agg["neutralizes"]
        prof.wins = agg["wins"]
        prof.losses = agg["losses"]
        prof.matches_played = agg["matches"]
        prof.xp_total = agg["xp"]
        prof.kd_ratio = kd
        prof.total_shots = total_shots
        prof.total_hits = total_hits
        prof.total_headshots = total_headshots
        prof.overall_hit_rate = hit_rate
        prof.longest_kill_m = agg["longest"]
        prof.favorite_weapon_id = favorite
        prof.total_playtime_s = agg["playtime"]
        prof.updated_at = now
        count += 1

    await session.commit()
    return count
