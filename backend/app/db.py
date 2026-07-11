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
    """Create all tables if absent. Idempotent and safe under concurrent startup
    (api + worker start together under compose): a transaction-scoped advisory
    lock serializes create_all so two processes can't both CREATE the same table.
    Alembic migrations are introduced at the first schema change (P2)."""
    async with engine.begin() as conn:
        await conn.exec_driver_sql("SELECT pg_advisory_xact_lock(4915301)")
        await conn.run_sync(Base.metadata.create_all)
