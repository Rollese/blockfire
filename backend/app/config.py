from pydantic_settings import BaseSettings, SettingsConfigDict

from app.signing import parse_signing_keys


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    ingest_token: str
    # M9-P1 signed match reports (ADR-0011). Space/comma-separated key_id:secret
    # pairs; any configured key is an official/trusted signer.
    ingest_signing_keys: str = ""
    # When True, unsigned ingest POSTs are rejected 401 (prod). Default False
    # keeps M20 dev servers (no signature) working, ingested as trusted=false.
    require_signed_ingest: bool = False
    # Max abs clock skew (seconds) tolerated on X-BF-Timestamp.
    ingest_max_skew_s: int = 300
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

    # --- P4 anomaly-detection thresholds (tuning knobs) ---
    anomaly_kd_floor: float = 4.0
    anomaly_headshot_rate_floor: float = 0.6
    anomaly_hit_rate_floor: float = 0.55
    anomaly_min_deaths: int = 5
    anomaly_min_kills: int = 10
    anomaly_min_hits: int = 40
    anomaly_min_shots: int = 100
    anomaly_min_population: int = 5
    anomaly_mad_k: float = 3.5

    # --- M9-P2 rating knobs (ADR-0012) ---
    rating_require_trusted: bool = True
    rating_mu_init: float = 25.0
    rating_sigma_init: float = 25.0 / 3.0
    rating_beta: float = 25.0 / 6.0
    rating_tau: float = 25.0 / 300.0
    rating_ordinal_z: float = 3.0
    rating_draw_margin: float = 0.1
    rating_perf_floor: float = 1.0
    rating_w_kill: float = 1.0
    rating_w_assist: float = 0.5
    rating_w_capture: float = 3.0
    rating_w_neutralize: float = 2.0
    rating_w_revive: float = 1.5
    rating_w_death: float = 0.5
    rating_tier_thresholds: str = "0:Bronze,10:Silver,17:Gold,24:Platinum,31:Diamond"

    def rating_tier_breakpoints(self) -> list[tuple[float, str]]:
        out: list[tuple[float, str]] = []
        for part in self.rating_tier_thresholds.split(","):
            part = part.strip()
            if not part:
                continue
            lo, _, name = part.partition(":")
            out.append((float(lo), name.strip()))
        out.sort(key=lambda t: t[0])
        return out

    def admin_steam_id_set(self) -> frozenset[int]:
        tokens = self.admin_steam_ids.replace(",", " ").split()
        # SteamID64s are always positive integers, so isdigit() is a clean,
        # correct filter. Skip (rather than raise on) any non-numeric token
        # so a deploy-time typo in ADMIN_STEAM_IDS can't 500 the public
        # homepage (is_admin() is evaluated there to gate the Admin nav link).
        return frozenset(int(token) for token in tokens if token.isdigit())

    def signing_key_map(self) -> dict[str, str]:
        return parse_signing_keys(self.ingest_signing_keys)


def get_settings() -> Settings:
    return Settings()
