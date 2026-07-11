from sqlalchemy import func, select
from app.models import Match, MatchPlayer

from tests.test_ingest_match import REPORT


async def test_match_reingest_does_not_duplicate(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await client.post("/ingest/match", json=REPORT)
    await client.post("/ingest/match", json=REPORT)  # retry / NDJSON replay
    async with sm() as s:
        assert (await s.execute(select(func.count()).select_from(Match))).scalar_one() == 1
        assert (await s.execute(select(func.count()).select_from(MatchPlayer))).scalar_one() == 1
        mp = (await s.execute(select(MatchPlayer))).scalar_one()
        assert mp.kills == 12  # overwritten, not doubled
