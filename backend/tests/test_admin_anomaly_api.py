"""Admin JSON API for the anomaly review queue (`app.admin_api`, Task 5).

Mirrors test_admin_api.py's three-app pattern over ONE shared sessionmaker:
  - default `client` fixture (admin_dev_open=False, no cookie) -> every new
    /admin/api anomaly route 403s for a non-admin caller.
  - a second app (admin_dev_open=True) -> proves the routes work + shapes.
  - a cookie-signed app (admin_dev_open=False, allowlisted steam_id) -> proves
    the cookie path works AND that reviewed_by records the steam_id string.
"""

import datetime as dt

from httpx import ASGITransport, AsyncClient
from itsdangerous import URLSafeSerializer

from app.config import Settings
from app.main import create_app
from app.models import AnomalyFlag, PlayerProfile

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)
ADMIN_ID = 76561198000000001


def _flag(player_key: str, metric: str, *, value: float, severity: str,
          status: str = "open") -> AnomalyFlag:
    return AnomalyFlag(
        player_key=player_key, metric=metric, value=value, threshold=4.0,
        sample_size=10, severity=severity, status=status, detector_version=1,
        context={}, created_at=NOW, last_seen_at=NOW,
    )


async def _seed_flags(sm) -> None:
    async with sm() as s:
        s.add(_flag("name:P1", "kd", value=12.0, severity="high"))
        s.add(_flag("name:P2", "hit_rate", value=0.9, severity="med",
                    status="confirmed"))
        await s.commit()


async def _seed_cheater(sm) -> None:
    async with sm() as s:
        s.add(PlayerProfile(
            player_key="name:CHEAT", total_kills=200, total_deaths=5,
            kd_ratio=40.0, total_shots=300, total_hits=285, total_headshots=270,
            overall_hit_rate=0.95, matches_played=1, updated_at=NOW,
        ))
        await s.commit()


async def _admin_client(sm) -> AsyncClient:
    """Second app over the SAME sessionmaker, admin_dev_open=True."""
    settings = Settings(ingest_token="test-token", admin_dev_open=True)
    app = create_app(settings=settings, sessionmaker=sm)
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


# ---- 1. auth gate -----------------------------------------------------------

async def test_anomaly_routes_403_for_non_admin(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)

    assert (await client.get("/admin/api/anomalies")).status_code == 403
    assert (await client.post("/admin/api/anomaly/scan")).status_code == 403
    r = await client.post("/admin/api/anomalies/1/review",
                          json={"status": "confirmed"})
    assert r.status_code == 403


# ---- 2. dev-open happy paths ------------------------------------------------

async def test_anomalies_list_and_summary(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/api/anomalies")
    assert r.status_code == 200
    body = r.json()
    assert isinstance(body["flags"], list)
    assert len(body["flags"]) == 2
    summary = body["summary"]
    assert set(summary.keys()) == {"total", "by_status", "by_metric", "open_high"}
    assert summary["total"] == 2
    assert summary["by_status"]["open"] == 1
    assert summary["by_status"]["confirmed"] == 1
    assert summary["by_metric"]["kd"] == 1
    assert summary["by_metric"]["hit_rate"] == 1
    assert summary["open_high"] == 1


async def test_anomalies_list_filters(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with await _admin_client(sm) as c:
        r_status = await c.get("/admin/api/anomalies", params={"status": "open"})
        r_metric = await c.get("/admin/api/anomalies", params={"metric": "kd"})
    assert r_status.status_code == 200
    flags = r_status.json()["flags"]
    assert len(flags) == 1
    assert flags[0]["status"] == "open"
    assert flags[0]["metric"] == "kd"

    assert r_metric.status_code == 200
    metric_flags = r_metric.json()["flags"]
    assert len(metric_flags) == 1
    assert metric_flags[0]["metric"] == "kd"


async def test_anomaly_scan_flags_egregious_cheater(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_cheater(sm)
    async with await _admin_client(sm) as c:
        r = await c.post("/admin/api/anomaly/scan")
    assert r.status_code == 200
    assert r.json()["written"] >= 1

    async with sm() as s:
        from sqlalchemy import select
        rows = (await s.execute(select(AnomalyFlag))).scalars().all()
    assert len(rows) >= 1
    assert any(f.player_key == "name:CHEAT" for f in rows)


async def test_anomaly_review_confirm(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        f = _flag("name:P1", "kd", value=12.0, severity="high")
        s.add(f)
        await s.commit()
        flag_id = f.flag_id

    async with await _admin_client(sm) as c:
        r = await c.post(f"/admin/api/anomalies/{flag_id}/review",
                         json={"status": "confirmed", "notes": "blatant"})
    assert r.status_code == 200
    flag = r.json()["flag"]
    assert flag["status"] == "confirmed"
    assert flag["reviewed_by"] == "dev"
    assert flag["notes"] == "blatant"


async def test_anomaly_review_bad_status_400(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        f = _flag("name:P1", "kd", value=12.0, severity="high")
        s.add(f)
        await s.commit()
        flag_id = f.flag_id

    async with await _admin_client(sm) as c:
        r = await c.post(f"/admin/api/anomalies/{flag_id}/review",
                         json={"status": "bogus"})
    assert r.status_code == 400


async def test_anomaly_review_unknown_id_404(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.post("/admin/api/anomalies/999999/review",
                         json={"status": "confirmed"})
    assert r.status_code == 404


# ---- 3. cookie path ---------------------------------------------------------

async def test_anomaly_routes_cookie_path_records_steam_id(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        f = _flag("name:P1", "kd", value=12.0, severity="high")
        s.add(f)
        await s.commit()
        flag_id = f.flag_id

    settings = Settings(ingest_token="test-token", session_secret="topsecret",
                        admin_dev_open=False, admin_steam_ids=str(ADMIN_ID))
    app = create_app(settings=settings, sessionmaker=sm)
    cookie = URLSafeSerializer(settings.session_secret, salt="session").dumps(
        {"steam_id": ADMIN_ID})
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        c.cookies.set("bf_session", cookie)
        r_list = await c.get("/admin/api/anomalies")
        assert r_list.status_code == 200
        r_review = await c.post(f"/admin/api/anomalies/{flag_id}/review",
                                json={"status": "confirmed"})
    assert r_review.status_code == 200
    assert r_review.json()["flag"]["reviewed_by"] == str(ADMIN_ID)
