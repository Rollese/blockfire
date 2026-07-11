import datetime as dt

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Event


async def prune_old_events(session: AsyncSession, retention_days: int,
                           now: dt.datetime | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(days=retention_days)
    result = await session.execute(delete(Event).where(Event.created_at < cutoff))
    await session.commit()
    return result.rowcount or 0
