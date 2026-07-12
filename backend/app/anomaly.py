import datetime as dt
import statistics

from sqlalchemy import case, desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AnomalyFlag, PlayerProfile

ANOMALY_DETECTOR_VERSION = 1

# Fixed processing order for determinism.
_METRICS = ("kd", "headshot_rate", "hit_rate")

# Ordering rank for review-queue listings (high first).
_SEVERITY_RANK = {"high": 0, "med": 1, "low": 2}


def _severity(value: float, effective: float) -> str:
    # floors are all > 0 so effective is always > 0, but guard anyway.
    ratio = value / effective if effective > 0 else float("inf")
    if ratio >= 1.5:
        return "high"
    if ratio >= 1.2:
        return "med"
    return "low"


def _population(metric: str, profiles: list[PlayerProfile], settings
                ) -> list[tuple[PlayerProfile, float, int]]:
    """Qualifying (profile, value, sample) triples passing metric's min-sample gate."""
    pop: list[tuple[PlayerProfile, float, int]] = []
    for p in profiles:
        if metric == "kd":
            if p.total_deaths >= settings.anomaly_min_deaths \
                    and p.total_kills >= settings.anomaly_min_kills:
                pop.append((p, p.kd_ratio, p.total_deaths))
        elif metric == "headshot_rate":
            if p.total_hits >= settings.anomaly_min_hits and p.total_hits > 0:
                value = round(p.total_headshots / p.total_hits, 4)
                pop.append((p, value, p.total_hits))
        elif metric == "hit_rate":
            if p.total_shots >= settings.anomaly_min_shots:
                pop.append((p, p.overall_hit_rate, p.total_shots))
    return pop


async def detect_anomalies(session: AsyncSession, settings,
                           now: dt.datetime | None = None) -> int:
    """Flag outlier players into the anomaly_flags review queue.

    For each metric (kd, headshot_rate, hit_rate) builds a qualifying population
    (profiles passing a min-sample gate), computes a robust population threshold
    via median + k * 1.4826 * MAD, and flags every qualifying profile whose value
    meets max(absolute_floor, population_threshold). Idempotent per
    (player_key, metric) signature: an open flag is updated in place, a
    reviewer-triaged (confirmed/dismissed) flag is left untouched. Returns the
    number of flags written (inserted + updated-open).
    """
    now = now or dt.datetime.now(dt.timezone.utc)

    profiles = (await session.execute(select(PlayerProfile))).scalars().all()
    profiles = sorted(profiles, key=lambda p: p.player_key)

    written = 0
    for metric in _METRICS:
        population = _population(metric, profiles, settings)
        floor = getattr(settings, f"anomaly_{metric}_floor")

        if len(population) >= settings.anomaly_min_population:
            values = [v for (_, v, _) in population]
            med = statistics.median(values)
            mad = statistics.median([abs(v - med) for v in values])
            pop_thr = med + settings.anomaly_mad_k * 1.4826 * mad
            effective = max(floor, pop_thr)
            pop_median: float | None = round(med, 4)
            pop_mad: float | None = round(mad, 4)
        else:
            effective = floor
            pop_median = None
            pop_mad = None

        for profile, value, sample in population:
            if value < effective:
                continue

            pk = profile.player_key
            severity = _severity(value, effective)
            context = {
                "population_median": pop_median,
                "population_mad": pop_mad,
                "absolute_floor": floor,
                "population_size": len(population),
                "kills": profile.total_kills,
                "deaths": profile.total_deaths,
                "shots": profile.total_shots,
                "hits": profile.total_hits,
                "headshots": profile.total_headshots,
                "matches_played": profile.matches_played,
            }

            existing = (await session.execute(
                select(AnomalyFlag).where(
                    AnomalyFlag.player_key == pk,
                    AnomalyFlag.metric == metric,
                ).order_by(AnomalyFlag.flag_id)
            )).scalars().all()

            if any(f.status in ("confirmed", "dismissed") for f in existing):
                # A reviewer already triaged this signature; leave it alone.
                continue

            open_flags = [f for f in existing if f.status == "open"]
            if open_flags:
                flag = open_flags[0]  # lowest flag_id (ordered above)
                flag.value = value
                flag.threshold = effective
                flag.sample_size = sample
                flag.severity = severity
                flag.context = context
                flag.last_seen_at = now
            else:
                session.add(AnomalyFlag(
                    player_key=pk,
                    metric=metric,
                    value=value,
                    threshold=effective,
                    sample_size=sample,
                    severity=severity,
                    status="open",
                    detector_version=ANOMALY_DETECTOR_VERSION,
                    context=context,
                    created_at=now,
                    last_seen_at=now,
                ))
            written += 1

    await session.commit()
    return written


def _flag_to_dict(flag: AnomalyFlag) -> dict:
    """Serialize an AnomalyFlag row to a plain dict (all columns, no ORM leak).

    Datetimes are returned as-is; the JSON/HTML layers format them.
    """
    return {
        "flag_id": flag.flag_id,
        "player_key": flag.player_key,
        "metric": flag.metric,
        "value": flag.value,
        "threshold": flag.threshold,
        "sample_size": flag.sample_size,
        "severity": flag.severity,
        "status": flag.status,
        "detector_version": flag.detector_version,
        "context": flag.context,
        "created_at": flag.created_at,
        "last_seen_at": flag.last_seen_at,
        "reviewed_at": flag.reviewed_at,
        "reviewed_by": flag.reviewed_by,
        "notes": flag.notes,
    }


async def list_flags(session: AsyncSession, *, status: str | None = None,
                     metric: str | None = None, limit: int = 100) -> list[dict]:
    """List review-queue flags, optionally filtered by exact `status`/`metric`.

    Ordered by severity rank (high -> med -> low), then value DESC, then
    flag_id ASC for full determinism. `limit` is clamped to 1..500 and applied
    as a real DB LIMIT. Returns plain dicts (no ORM objects leaked).
    """
    limit = max(1, min(limit, 500))

    # severity -> rank as a SQL CASE so the LIMIT is a real DB LIMIT.
    sev_rank = case(_SEVERITY_RANK, value=AnomalyFlag.severity, else_=99)

    stmt = select(AnomalyFlag)
    if status is not None:
        stmt = stmt.where(AnomalyFlag.status == status)
    if metric is not None:
        stmt = stmt.where(AnomalyFlag.metric == metric)
    stmt = stmt.order_by(
        sev_rank, desc(AnomalyFlag.value), AnomalyFlag.flag_id
    ).limit(limit)

    rows = (await session.execute(stmt)).scalars().all()
    return [_flag_to_dict(f) for f in rows]


async def flag_summary(session: AsyncSession) -> dict:
    """Aggregate counts for the review-queue overview. Zero-safe: absent
    statuses/metrics report 0. Returns total, by_status, by_metric, open_high.
    """
    by_status = {"open": 0, "confirmed": 0, "dismissed": 0}
    by_metric = {"kd": 0, "headshot_rate": 0, "hit_rate": 0}

    total = (await session.execute(
        select(func.count()).select_from(AnomalyFlag)
    )).scalar_one()

    status_rows = (await session.execute(
        select(AnomalyFlag.status, func.count()).group_by(AnomalyFlag.status)
    )).all()
    for s, n in status_rows:
        if s in by_status:
            by_status[s] = n

    metric_rows = (await session.execute(
        select(AnomalyFlag.metric, func.count()).group_by(AnomalyFlag.metric)
    )).all()
    for m, n in metric_rows:
        if m in by_metric:
            by_metric[m] = n

    open_high = (await session.execute(
        select(func.count()).where(
            AnomalyFlag.status == "open", AnomalyFlag.severity == "high"
        )
    )).scalar_one()

    return {
        "total": total,
        "by_status": by_status,
        "by_metric": by_metric,
        "open_high": open_high,
    }


async def set_flag_status(session: AsyncSession, flag_id: int, status: str, *,
                          reviewed_by: str | None = None,
                          notes: str | None = None,
                          now: dt.datetime | None = None) -> dict | None:
    """Triage a flag: set its review `status` (+ reviewer/notes/timestamp).

    Re-opening (status == "open") clears reviewed_at back to None. Returns the
    updated flag as a dict, or None if `flag_id` is unknown (no commit). Raises
    ValueError for an invalid status.
    """
    if status not in ("open", "confirmed", "dismissed"):
        raise ValueError(f"invalid status: {status}")
    now = now or dt.datetime.now(dt.timezone.utc)

    flag = await session.get(AnomalyFlag, flag_id)
    if flag is None:
        return None

    flag.status = status
    flag.reviewed_at = None if status == "open" else now
    flag.reviewed_by = reviewed_by
    flag.notes = notes

    await session.commit()
    return _flag_to_dict(flag)
