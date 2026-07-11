"""Pure READ helpers for admin weapon-balance dashboards. Aggregates over ALL
`match_player_weapons` rows (server-wide, not per-player). Returns plain
dicts — no ORM objects are leaked to callers.
"""

from sqlalchemy import asc, desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import MatchPlayerWeapon


async def weapon_balance(session: AsyncSession) -> list[dict]:
    """Server-wide per-weapon aggregates + derived balance ratios, ordered by
    total_kills DESC (weapon_id ASC tiebreak). Returns [] for an empty table.
    """
    stmt = (
        select(
            MatchPlayerWeapon.weapon_id,
            func.sum(MatchPlayerWeapon.shots).label("total_shots"),
            func.sum(MatchPlayerWeapon.hits).label("total_hits"),
            func.sum(MatchPlayerWeapon.kills).label("total_kills"),
            func.sum(MatchPlayerWeapon.headshots).label("total_headshots"),
            func.sum(MatchPlayerWeapon.damage).label("total_damage"),
            func.count(func.distinct(MatchPlayerWeapon.player_key)).label("users"),
            func.count(func.distinct(MatchPlayerWeapon.match_id)).label("matches"),
        )
        .group_by(MatchPlayerWeapon.weapon_id)
        .order_by(desc(func.sum(MatchPlayerWeapon.kills)), asc(MatchPlayerWeapon.weapon_id))
    )
    rows = (await session.execute(stmt)).all()

    grand_total_shots = sum(r.total_shots or 0 for r in rows)

    out: list[dict] = []
    for r in rows:
        total_shots = r.total_shots or 0
        total_hits = r.total_hits or 0
        total_kills = r.total_kills or 0
        total_headshots = r.total_headshots or 0
        total_damage = r.total_damage or 0
        matches = r.matches or 0
        out.append({
            "weapon_id": r.weapon_id,
            "total_shots": total_shots,
            "total_hits": total_hits,
            "total_kills": total_kills,
            "total_headshots": total_headshots,
            "total_damage": total_damage,
            "users": r.users,
            "matches": matches,
            "hit_rate": round(total_hits / total_shots, 4) if total_shots > 0 else 0.0,
            "headshot_rate": round(total_headshots / total_hits, 4) if total_hits > 0 else 0.0,
            "damage_per_hit": round(total_damage / total_hits, 2) if total_hits > 0 else 0.0,
            "kills_per_match": round(total_kills / matches, 3) if matches > 0 else 0.0,
            "usage_pct": round(total_shots / grand_total_shots, 4) if grand_total_shots > 0 else 0.0,
        })
    return out
