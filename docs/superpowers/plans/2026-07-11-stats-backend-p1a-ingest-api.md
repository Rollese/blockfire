# Stats Backend P1-A — Ingest API + Postgres Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Python ingest backend — a FastAPI service that accepts match/event POSTs from game servers, validates them, and stores them idempotently in PostgreSQL — runnable via docker-compose and testable standalone with synthetic POSTs.

**Architecture:** Stateless FastAPI `api` process behind bearer-token auth writes to a PostgreSQL `db`; a `worker` prunes raw events past retention. Schema is created from SQLAlchemy models via an idempotent `init_db()` (Alembic deferred until the first schema change in P2). Everything keys on a `player_key` string (`steam:<id>` when a SteamID exists, else `name:<name>` fallback for bots/LAN).

**Tech Stack:** Python 3.11+, FastAPI, Uvicorn, SQLAlchemy 2.0 (async + asyncpg), Pydantic v2, pytest + pytest-asyncio + httpx, Docker Compose, PostgreSQL 16.

**Companion spec:** `docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md`. This plan is **P1-A**; the game-server `StatsReporter` that calls this API is **P1-B** (`2026-07-11-stats-backend-p1b-statsreporter.md`). This service defines the contract P1-B targets, so build it first.

---

## File structure

```
backend/
  pyproject.toml            deps + tooling
  .env.example              DATABASE_URL, INGEST_TOKEN, RAW_EVENT_RETENTION_DAYS
  Dockerfile                api + worker image
  docker-compose.yml        api, db, worker
  README.md                 how to run/test (scoping note lives in root AGENTS.md)
  app/
    __init__.py
    config.py               Settings (pydantic-settings)
    db.py                   async engine/session + init_db()
    models.py               SQLAlchemy models (players, matches, match_players,
                            match_player_weapons, events, ingested_batches)
    identity.py             player_key(steam_id, name) -> str
    schemas.py              Pydantic ingest models (EventBatchIn, MatchReportIn, ...)
    auth.py                 require_ingest_token dependency
    ingest.py               ingest_event_batch(), ingest_match_report()
    retention.py            prune_old_events()
    main.py                 FastAPI app + routes
  worker/
    __init__.py
    run.py                  loop: call prune_old_events() on an interval
  tests/
    conftest.py             async engine + client fixtures
    test_config.py
    test_models.py
    test_identity.py
    test_schemas.py
    test_auth.py
    test_health.py
    test_ingest_events.py
    test_ingest_match.py
    test_idempotency.py
    test_retention.py
```

**Running the test DB (used by integration tasks 2, 7–10):**
```bash
cd backend
docker compose up -d db
export DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@localhost:5432/blockfire_stats'
export INGEST_TOKEN='test-token'
```
Pure-logic tasks (3, 4, 5, 6) need no DB.

---

### Task 1: Project scaffold + config

**Files:**
- Create: `backend/pyproject.toml`, `backend/.env.example`, `backend/app/__init__.py`, `backend/worker/__init__.py`, `backend/app/config.py`
- Test: `backend/tests/test_config.py`, `backend/tests/conftest.py`

- [ ] **Step 1: Write `backend/pyproject.toml`**

```toml
[project]
name = "blockfire-stats"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.110",
    "uvicorn[standard]>=0.29",
    "sqlalchemy[asyncio]>=2.0",
    "asyncpg>=0.29",
    "pydantic>=2.6",
    "pydantic-settings>=2.2",
]

[project.optional-dependencies]
dev = ["pytest>=8", "pytest-asyncio>=0.23", "httpx>=0.27"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]

[tool.setuptools.packages.find]
include = ["app*", "worker*"]
```

- [ ] **Step 2: Write `backend/.env.example`**

```bash
# Copy to .env for local runs; docker-compose reads these.
DATABASE_URL=postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats
INGEST_TOKEN=change-me-in-prod
RAW_EVENT_RETENTION_DAYS=90
```

- [ ] **Step 3: Write the failing test** `backend/tests/test_config.py`

```python
import os
from app.config import Settings


def test_settings_read_from_env(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@h:5432/d")
    monkeypatch.setenv("INGEST_TOKEN", "secret")
    monkeypatch.setenv("RAW_EVENT_RETENTION_DAYS", "30")
    s = Settings()
    assert s.database_url == "postgresql+asyncpg://u:p@h:5432/d"
    assert s.ingest_token == "secret"
    assert s.raw_event_retention_days == 30


def test_retention_defaults_to_90(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@h:5432/d")
    monkeypatch.setenv("INGEST_TOKEN", "secret")
    monkeypatch.delenv("RAW_EVENT_RETENTION_DAYS", raising=False)
    assert Settings().raw_event_retention_days == 90
```

- [ ] **Step 4: Empty `__init__.py` files and minimal conftest**

Create empty `backend/app/__init__.py` and `backend/worker/__init__.py`. Create `backend/tests/conftest.py`:

```python
import os
import sys
import pathlib

# Make `app` and `worker` importable when running `pytest` from backend/.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
```

- [ ] **Step 5: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_config.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.config'`

- [ ] **Step 6: Write `backend/app/config.py`**

```python
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    ingest_token: str
    raw_event_retention_days: int = 90


def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_config.py -v`
Expected: PASS (2 passed)

- [ ] **Step 8: Commit**

```bash
git add backend/pyproject.toml backend/.env.example backend/app backend/worker backend/tests
git commit -m "feat(stats): backend scaffold + settings"
```

---

### Task 2: Database engine, models, and init_db

**Files:**
- Create: `backend/app/db.py`, `backend/app/models.py`
- Test: `backend/tests/test_models.py`

- [ ] **Step 1: Write `backend/app/db.py`**

```python
from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import (
    AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from app.config import get_settings


class Base(DeclarativeBase):
    pass


def make_engine(url: str | None = None) -> AsyncEngine:
    return create_async_engine(url or get_settings().database_url, future=True)


def make_sessionmaker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False)


async def init_db(engine: AsyncEngine) -> None:
    """Create all tables if absent. Idempotent; safe to call on every startup.
    Alembic migrations are introduced at the first schema change (P2)."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
```

- [ ] **Step 2: Write the failing test** `backend/tests/test_models.py`

```python
import datetime as dt
import pytest
from sqlalchemy import select

from app.db import Base, init_db, make_engine, make_sessionmaker
from app.models import Player


@pytest.fixture
async def sessionmaker_fixture():
    engine = make_engine()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await init_db(engine)
    yield make_sessionmaker(engine)
    await engine.dispose()


async def test_player_roundtrips(sessionmaker_fixture):
    now = dt.datetime(2026, 7, 11, tzinfo=dt.timezone.utc)
    async with sessionmaker_fixture() as s:
        s.add(Player(player_key="name:Bot_A", steam_id=None, name="Bot_A",
                     first_seen=now, last_seen=now))
        await s.commit()
    async with sessionmaker_fixture() as s:
        got = (await s.execute(select(Player).where(Player.player_key == "name:Bot_A"))).scalar_one()
        assert got.name == "Bot_A"
        assert got.steam_id is None
```

- [ ] **Step 3: Run test to verify it fails**

Run (DB running per "Running the test DB" above): `cd backend && python -m pytest tests/test_models.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.models'`

- [ ] **Step 4: Write `backend/app/models.py`**

```python
import datetime as dt

from sqlalchemy import BigInteger, Boolean, Float, ForeignKey, Integer, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Player(Base):
    __tablename__ = "players"
    player_key: Mapped[str] = mapped_column(String, primary_key=True)
    steam_id: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    name: Mapped[str | None] = mapped_column(String, nullable=True)
    first_seen: Mapped[dt.datetime] = mapped_column()
    last_seen: Mapped[dt.datetime] = mapped_column()


class Match(Base):
    __tablename__ = "matches"
    match_id: Mapped[str] = mapped_column(String, primary_key=True)
    server_id: Mapped[str] = mapped_column(String)
    map: Mapped[str] = mapped_column(String)
    mode: Mapped[str] = mapped_column(String)
    started_at: Mapped[dt.datetime | None] = mapped_column(nullable=True)
    ended_at: Mapped[dt.datetime | None] = mapped_column(nullable=True)
    duration_s: Mapped[int | None] = mapped_column(Integer, nullable=True)
    winner: Mapped[str | None] = mapped_column(String, nullable=True)
    report_version: Mapped[int] = mapped_column(Integer, default=1)
    complete: Mapped[bool] = mapped_column(Boolean, default=False)
    ingested_at: Mapped[dt.datetime] = mapped_column()


class MatchPlayer(Base):
    __tablename__ = "match_players"
    match_id: Mapped[str] = mapped_column(ForeignKey("matches.match_id"), primary_key=True)
    player_key: Mapped[str] = mapped_column(ForeignKey("players.player_key"), primary_key=True)
    team: Mapped[str] = mapped_column(String, default="")
    kills: Mapped[int] = mapped_column(Integer, default=0)
    deaths: Mapped[int] = mapped_column(Integer, default=0)
    assists: Mapped[int] = mapped_column(Integer, default=0)
    downs: Mapped[int] = mapped_column(Integer, default=0)
    revives: Mapped[int] = mapped_column(Integer, default=0)
    captures: Mapped[int] = mapped_column(Integer, default=0)
    neutralizes: Mapped[int] = mapped_column(Integer, default=0)
    xp_earned: Mapped[int] = mapped_column(Integer, default=0)
    longest_kill_m: Mapped[float] = mapped_column(Float, default=0.0)
    playtime_s: Mapped[int] = mapped_column(Integer, default=0)
    result: Mapped[str] = mapped_column(String, default="")


class MatchPlayerWeapon(Base):
    __tablename__ = "match_player_weapons"
    match_id: Mapped[str] = mapped_column(ForeignKey("matches.match_id"), primary_key=True)
    player_key: Mapped[str] = mapped_column(ForeignKey("players.player_key"), primary_key=True)
    weapon_id: Mapped[str] = mapped_column(String, primary_key=True)
    shots: Mapped[int] = mapped_column(Integer, default=0)
    hits: Mapped[int] = mapped_column(Integer, default=0)
    kills: Mapped[int] = mapped_column(Integer, default=0)
    headshots: Mapped[int] = mapped_column(Integer, default=0)
    damage: Mapped[int] = mapped_column(Integer, default=0)
    time_used_s: Mapped[int] = mapped_column(Integer, default=0)


class Event(Base):
    __tablename__ = "events"
    event_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    match_id: Mapped[str] = mapped_column(String, index=True)
    tick: Mapped[int] = mapped_column(Integer)
    type: Mapped[str] = mapped_column(String, index=True)
    actor_key: Mapped[str | None] = mapped_column(String, nullable=True)
    target_key: Mapped[str | None] = mapped_column(String, nullable=True)
    weapon_id: Mapped[str | None] = mapped_column(String, nullable=True)
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[dt.datetime] = mapped_column(index=True)


class IngestedBatch(Base):
    __tablename__ = "ingested_batches"
    match_id: Mapped[str] = mapped_column(String, primary_key=True)
    batch_seq: Mapped[int] = mapped_column(Integer, primary_key=True)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_models.py -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add backend/app/db.py backend/app/models.py backend/tests/test_models.py
git commit -m "feat(stats): db engine + SQLAlchemy models + init_db"
```

---

### Task 3: Player identity (`player_key`)

**Files:**
- Create: `backend/app/identity.py`
- Test: `backend/tests/test_identity.py`

- [ ] **Step 1: Write the failing test** `backend/tests/test_identity.py`

```python
from app.identity import player_key


def test_steam_id_takes_precedence():
    assert player_key(steam_id=76561198000000000, name="Whatever") == "steam:76561198000000000"


def test_falls_back_to_name_when_no_steam_id():
    assert player_key(steam_id=None, name="Bot_A") == "name:Bot_A"


def test_zero_steam_id_is_treated_as_absent():
    assert player_key(steam_id=0, name="Bot_A") == "name:Bot_A"


def test_missing_both_raises():
    import pytest
    with pytest.raises(ValueError):
        player_key(steam_id=None, name="")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_identity.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.identity'`

- [ ] **Step 3: Write `backend/app/identity.py`**

```python
def player_key(steam_id: int | None, name: str | None) -> str:
    """Stable identity key. SteamID when present (non-zero), else name-based
    fallback for bots/LAN players that have no SteamID yet."""
    if steam_id:
        return f"steam:{steam_id}"
    if name:
        return f"name:{name}"
    raise ValueError("player must have a steam_id or a name")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_identity.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add backend/app/identity.py backend/tests/test_identity.py
git commit -m "feat(stats): player_key identity derivation"
```

---

### Task 4: Pydantic ingest schemas

**Files:**
- Create: `backend/app/schemas.py`
- Test: `backend/tests/test_schemas.py`

- [ ] **Step 1: Write the failing test** `backend/tests/test_schemas.py`

```python
import pytest
from pydantic import ValidationError

from app.schemas import EventBatchIn, MatchReportIn


def test_event_batch_parses():
    b = EventBatchIn.model_validate({
        "match_id": "m1", "batch_seq": 7,
        "events": [{"tick": 1234, "type": "kill", "actor": "name:A", "target": "name:B",
                    "weapon_id": "ar", "payload": {"distance_m": 142.3, "hitzone": "head"}}],
    })
    assert b.batch_seq == 7
    assert b.events[0].type == "kill"
    assert b.events[0].payload["distance_m"] == 142.3


def test_event_batch_rejects_negative_seq():
    with pytest.raises(ValidationError):
        EventBatchIn.model_validate({"match_id": "m1", "batch_seq": -1, "events": []})


def test_match_report_parses():
    r = MatchReportIn.model_validate({
        "report_version": 1,
        "match": {"match_id": "m1", "server_id": "game2-dev-1", "map": "dust",
                  "mode": "conquest", "started_at": "2026-07-11T10:00:00Z",
                  "ended_at": "2026-07-11T10:20:00Z", "winner": "team_a"},
        "players": [{"name": "Bot_A", "steam_id": None, "team": "team_a", "kills": 12,
                     "deaths": 8, "assists": 3, "downs": 5, "revives": 2, "captures": 2,
                     "neutralizes": 0, "xp_earned": 3400, "longest_kill_m": 214.5,
                     "playtime_s": 1180, "result": "win",
                     "weapons": [{"weapon_id": "ar", "shots": 420, "hits": 150, "kills": 8,
                                  "headshots": 3, "damage": 2100, "time_used_s": 800}]}],
    })
    assert r.match.match_id == "m1"
    assert r.players[0].weapons[0].weapon_id == "ar"


def test_match_report_rejects_missing_match_id():
    with pytest.raises(ValidationError):
        MatchReportIn.model_validate({"report_version": 1,
            "match": {"server_id": "s", "map": "m", "mode": "conquest"}, "players": []})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_schemas.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.schemas'`

- [ ] **Step 3: Write `backend/app/schemas.py`**

```python
import datetime as dt

from pydantic import BaseModel, Field


class EventIn(BaseModel):
    tick: int
    type: str
    actor: str | None = None
    target: str | None = None
    weapon_id: str | None = None
    payload: dict = Field(default_factory=dict)


class EventBatchIn(BaseModel):
    match_id: str
    batch_seq: int = Field(ge=0)
    events: list[EventIn]


class WeaponStatIn(BaseModel):
    weapon_id: str
    shots: int = 0
    hits: int = 0
    kills: int = 0
    headshots: int = 0
    damage: int = 0
    time_used_s: int = 0


class PlayerReportIn(BaseModel):
    name: str
    steam_id: int | None = None
    team: str = ""
    kills: int = 0
    deaths: int = 0
    assists: int = 0
    downs: int = 0
    revives: int = 0
    captures: int = 0
    neutralizes: int = 0
    xp_earned: int = 0
    longest_kill_m: float = 0.0
    playtime_s: int = 0
    result: str = ""
    weapons: list[WeaponStatIn] = Field(default_factory=list)


class MatchMetaIn(BaseModel):
    match_id: str
    server_id: str
    map: str
    mode: str
    started_at: dt.datetime | None = None
    ended_at: dt.datetime | None = None
    winner: str | None = None


class MatchReportIn(BaseModel):
    report_version: int = 1
    match: MatchMetaIn
    players: list[PlayerReportIn]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_schemas.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas.py backend/tests/test_schemas.py
git commit -m "feat(stats): pydantic ingest schemas"
```

---

### Task 5: Bearer-token auth dependency

**Files:**
- Create: `backend/app/auth.py`
- Test: `backend/tests/test_auth.py`

- [ ] **Step 1: Write the failing test** `backend/tests/test_auth.py`

```python
import pytest
from fastapi import Depends, FastAPI
from httpx import ASGITransport, AsyncClient

from app.auth import require_ingest_token
from app.config import Settings


def _app(token: str) -> FastAPI:
    app = FastAPI()
    app.dependency_overrides = {}
    app.state.settings = Settings(database_url="x", ingest_token=token)

    @app.post("/guarded", dependencies=[Depends(require_ingest_token)])
    async def guarded():
        return {"ok": True}

    return app


async def _post(app, headers):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        return await c.post("/guarded", headers=headers)


async def test_valid_token_allows():
    r = await _post(_app("secret"), {"Authorization": "Bearer secret"})
    assert r.status_code == 200


async def test_missing_token_401():
    r = await _post(_app("secret"), {})
    assert r.status_code == 401


async def test_wrong_token_401():
    r = await _post(_app("secret"), {"Authorization": "Bearer nope"})
    assert r.status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_auth.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.auth'`

- [ ] **Step 3: Write `backend/app/auth.py`**

```python
import secrets

from fastapi import HTTPException, Request


async def require_ingest_token(request: Request) -> None:
    expected = request.app.state.settings.ingest_token
    header = request.headers.get("Authorization", "")
    prefix = "Bearer "
    supplied = header[len(prefix):] if header.startswith(prefix) else ""
    if not supplied or not secrets.compare_digest(supplied, expected):
        raise HTTPException(status_code=401, detail="invalid ingest token")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_auth.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add backend/app/auth.py backend/tests/test_auth.py
git commit -m "feat(stats): bearer-token ingest auth"
```

---

### Task 6: FastAPI app + health endpoint

**Files:**
- Create: `backend/app/main.py`
- Test: `backend/tests/test_health.py`
- Modify: `backend/tests/conftest.py` (add shared app/client fixtures)

- [ ] **Step 1: Add fixtures to `backend/tests/conftest.py`** (append below the sys.path insert)

```python
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
```

Note: `Settings(ingest_token="test-token")` still needs `database_url`; the env exported in "Running the test DB" supplies it. `create_app` accepts an explicit sessionmaker so tests inject the test DB.

- [ ] **Step 2: Write the failing test** `backend/tests/test_health.py`

```python
async def test_healthz_ok(client):
    r = await client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_health.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.main'`

- [ ] **Step 4: Write `backend/app/main.py`**

```python
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import Settings, get_settings
from app.db import init_db, make_engine, make_sessionmaker


def create_app(settings: Settings | None = None,
               sessionmaker: async_sessionmaker[AsyncSession] | None = None) -> FastAPI:
    settings = settings or get_settings()
    app = FastAPI(title="Blockfire Stats API")
    app.state.settings = settings

    if sessionmaker is None:
        engine = make_engine(settings.database_url)
        app.state.engine = engine
        sessionmaker = make_sessionmaker(engine)

        @app.on_event("startup")
        async def _startup() -> None:
            await init_db(engine)

    app.state.sessionmaker = sessionmaker

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    from app.routes import register_ingest_routes  # local import avoids cycle
    register_ingest_routes(app)
    return app


app = create_app()
```

Note: `app.routes` is created in Task 7. To keep Task 6 runnable now, create a stub `backend/app/routes.py`:

```python
from fastapi import FastAPI


def register_ingest_routes(app: FastAPI) -> None:
    pass  # populated in Task 7
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_health.py -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add backend/app/main.py backend/app/routes.py backend/tests/conftest.py backend/tests/test_health.py
git commit -m "feat(stats): FastAPI app factory + healthz"
```

---

### Task 7: `/ingest/events` endpoint with batch idempotency

**Files:**
- Create: `backend/app/ingest.py`
- Modify: `backend/app/routes.py`
- Test: `backend/tests/test_ingest_events.py`

- [ ] **Step 1: Write the failing test** `backend/tests/test_ingest_events.py`

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_ingest_events.py -v`
Expected: FAIL — 404 (route not registered) / ImportError for `app.ingest`

- [ ] **Step 3: Write `backend/app/ingest.py`** (event half)

```python
import datetime as dt

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Event, IngestedBatch
from app.schemas import EventBatchIn


async def ingest_event_batch(session: AsyncSession, batch: EventBatchIn) -> bool:
    """Insert a batch's events. Returns False (and writes nothing) if this
    (match_id, batch_seq) was already ingested. Idempotent."""
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
```

- [ ] **Step 4: Replace `backend/app/routes.py`**

```python
from fastapi import Depends, FastAPI, Request, Response

from app.auth import require_ingest_token
from app.ingest import ingest_event_batch
from app.schemas import EventBatchIn


def register_ingest_routes(app: FastAPI) -> None:
    @app.post("/ingest/events", status_code=202,
              dependencies=[Depends(require_ingest_token)])
    async def ingest_events(batch: EventBatchIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_event_batch(session, batch)
        return Response(status_code=202)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_ingest_events.py -v`
Expected: PASS (3 passed)

- [ ] **Step 6: Commit**

```bash
git add backend/app/ingest.py backend/app/routes.py backend/tests/test_ingest_events.py
git commit -m "feat(stats): /ingest/events with batch idempotency"
```

---

### Task 8: `/ingest/match` endpoint (players, counters, summary)

**Files:**
- Modify: `backend/app/ingest.py`, `backend/app/routes.py`
- Test: `backend/tests/test_ingest_match.py`

- [ ] **Step 1: Write the failing test** `backend/tests/test_ingest_match.py`

```python
from sqlalchemy import select
from app.models import Match, MatchPlayer, MatchPlayerWeapon, Player

REPORT = {
    "report_version": 1,
    "match": {"match_id": "m1", "server_id": "game2-dev-1", "map": "dust",
              "mode": "conquest", "started_at": "2026-07-11T10:00:00Z",
              "ended_at": "2026-07-11T10:20:00Z", "winner": "team_a"},
    "players": [{"name": "Bot_A", "steam_id": None, "team": "team_a", "kills": 12,
                 "deaths": 8, "assists": 3, "downs": 5, "revives": 2, "captures": 2,
                 "neutralizes": 0, "xp_earned": 3400, "longest_kill_m": 214.5,
                 "playtime_s": 1180, "result": "win",
                 "weapons": [{"weapon_id": "ar", "shots": 420, "hits": 150, "kills": 8,
                              "headshots": 3, "damage": 2100, "time_used_s": 800}]}]}


async def test_match_report_persists_all_layers(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    r = await client.post("/ingest/match", json=REPORT)
    assert r.status_code == 202
    async with sm() as s:
        m = (await s.execute(select(Match).where(Match.match_id == "m1"))).scalar_one()
        assert m.winner == "team_a" and m.complete is True and m.duration_s == 1200
        p = (await s.execute(select(Player).where(Player.player_key == "name:Bot_A"))).scalar_one()
        assert p.name == "Bot_A"
        mp = (await s.execute(select(MatchPlayer))).scalar_one()
        assert mp.kills == 12 and mp.longest_kill_m == 214.5
        w = (await s.execute(select(MatchPlayerWeapon))).scalar_one()
        assert w.weapon_id == "ar" and w.hits == 150


async def test_hit_rate_query_is_correct(client, app_and_sessionmaker):
    """The P1 gate's sample balancing query: hit-rate = hits/shots per weapon."""
    _, sm = app_and_sessionmaker
    await client.post("/ingest/match", json=REPORT)
    async with sm() as s:
        w = (await s.execute(select(MatchPlayerWeapon))).scalar_one()
        assert round(w.hits / w.shots, 4) == round(150 / 420, 4)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_ingest_match.py -v`
Expected: FAIL — 404 (route not registered)

- [ ] **Step 3: Append to `backend/app/ingest.py`**

```python
from app.identity import player_key
from app.models import Match, MatchPlayer, MatchPlayerWeapon
from app.schemas import MatchReportIn


async def _upsert_player(session: AsyncSession, key: str, steam_id: int | None,
                         name: str, now: dt.datetime) -> None:
    existing = await session.get(Player, key)
    if existing is None:
        session.add(Player(player_key=key, steam_id=steam_id or None, name=name,
                           first_seen=now, last_seen=now))
    else:
        existing.last_seen = now
        if steam_id:
            existing.steam_id = steam_id


async def ingest_match_report(session: AsyncSession, report: MatchReportIn) -> None:
    """Upsert the match, its players, per-player summaries and per-weapon
    counters. Idempotent: re-POSTing the same match overwrites the summary."""
    now = dt.datetime.now(dt.timezone.utc)
    m = report.match
    duration = None
    if m.started_at and m.ended_at:
        duration = int((m.ended_at - m.started_at).total_seconds())

    match_row = await session.get(Match, m.match_id)
    if match_row is None:
        match_row = Match(match_id=m.match_id)
        session.add(match_row)
    match_row.server_id = m.server_id
    match_row.map = m.map
    match_row.mode = m.mode
    match_row.started_at = m.started_at
    match_row.ended_at = m.ended_at
    match_row.duration_s = duration
    match_row.winner = m.winner
    match_row.report_version = report.report_version
    match_row.complete = True
    match_row.ingested_at = now

    for p in report.players:
        key = player_key(p.steam_id, p.name)
        await _upsert_player(session, key, p.steam_id, p.name, now)
        mp = await session.get(MatchPlayer, (m.match_id, key))
        if mp is None:
            mp = MatchPlayer(match_id=m.match_id, player_key=key)
            session.add(mp)
        mp.team = p.team
        mp.kills, mp.deaths, mp.assists = p.kills, p.deaths, p.assists
        mp.downs, mp.revives = p.downs, p.revives
        mp.captures, mp.neutralizes = p.captures, p.neutralizes
        mp.xp_earned, mp.longest_kill_m = p.xp_earned, p.longest_kill_m
        mp.playtime_s, mp.result = p.playtime_s, p.result
        for w in p.weapons:
            mpw = await session.get(MatchPlayerWeapon, (m.match_id, key, w.weapon_id))
            if mpw is None:
                mpw = MatchPlayerWeapon(match_id=m.match_id, player_key=key, weapon_id=w.weapon_id)
                session.add(mpw)
            mpw.shots, mpw.hits, mpw.kills = w.shots, w.hits, w.kills
            mpw.headshots, mpw.damage, mpw.time_used_s = w.headshots, w.damage, w.time_used_s
    await session.commit()
```

- [ ] **Step 4: Add the route to `backend/app/routes.py`** (add import + endpoint)

Add to imports: `from app.ingest import ingest_event_batch, ingest_match_report` and `from app.schemas import EventBatchIn, MatchReportIn`. Add inside `register_ingest_routes`:

```python
    @app.post("/ingest/match", status_code=202,
              dependencies=[Depends(require_ingest_token)])
    async def ingest_match(report: MatchReportIn, request: Request) -> Response:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            await ingest_match_report(session, report)
        return Response(status_code=202)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_ingest_match.py -v`
Expected: PASS (2 passed)

- [ ] **Step 6: Commit**

```bash
git add backend/app/ingest.py backend/app/routes.py backend/tests/test_ingest_match.py
git commit -m "feat(stats): /ingest/match upsert (players, counters, summary)"
```

---

### Task 9: End-to-end idempotency

**Files:**
- Test: `backend/tests/test_idempotency.py`

- [ ] **Step 1: Write the test** `backend/tests/test_idempotency.py`

```python
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
```

- [ ] **Step 2: Run test to verify it passes** (behaviour already implemented in Tasks 7–8)

Run: `cd backend && python -m pytest tests/test_idempotency.py -v`
Expected: PASS — if it fails, the upsert logic in Task 8 is wrong; fix `ingest_match_report` before proceeding.

- [ ] **Step 3: Commit**

```bash
git add backend/tests/test_idempotency.py
git commit -m "test(stats): end-to-end match re-ingest idempotency"
```

---

### Task 10: Retention prune worker

**Files:**
- Create: `backend/app/retention.py`, `backend/worker/run.py`
- Test: `backend/tests/test_retention.py`

- [ ] **Step 1: Write the failing test** `backend/tests/test_retention.py`

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_retention.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.retention'`

- [ ] **Step 3: Write `backend/app/retention.py`**

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m pytest tests/test_retention.py -v`
Expected: PASS

- [ ] **Step 5: Write `backend/worker/run.py`** (the long-lived prune loop; no unit test — exercised via compose in Task 11)

```python
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
        async with sm() as session:
            deleted = await prune_old_events(session, settings.raw_event_retention_days)
        print(f"[worker] pruned {deleted} events older than "
              f"{settings.raw_event_retention_days}d", flush=True)
        await asyncio.sleep(PRUNE_INTERVAL_S)


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 6: Commit**

```bash
git add backend/app/retention.py backend/worker/run.py backend/tests/test_retention.py
git commit -m "feat(stats): raw-event retention prune + worker loop"
```

---

### Task 11: Dockerfile + docker-compose + end-to-end smoke

**Files:**
- Create: `backend/Dockerfile`, `backend/docker-compose.yml`, `backend/README.md`

- [ ] **Step 1: Write `backend/Dockerfile`**

```dockerfile
FROM python:3.11-slim
WORKDIR /srv
COPY pyproject.toml ./
RUN pip install --no-cache-dir . && pip install --no-cache-dir "uvicorn[standard]>=0.29"
COPY app ./app
COPY worker ./worker
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Write `backend/docker-compose.yml`**

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: blockfire
      POSTGRES_PASSWORD: blockfire
      POSTGRES_DB: blockfire_stats
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U blockfire -d blockfire_stats"]
      interval: 5s
      timeout: 3s
      retries: 10

  api:
    build: .
    environment:
      DATABASE_URL: postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats
      INGEST_TOKEN: ${INGEST_TOKEN:-change-me-in-prod}
      RAW_EVENT_RETENTION_DAYS: ${RAW_EVENT_RETENTION_DAYS:-90}
    ports:
      - "8000:8000"
    depends_on:
      db:
        condition: service_healthy

  worker:
    build: .
    command: ["python", "-m", "worker.run"]
    environment:
      DATABASE_URL: postgresql+asyncpg://blockfire:blockfire@db:5432/blockfire_stats
      INGEST_TOKEN: ${INGEST_TOKEN:-change-me-in-prod}
      RAW_EVENT_RETENTION_DAYS: ${RAW_EVENT_RETENTION_DAYS:-90}
    depends_on:
      db:
        condition: service_healthy

volumes:
  pgdata:
```

- [ ] **Step 3: Write `backend/README.md`**

````markdown
# Blockfire Stats Backend (P1 — ingest + DB)

Python/FastAPI + PostgreSQL ingest service for match/event data. See the design spec
`docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md`.

> **For agents doing game work:** this directory is out of scope — see the root `AGENTS.md`.

## Run (dev, on game2 or locally)
```bash
cd backend
export INGEST_TOKEN=dev-secret
docker compose up --build       # db + api (:8000) + worker
curl -s localhost:8000/healthz  # {"status":"ok"}
```

## Test
```bash
cd backend
docker compose up -d db
export DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@localhost:5432/blockfire_stats'
export INGEST_TOKEN='test-token'
pip install -e '.[dev]'
python -m pytest -v
```
````

- [ ] **Step 4: End-to-end smoke (manual verification)**

Run:
```bash
cd backend
export INGEST_TOKEN=dev-secret
docker compose up --build -d
sleep 5
curl -s localhost:8000/healthz
curl -s -X POST localhost:8000/ingest/match -H "Authorization: Bearer dev-secret" \
  -H 'Content-Type: application/json' -d @- <<'JSON'
{"report_version":1,"match":{"match_id":"smoke1","server_id":"local","map":"dust",
"mode":"conquest","started_at":"2026-07-11T10:00:00Z","ended_at":"2026-07-11T10:20:00Z",
"winner":"team_a"},"players":[{"name":"Bot_A","team":"team_a","kills":3,
"weapons":[{"weapon_id":"ar","shots":100,"hits":40,"kills":3}]}]}
JSON
docker compose exec -T db psql -U blockfire -d blockfire_stats \
  -c "SELECT match_id, winner, duration_s FROM matches;" \
  -c "SELECT weapon_id, hits, shots, round(hits::numeric/shots,3) AS hit_rate FROM match_player_weapons;"
```
Expected: `smoke1 | team_a | 1200`, and `ar | 40 | 100 | 0.400`.

- [ ] **Step 5: Verify unauthorized + malformed are rejected**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8000/ingest/match \
  -H 'Content-Type: application/json' -d '{}'                       # expect 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8000/ingest/match \
  -H "Authorization: Bearer dev-secret" -H 'Content-Type: application/json' -d '{}'  # expect 422
docker compose down
```
Expected: `401` then `422`.

- [ ] **Step 6: Commit**

```bash
git add backend/Dockerfile backend/docker-compose.yml backend/README.md
git commit -m "feat(stats): dockerfile + compose (db/api/worker) + smoke docs"
```

---

### Task 12: AGENTS.md scoping note

**Files:**
- Modify: `AGENTS.md` (repo root)

- [ ] **Step 1: Read the current root `AGENTS.md`** to match its heading style.

Run: `sed -n '1,40p' AGENTS.md`

- [ ] **Step 2: Add a scoping section** (place near the top-level layout/overview section, matching surrounding style):

```markdown
## `backend/` — stats & analytics service (out of scope for game work)

`backend/` is the Python/FastAPI + PostgreSQL stats & analytics service
(design: `docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md`).
It is **not part of the Godot game** and shares no runtime with `client/ server/
shared/ bots/`. When working on the game, do **not** scan, analyze, or modify
`backend/` — it only communicates with the game via the HTTP ingest contract.
Work there only when the task is explicitly the stats/analytics milestone.
```

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): scope backend/ out of game work"
```

---

## Self-review

**Spec coverage (P1 portion):**
- Ingest API (`/ingest/events`, `/ingest/match`) — Tasks 7, 8 ✓
- Bearer-token auth — Task 5 ✓
- Postgres schema (players, matches, match_players, match_player_weapons, events) — Task 2 ✓
- Idempotency (batch_seq + match upsert) — Tasks 7, 8, 9 ✓
- Retention prune (raw events > 90d) — Task 10 ✓
- docker-compose (db/api/worker) — Task 11 ✓
- AGENTS.md scoping note — Task 12 ✓
- P1 gate "hit-rate query returns correct numbers" — Task 8 `test_hit_rate_query_is_correct` + Task 11 smoke ✓
- P1 gate "unauthenticated/malformed POSTs rejected" — Task 7 `test_events_require_auth` + Task 11 Step 5 ✓
- **Deferred to P1-B (not this plan):** `StatsReporter`, NDJSON fallback, the live game2 run. **Deferred to P2:** `player_profiles`/`player_weapon_totals` rollups, Steam OpenID, Alembic migrations.

**Placeholder scan:** none — every code step is complete.

**Type consistency:** `player_key(steam_id, name)` signature consistent (Tasks 3, 8); `create_app(settings, sessionmaker)` consistent (Tasks 6, conftest); `ingest_event_batch`/`ingest_match_report` names consistent (Tasks 7, 8, routes); model field names match schema field names used in `ingest.py`.

**Note on identity:** the spec's `players.steam_id` PK is realized as `player_key` PK + nullable `steam_id` column, because the current game server has no SteamID (players are int-id + name; bots have neither). This is the forward-compatible reconciliation flagged during planning.
