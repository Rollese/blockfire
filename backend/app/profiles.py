"""Pure READ helpers for player profiles / leaderboard / weapon totals /
recent matches. Every helper returns plain dicts (or lists of dicts) — no ORM
objects are leaked to callers.
"""

from sqlalchemy import asc, desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Match, MatchPlayer, PlayerProfile, PlayerWeaponTotal

# Leaderboard sort key -> profile column. Unknown keys fall back to "kills".
_SORT_COLUMNS = {
    "kills": PlayerProfile.total_kills,
    "kd": PlayerProfile.kd_ratio,
    "hit_rate": PlayerProfile.overall_hit_rate,
    "wins": PlayerProfile.wins,
}


def _row_to_dict(obj) -> dict:
    """Serialize an ORM row to a plain dict keyed by column name."""
    return {c.name: getattr(obj, c.name) for c in obj.__table__.columns}


async def get_profile(session: AsyncSession, player_key: str) -> dict | None:
    """Return the PlayerProfile row for `player_key` as a dict, or None."""
    prof = await session.get(PlayerProfile, player_key)
    return _row_to_dict(prof) if prof is not None else None


async def list_leaderboard(
    session: AsyncSession, limit: int = 50, sort: str = "kills",
) -> list[dict]:
    """Top players from player_profiles ordered by `sort` DESC with a
    deterministic player_key ASC tiebreak. Unknown `sort` -> "kills"."""
    col = _SORT_COLUMNS.get(sort, PlayerProfile.total_kills)
    stmt = (
        select(PlayerProfile)
        .order_by(desc(col), asc(PlayerProfile.player_key))
        .limit(limit)
    )
    rows = (await session.execute(stmt)).scalars().all()
    return [_row_to_dict(r) for r in rows]


async def get_weapon_totals(session: AsyncSession, player_key: str) -> list[dict]:
    """Per-weapon totals for `player_key`, shots DESC (weapon_id ASC tiebreak),
    each including a computed `hit_rate` = round(hits/shots, 4) or 0.0."""
    stmt = (
        select(PlayerWeaponTotal)
        .where(PlayerWeaponTotal.player_key == player_key)
        .order_by(desc(PlayerWeaponTotal.shots), asc(PlayerWeaponTotal.weapon_id))
    )
    out: list[dict] = []
    for w in (await session.execute(stmt)).scalars().all():
        d = _row_to_dict(w)
        d["hit_rate"] = round(w.hits / w.shots, 4) if w.shots > 0 else 0.0
        out.append(d)
    return out


async def get_recent_matches(
    session: AsyncSession, player_key: str, limit: int = 10,
) -> list[dict]:
    """Recent matches for `player_key`, newest first by Match.ended_at DESC
    (NULLs last). Returns match_id, map, mode, result, kills, deaths, ended_at."""
    stmt = (
        select(
            Match.match_id, Match.map, Match.mode, Match.ended_at,
            MatchPlayer.result, MatchPlayer.kills, MatchPlayer.deaths,
        )
        .join(Match, Match.match_id == MatchPlayer.match_id)
        .where(MatchPlayer.player_key == player_key)
        .order_by(desc(Match.ended_at).nullslast())
        .limit(limit)
    )
    rows = (await session.execute(stmt)).all()
    return [
        {
            "match_id": r.match_id,
            "map": r.map,
            "mode": r.mode,
            "result": r.result,
            "kills": r.kills,
            "deaths": r.deaths,
            "ended_at": r.ended_at,
        }
        for r in rows
    ]
