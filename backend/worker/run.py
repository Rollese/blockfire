import asyncio

from app.config import get_settings
from app.db import init_db, make_engine, make_sessionmaker
from app.retention import prune_old_events

PRUNE_INTERVAL_S = 3600


async def main() -> None:
    settings = get_settings()
    engine = make_engine(settings.database_url)
    await init_db(engine)
    sm = make_sessionmaker(engine)
    while True:
        try:
            async with sm() as session:
                deleted = await prune_old_events(session, settings.raw_event_retention_days)
            print(f"[worker] pruned {deleted} events older than "
                  f"{settings.raw_event_retention_days}d", flush=True)
        except Exception as exc:
            print(f"[worker] prune failed: {exc!r}", flush=True)
        await asyncio.sleep(PRUNE_INTERVAL_S)


if __name__ == "__main__":
    asyncio.run(main())
