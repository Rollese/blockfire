import sys
import pathlib

# Make `app` and `worker` importable when running `pytest` from backend/.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.db import Base, init_db, make_engine, make_sessionmaker
from app.main import create_app


@pytest.fixture
async def app_and_sessionmaker():
    engine = make_engine()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db(engine)
    sm = make_sessionmaker(engine)
    settings = Settings(ingest_token="test-token")
    app = create_app(settings=settings, sessionmaker=sm)
    yield app, sm
    await engine.dispose()


@pytest.fixture
async def client(app_and_sessionmaker):
    app, _ = app_and_sessionmaker
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t",
                           headers={"Authorization": "Bearer test-token"}) as c:
        yield c
