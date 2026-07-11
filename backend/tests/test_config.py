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
