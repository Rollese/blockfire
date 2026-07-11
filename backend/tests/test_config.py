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


def test_p2_config_defaults(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@h:5432/d")
    monkeypatch.setenv("INGEST_TOKEN", "secret")
    monkeypatch.delenv("STEAM_WEB_API_KEY", raising=False)
    monkeypatch.delenv("SESSION_SECRET", raising=False)
    monkeypatch.delenv("SITE_BASE_URL", raising=False)
    s = Settings()
    assert s.steam_web_api_key is None
    assert s.session_secret == "dev-insecure-change-me"
    assert s.site_base_url == "http://localhost:8000"


def test_p2_config_env_overrides(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@h:5432/d")
    monkeypatch.setenv("INGEST_TOKEN", "secret")
    monkeypatch.setenv("STEAM_WEB_API_KEY", "k")
    monkeypatch.setenv("SESSION_SECRET", "s")
    monkeypatch.setenv("SITE_BASE_URL", "http://x")
    s = Settings()
    assert s.steam_web_api_key == "k"
    assert s.session_secret == "s"
    assert s.site_base_url == "http://x"
