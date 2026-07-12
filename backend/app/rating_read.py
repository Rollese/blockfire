"""Read-only layer over `PlayerRating` for the admin ratings surface (Task 6,
spec §6). No writes -- rating computation/application lives in
`app.rating_apply` (Task 5, if present) or the M9 rating worker.
"""

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import PlayerRating


async def leaderboard(session: AsyncSession, limit: int = 100, offset: int = 0
                      ) -> list[PlayerRating]:
    """Top players by ordinal (conservative skill estimate) descending,
    ties broken by player_key ascending for deterministic paging."""
    stmt = (
        select(PlayerRating)
        .order_by(PlayerRating.ordinal.desc(), PlayerRating.player_key.asc())
        .limit(limit)
        .offset(offset)
    )
    return (await session.execute(stmt)).scalars().all()


async def rating_summary(session: AsyncSession) -> dict:
    """Population-level counters: total rated players, total rating
    applications (sum of matches_rated across players), and a per-tier
    distribution."""
    total = (
        await session.execute(select(func.count()).select_from(PlayerRating))
    ).scalar_one()
    tier_rows = (
        await session.execute(
            select(PlayerRating.tier, func.count()).group_by(PlayerRating.tier)
        )
    ).all()
    rated_matches = (
        await session.execute(
            select(func.coalesce(func.sum(PlayerRating.matches_rated), 0))
        )
    ).scalar_one()
    return {
        "total_rated_players": int(total),
        "total_rating_applications": int(rated_matches),
        "tiers": {tier: int(n) for tier, n in tier_rows},
    }
