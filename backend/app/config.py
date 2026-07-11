from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    ingest_token: str
    raw_event_retention_days: int = 90
    steam_web_api_key: str | None = None
    session_secret: str = "dev-insecure-change-me"
    site_base_url: str = "http://localhost:8000"


def get_settings() -> Settings:
    return Settings()
