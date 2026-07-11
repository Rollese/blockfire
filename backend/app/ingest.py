import datetime as dt

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Event, IngestedBatch
from app.schemas import EventBatchIn


async def ingest_event_batch(session: AsyncSession, batch: EventBatchIn) -> bool:
    """Insert a batch's events. Returns False (and writes nothing) if this
    (match_id, batch_seq) was already ingested. Idempotent.

    Idempotency assumes a single writer per match: the check-then-insert on
    (match_id, batch_seq) is not DB-atomic, so truly concurrent duplicate POSTs
    could collide on the ingested_batches PK. Acceptable because the game-server
    StatsReporter retries/drains NDJSON sequentially (spec §5)."""
    already = await session.get(IngestedBatch, (batch.match_id, batch.batch_seq))
    if already is not None:
        return False
    now = dt.datetime.now(dt.timezone.utc)
    for ev in batch.events:
        session.add(Event(
            match_id=batch.match_id, tick=ev.tick, type=ev.type,
            actor_key=ev.actor, target_key=ev.target, weapon_id=ev.weapon_id,
            payload=ev.payload, created_at=now,
        ))
    session.add(IngestedBatch(match_id=batch.match_id, batch_seq=batch.batch_seq))
    await session.commit()
    return True
