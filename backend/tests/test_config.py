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


def test_admin_steam_id_set_parses_csv():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
        admin_steam_ids="76561190000000001, 76561190000000002",
    )
    assert s.admin_steam_id_set() == frozenset(
        {76561190000000001, 76561190000000002}
    )


def test_admin_steam_id_set_empty_string():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
        admin_steam_ids="",
    )
    assert s.admin_steam_id_set() == frozenset()


def test_admin_steam_id_set_tolerates_whitespace_and_trailing_comma():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
        admin_steam_ids=" 76561190000000001 ,  ,",
    )
    assert s.admin_steam_id_set() == frozenset({76561190000000001})


def test_admin_steam_id_set_skips_non_numeric_tokens():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
        admin_steam_ids="76561190000000001, garbage, 76561190000000002",
    )
    assert s.admin_steam_id_set() == frozenset(
        {76561190000000001, 76561190000000002}
    )


def test_admin_steam_id_set_all_garbage_returns_empty_no_raise():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
        admin_steam_ids="nope, ---",
    )
    assert s.admin_steam_id_set() == frozenset()


def test_admin_dev_open_defaults_false():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
    )
    assert s.admin_dev_open is False


def test_admin_dev_open_env_override(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@h:5432/d")
    monkeypatch.setenv("INGEST_TOKEN", "secret")
    monkeypatch.setenv("ADMIN_DEV_OPEN", "true")
    s = Settings()
    assert s.admin_dev_open is True


def test_p4_anomaly_config_defaults():
    s = Settings(
        database_url="postgresql+asyncpg://u:p@h:5432/d",
        ingest_token="secret",
    )
    assert s.anomaly_kd_floor == 4.0
    assert s.anomaly_headshot_rate_floor == 0.6
    assert s.anomaly_hit_rate_floor == 0.55
    assert s.anomaly_min_deaths == 5
    assert s.anomaly_min_kills == 10
    assert s.anomaly_min_hits == 40
    assert s.anomaly_min_shots == 100
    assert s.anomaly_min_population == 5
    assert s.anomaly_mad_k == 3.5


def test_p4_anomaly_config_env_override(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@h:5432/d")
    monkeypatch.setenv("INGEST_TOKEN", "secret")
    monkeypatch.setenv("ANOMALY_KD_FLOOR", "6.5")
    s = Settings()
    assert s.anomaly_kd_floor == 6.5


def test_signing_key_map_parses():
    from app.config import Settings
    s = Settings(ingest_token="t", ingest_signing_keys="game2-dev-1:sa bad-token")
    assert s.signing_key_map() == {"game2-dev-1": "sa"}


def test_signing_defaults():
    from app.config import Settings
    s = Settings(ingest_token="t")
    assert s.ingest_signing_keys == ""
    assert s.require_signed_ingest is False
    assert s.ingest_max_skew_s == 300
    assert s.signing_key_map() == {}


def test_rating_defaults():
    from app.config import Settings
    s = Settings()
    assert s.rating_require_trusted is True
    assert s.rating_mu_init == 25.0
    assert abs(s.rating_sigma_init - 25.0 / 3.0) < 1e-9
    assert abs(s.rating_beta - 25.0 / 6.0) < 1e-9
    assert s.rating_ordinal_z == 3.0
    assert s.rating_w_capture == 3.0
    bps = s.rating_tier_breakpoints()
    assert bps[0][1] == "Bronze"
    assert all(bps[i][0] <= bps[i + 1][0] for i in range(len(bps) - 1))


def test_rating_tier_breakpoints_parse_override(monkeypatch):
    from app.config import Settings
    s = Settings(rating_tier_thresholds="0:Wood,50:Iron")
    bps = s.rating_tier_breakpoints()
    assert bps == [(0.0, "Wood"), (50.0, "Iron")]
