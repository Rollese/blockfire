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
