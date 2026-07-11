"""Pure READ helpers for admin weapon-balance dashboards. Aggregates over ALL
`match_player_weapons` rows (server-wide, not per-player). Returns plain
dicts — no ORM objects are leaked to callers.
"""

import math

from sqlalchemy import Float, asc, desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Event, Match, MatchPlayerWeapon, Player


async def admin_summary(session: AsyncSession) -> dict:
    """Headline totals for the admin dashboard overview: match count,
    distinct player count (all rows in `players`), total kills summed across
    `match_player_weapons`, and total `type == "kill"` event count. Zero-safe
    on an empty DB (every field is 0).
    """
    matches = (await session.execute(select(func.count()).select_from(Match))).scalar_one()
    players = (await session.execute(select(func.count()).select_from(Player))).scalar_one()
    total_kills = (await session.execute(
        select(func.coalesce(func.sum(MatchPlayerWeapon.kills), 0))
    )).scalar_one()
    kill_events = (await session.execute(
        select(func.count()).where(Event.type == "kill")
    )).scalar_one()
    return {
        "matches": matches,
        "players": players,
        "total_kills": total_kills,
        "kill_events": kill_events,
    }


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


_HISTOGRAM_BANDS = [
    ("0-10", 0.0, 10.0),
    ("10-25", 10.0, 25.0),
    ("25-50", 25.0, 50.0),
    ("50-100", 50.0, 100.0),
    ("100-200", 100.0, 200.0),
    ("200+", 200.0, None),
]


async def kill_distance_stats(session: AsyncSession) -> dict:
    """Distance-to-kill statistics over all `type == "kill"` events' `payload
    -> distance_m` (metres). Only rows carrying a numeric `distance_m` are
    included (defensive against missing/null payload keys).

    Percentiles use the **nearest-rank method** on the ascending-sorted
    sample: for percentile `p` and `N` samples, `rank = ceil(p/100 * N)`
    (clamped to `[1, N]`), and the result is `sorted_distances[rank - 1]`.
    E.g. N=5, p50 -> rank=ceil(2.5)=3 -> the 3rd-smallest value.

    Histogram buckets are fixed metre bands; a distance falls in band
    `[lo, hi)`, and the terminal "200+" bucket catches `>= 200`.

    Returns the zeroed/empty shape below when there are no kill events with
    a distance_m.
    """
    stmt = select(Event.payload["distance_m"].astext.cast(Float)).where(Event.type == "kill")
    raw = (await session.execute(stmt)).scalars().all()
    distances = sorted(d for d in raw if d is not None)

    if not distances:
        return {
            "count": 0, "avg_m": 0.0, "min_m": 0.0, "max_m": 0.0,
            "p50_m": 0.0, "p90_m": 0.0, "p99_m": 0.0, "histogram": [],
        }

    n = len(distances)

    def _percentile(p: float) -> float:
        rank = max(1, min(n, math.ceil(p / 100 * n)))
        return distances[rank - 1]

    histogram = []
    for label, lo, hi in _HISTOGRAM_BANDS:
        if hi is None:
            count = sum(1 for d in distances if d >= lo)
        else:
            count = sum(1 for d in distances if lo <= d < hi)
        histogram.append({"bucket": label, "count": count})

    return {
        "count": n,
        "avg_m": round(sum(distances) / n, 1),
        "min_m": round(distances[0], 1),
        "max_m": round(distances[-1], 1),
        "p50_m": round(_percentile(50), 1),
        "p90_m": round(_percentile(90), 1),
        "p99_m": round(_percentile(99), 1),
        "histogram": histogram,
    }


async def hitzone_breakdown(session: AsyncSession) -> dict:
    """Headshot-vs-bodyshot breakdown over all `type == "kill"` events'
    `payload -> hitzone`. Rows with a hitzone other than "head"/"body" (or
    missing) count toward `total` but not `head`/`body`.
    """
    total = (await session.execute(
        select(func.count()).where(Event.type == "kill")
    )).scalar_one()
    head = (await session.execute(
        select(func.count()).where(Event.type == "kill", Event.payload["hitzone"].astext == "head")
    )).scalar_one()
    body = (await session.execute(
        select(func.count()).where(Event.type == "kill", Event.payload["hitzone"].astext == "body")
    )).scalar_one()

    return {
        "total": total,
        "head": head,
        "body": body,
        "headshot_rate": round(head / total, 4) if total > 0 else 0.0,
    }


async def query_kill_events(
    session: AsyncSession,
    *,
    weapon_id: str | None = None,
    min_distance_m: float | None = None,
    hitzone: str | None = None,
    order: str = "distance",
    limit: int = 50,
) -> list[dict]:
    """Parameterized edge-case explorer over `type == "kill"` events, for
    hunting balance/forensic outliers (READ-only; no flagging/queue here).

    Filters (all optional, AND-combined): exact `weapon_id`, `distance_m >=
    min_distance_m`, exact `hitzone`. `order`: "distance" -> payload
    distance_m DESC; "recent" -> created_at DESC then tick DESC; any other
    value (including unrecognised strings) falls back to "distance". Every
    ordering carries a final `event_id` ASC tiebreak for determinism.
    `limit` is clamped to `[1, 200]`.
    """
    limit = max(1, min(200, limit))
    distance = Event.payload["distance_m"].astext.cast(Float)

    stmt = select(Event).where(Event.type == "kill")
    if weapon_id is not None:
        stmt = stmt.where(Event.weapon_id == weapon_id)
    if min_distance_m is not None:
        stmt = stmt.where(distance >= min_distance_m)
    if hitzone is not None:
        stmt = stmt.where(Event.payload["hitzone"].astext == hitzone)

    if order == "recent":
        stmt = stmt.order_by(desc(Event.created_at), desc(Event.tick), asc(Event.event_id))
    else:
        stmt = stmt.order_by(desc(distance), asc(Event.event_id))

    stmt = stmt.limit(limit)
    rows = (await session.execute(stmt)).scalars().all()
    return [
        {
            "match_id": r.match_id,
            "weapon_id": r.weapon_id,
            "actor_key": r.actor_key,
            "target_key": r.target_key,
            "distance_m": r.payload.get("distance_m"),
            "hitzone": r.payload.get("hitzone"),
            "tick": r.tick,
            "created_at": r.created_at,
        }
        for r in rows
    ]


async def weapon_outliers(session: AsyncSession) -> list[dict]:
    """Thin projection over `weapon_balance` (no separate DB query) that
    surfaces the classic cheat/edge signal: weapons ranked by headshot_rate
    DESC, then hit_rate DESC, with a weapon_id ASC final tiebreak. Returns
    [] when there are no weapons.
    """
    balance = await weapon_balance(session)
    projected = [
        {
            "weapon_id": r["weapon_id"],
            "hit_rate": r["hit_rate"],
            "headshot_rate": r["headshot_rate"],
            "kills_per_match": r["kills_per_match"],
            "users": r["users"],
            "total_kills": r["total_kills"],
        }
        for r in balance
    ]
    projected.sort(key=lambda r: (-r["headshot_rate"], -r["hit_rate"], r["weapon_id"]))
    return projected


async def longest_kills(session: AsyncSession, limit: int = 20) -> list[dict]:
    """Top `limit` `type == "kill"` events by `payload -> distance_m` DESC,
    tiebroken by `event_id` ASC (insertion order) for determinism. `limit`
    is clamped to `[1, 100]`.
    """
    limit = max(1, min(100, limit))
    distance = Event.payload["distance_m"].astext.cast(Float)
    stmt = (
        select(Event)
        .where(Event.type == "kill")
        .order_by(desc(distance), asc(Event.event_id))
        .limit(limit)
    )
    rows = (await session.execute(stmt)).scalars().all()
    return [
        {
            "match_id": r.match_id,
            "weapon_id": r.weapon_id,
            "actor_key": r.actor_key,
            "target_key": r.target_key,
            "distance_m": r.payload.get("distance_m"),
            "hitzone": r.payload.get("hitzone"),
            "tick": r.tick,
        }
        for r in rows
    ]
