from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    ingest_token: str
    raw_event_retention_days: int = 90
    steam_web_api_key: str | None = None
    session_secret: str = "dev-insecure-change-me"
    site_base_url: str = "http://localhost:8000"

    # Comma/space-separated list of admin SteamID64s. Kept as a raw str
    # (pydantic-settings can't reliably parse a bare CSV env var into a
    # set[int]); use admin_steam_id_set() to get the parsed set.
    admin_steam_ids: str = ""

    # When True, admin routes are open WITHOUT Steam auth.
    # dev/LAN only — MUST stay False in any internet-facing deploy.
    admin_dev_open: bool = False

    def admin_steam_id_set(self) -> frozenset[int]:
        tokens = self.admin_steam_ids.replace(",", " ").split()
        return frozenset(int(token) for token in tokens if token)


def get_settings() -> Settings:
    return Settings()
