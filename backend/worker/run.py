import asyncio

from app.config import get_settings
from app.db import init_db, make_engine, make_sessionmaker
from app.retention import prune_old_events
from app.rollups import recompute_profiles
from app.steam_api import enrich_profiles

# Prune is idempotent + cheap, so we fold it into the shorter rollup cadence
# rather than gating it on a separate longer interval.
ROLLUP_INTERVAL_S = 30


async def run_cycle(sm, settings) -> dict:
    """Run one maintenance cycle: prune -> rollup -> enrich.

    Each step opens its own fresh session and is independently try/except
    guarded, so a failure (and rolled-back session) in one step can neither
    propagate nor poison the others. Returns per-step counts, using 0 for any
    step that raised.
    """
    result = {"pruned": 0, "profiles": 0, "enriched": 0}

    # 1. prune old raw events (idempotent + cheap -> safe every cycle)
    try:
        async with sm() as session:
            deleted = await prune_old_events(session, settings.raw_event_retention_days)
        result["pruned"] = deleted
        print(f"[worker] pruned {deleted} events older than "
              f"{settings.raw_event_retention_days}d", flush=True)
    except Exception as exc:
        print(f"[worker] prune failed: {exc!r}", flush=True)

    # 2. recompute rollup profiles from source-of-truth match tables
    try:
        async with sm() as session:
            profiles = await recompute_profiles(session)
        result["profiles"] = profiles
        print(f"[worker] recomputed {profiles} profiles", flush=True)
    except Exception as exc:
        print(f"[worker] rollup failed: {exc!r}", flush=True)

    # 3. optional Steam enrichment (no-op without an API key)
    try:
        async with sm() as session:
            enriched = await enrich_profiles(session, settings.steam_web_api_key)
        result["enriched"] = enriched
        if enriched:
            print(f"[worker] enriched {enriched} profiles", flush=True)
    except Exception as exc:
        print(f"[worker] enrich failed: {exc!r}", flush=True)

    return result


async def main() -> None:
    settings = get_settings()
    engine = make_engine(settings.database_url)
    await init_db(engine)
    sm = make_sessionmaker(engine)
    while True:
        await run_cycle(sm, settings)
        await asyncio.sleep(ROLLUP_INTERVAL_S)


if __name__ == "__main__":
    asyncio.run(main())
