from sqlalchemy import func, select
from app.models import Event, IngestedBatch


async def test_event_batch_inserts_rows(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    body = {"match_id": "m1", "batch_seq": 1, "events": [
        {"tick": 10, "type": "kill", "actor": "name:A", "target": "name:B",
         "weapon_id": "ar", "payload": {"distance_m": 12.5, "hitzone": "head"}},
        {"tick": 11, "type": "damage", "actor": "name:A", "target": "name:B",
         "weapon_id": "ar", "payload": {"damage": 30}}]}
    r = await client.post("/ingest/events", json=body)
    assert r.status_code == 202
    async with sm() as s:
        assert (await s.execute(select(func.count()).select_from(Event))).scalar_one() == 2
        assert (await s.execute(select(func.count()).select_from(IngestedBatch))).scalar_one() == 1


async def test_duplicate_batch_is_ignored(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    body = {"match_id": "m1", "batch_seq": 1, "events": [
        {"tick": 10, "type": "kill", "actor": "name:A", "target": "name:B", "weapon_id": "ar"}]}
    await client.post("/ingest/events", json=body)
    r2 = await client.post("/ingest/events", json=body)
    assert r2.status_code == 202
    async with sm() as s:
        assert (await s.execute(select(func.count()).select_from(Event))).scalar_one() == 1


async def test_events_require_auth(app_and_sessionmaker):
    from httpx import ASGITransport, AsyncClient
    app, _ = app_and_sessionmaker
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        r = await c.post("/ingest/events", json={"match_id": "m", "batch_seq": 0, "events": []})
    assert r.status_code == 401
