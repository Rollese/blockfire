import datetime as dt
from sqlalchemy import func, select
from app.models import Event
from app.retention import prune_old_events


async def test_prune_removes_events_older_than_retention(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    now = dt.datetime.now(dt.timezone.utc)
    async with sm() as s:
        s.add(Event(match_id="m1", tick=1, type="kill", payload={},
                    created_at=now - dt.timedelta(days=120)))
        s.add(Event(match_id="m1", tick=2, type="kill", payload={},
                    created_at=now - dt.timedelta(days=10)))
        await s.commit()
    async with sm() as s:
        deleted = await prune_old_events(s, retention_days=90, now=now)
    assert deleted == 1
    async with sm() as s:
        assert (await s.execute(select(func.count()).select_from(Event))).scalar_one() == 1
