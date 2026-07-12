"""Apply the pure rating update (app.rating) to trusted match reports.

Incremental (`update_ratings`) rates each trusted+complete+unrated match exactly
once, in chronological order, committing per match. `rebuild_ratings` truncates
and replays deterministically for tests/migrations/knob changes.
"""
import datetime as dt

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Match, MatchPlayer, PlayerRating
from app.rating import (
    Outcome, Rating, default_rating, performance_score, rate_two_teams, tier_for,
)


def _outcome_for(winner, team_a_label, team_b_label) -> Outcome:
    if not winner or winner in ("draw", "none"):
        return Outcome.DRAW
    if winner == team_a_label:
        return Outcome.A_WINS
    if winner == team_b_label:
        return Outcome.B_WINS
    return Outcome.DRAW


async def _rate_one(session: AsyncSession, match: Match, settings, now: dt.datetime) -> bool:
    rows = (await session.execute(
        select(MatchPlayer).where(MatchPlayer.match_id == match.match_id))).scalars().all()
    teams: dict[str, list[MatchPlayer]] = {}
    for mp in rows:
        teams.setdefault(mp.team, []).append(mp)
    if len(teams) != 2:
        return False  # BR / malformed — skip (caller leaves rated=False)
    (label_a, mps_a), (label_b, mps_b) = sorted(teams.items())

    keys_a = [mp.player_key for mp in mps_a]
    keys_b = [mp.player_key for mp in mps_b]
    all_keys = keys_a + keys_b
    existing = {
        r.player_key: r
        for r in (await session.execute(
            select(PlayerRating).where(PlayerRating.player_key.in_(all_keys)))).scalars()
    }

    def cur(key) -> Rating:
        r = existing.get(key)
        return Rating(r.mu, r.sigma) if r else default_rating(settings)

    team_a = [cur(k) for k in keys_a]
    team_b = [cur(k) for k in keys_b]
    w_a = [performance_score(mp, settings) for mp in mps_a]
    w_b = [performance_score(mp, settings) for mp in mps_b]
    outcome = _outcome_for(match.winner, label_a, label_b)

    new_a, new_b = rate_two_teams(team_a, team_b, w_a, w_b, outcome, settings)

    for key, rating in list(zip(keys_a, new_a)) + list(zip(keys_b, new_b)):
        ordinal = rating.ordinal(settings.rating_ordinal_z)
        row = existing.get(key)
        if row is None:
            row = PlayerRating(player_key=key, matches_rated=0)
            session.add(row)
        row.mu = rating.mu
        row.sigma = rating.sigma
        row.ordinal = ordinal
        row.tier = tier_for(ordinal, settings)
        row.matches_rated = (row.matches_rated or 0) + 1
        row.last_match_id = match.match_id
        row.updated_at = now
    match.rated = True
    return True


async def update_ratings(session: AsyncSession, settings) -> int:
    now = dt.datetime.now(dt.timezone.utc)
    stmt = select(Match).where(Match.complete.is_(True), Match.rated.is_(False))
    if settings.rating_require_trusted:
        stmt = stmt.where(Match.trusted.is_(True))
    stmt = stmt.order_by(
        Match.ended_at.asc().nulls_last(),
        Match.started_at.asc().nulls_last(),
        Match.match_id.asc())
    matches = (await session.execute(stmt)).scalars().all()
    rated = 0
    for match in matches:
        applied = await _rate_one(session, match, settings, now)
        if applied:
            await session.commit()
            rated += 1
        else:
            # Malformed / not-exactly-two-teams: leave rated=False so a later
            # corrected re-report can still apply. Cheap re-scan at P2 scale.
            await session.rollback()
    return rated


async def rebuild_ratings(session: AsyncSession, settings) -> int:
    await session.execute(update(Match).values(rated=False))
    await session.execute(PlayerRating.__table__.delete())
    await session.commit()
    return await update_ratings(session, settings)
