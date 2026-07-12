"""Admin anomaly review-queue HTML page (`app.admin_web` Task 6): the auth
gate, the rendered queue + filters, triage POST redirects, the scan POST, the
empty state, and autoescape/XSS safety.

Mirrors test_admin_web.py: the default `client` fixture (admin_dev_open=False,
no cookie) proves the 403 gate; a second app built here with
admin_dev_open=True over the SAME sessionmaker proves the pages render.
"""

import datetime as dt

from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.main import create_app
from app.models import AnomalyFlag, PlayerProfile

NOW = dt.datetime(2026, 7, 11, 12, 0, 0, tzinfo=dt.timezone.utc)


def _flag(player_key, metric, value, threshold, severity, status="open",
          sample_size=20, notes=None, reviewed_by=None, reviewed_at=None,
          matches_played=3):
    return AnomalyFlag(
        player_key=player_key, metric=metric, value=value, threshold=threshold,
        sample_size=sample_size, severity=severity, status=status,
        detector_version=1,
        context={"matches_played": matches_played, "kills": 100},
        created_at=NOW, last_seen_at=NOW,
        reviewed_at=reviewed_at, reviewed_by=reviewed_by, notes=notes,
    )


async def _seed_flags(sm):
    async with sm() as s:
        s.add(_flag("name:Cheater", "kd", 12.5, 4.0, "high", status="open"))
        s.add(_flag("name:Sharp", "headshot_rate", 0.72, 0.6, "med",
                    status="open"))
        s.add(_flag("name:OldConfirmed", "hit_rate", 0.8, 0.55, "high",
                    status="confirmed", reviewed_by="76561198000000000",
                    reviewed_at=NOW, notes="clear aimbot"))
        await s.commit()


async def _admin_client(sm) -> AsyncClient:
    settings = Settings(ingest_token="test-token", admin_dev_open=True)
    app = create_app(settings=settings, sessionmaker=sm)
    transport = ASGITransport(app=app)
    return AsyncClient(transport=transport, base_url="http://t")


# --- 1. gate -----------------------------------------------------------------

async def test_anomaly_pages_403_for_non_admin(client, app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    assert (await client.get("/admin/anomalies")).status_code == 403
    r = await client.post("/admin/anomalies/1/review",
                          data={"status": "confirmed"})
    assert r.status_code == 403
    assert (await client.post("/admin/anomalies/scan")).status_code == 403


# --- 2. dev-open GET + filters ----------------------------------------------

async def test_anomaly_queue_renders_open_flags(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/anomalies")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Anomaly Review Queue" in r.text
    # default (no status param) shows open flags
    assert "name:Cheater" in r.text
    assert "kd" in r.text
    assert "name:Sharp" in r.text
    # a confirmed-only flag is NOT in the default open view
    assert "name:OldConfirmed" not in r.text
    # summary counts present
    assert "Total" in r.text and "Confirmed" in r.text


async def test_anomaly_queue_filter_by_status_confirmed(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/anomalies", params={"status": "confirmed"})
    assert r.status_code == 200
    assert "name:OldConfirmed" in r.text        # confirmed flag shows
    assert "name:Cheater" not in r.text          # open-only flag excluded


async def test_anomaly_queue_filter_by_metric(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with await _admin_client(sm) as c:
        # status="" -> all statuses, metric=kd narrows
        r = await c.get("/admin/anomalies",
                        params={"status": "", "metric": "kd"})
    assert r.status_code == 200
    assert "name:Cheater" in r.text              # kd flag survives
    assert "name:Sharp" not in r.text            # headshot_rate flag filtered


# --- 3. triage POST ----------------------------------------------------------

async def test_anomaly_review_confirm_redirects_and_removes_from_open(
        app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with sm() as s:
        flag = _flag("name:Target", "kd", 9.0, 4.0, "high", status="open")
        s.add(flag)
        await s.commit()
        flag_id = flag.flag_id

    async with await _admin_client(sm) as c:
        r = await c.post(f"/admin/anomalies/{flag_id}/review",
                         data={"status": "confirmed", "notes": "blatant",
                               "back_status": "open"},
                         follow_redirects=False)
        assert r.status_code == 303
        assert r.headers["location"] == "/admin/anomalies?status=open"

        follow = await c.get("/admin/anomalies", params={"status": "open"})
    assert "name:Target" not in follow.text      # now confirmed, off the queue


async def test_anomaly_review_bad_status_400(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_flags(sm)
    async with await _admin_client(sm) as c:
        r = await c.post("/admin/anomalies/1/review",
                         data={"status": "bogus"}, follow_redirects=False)
    assert r.status_code == 400


async def test_anomaly_review_unknown_flag_404(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.post("/admin/anomalies/999999/review",
                         data={"status": "confirmed"}, follow_redirects=False)
    assert r.status_code == 404


# --- 4. scan POST ------------------------------------------------------------

async def test_anomaly_scan_flags_egregious_cheater(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(PlayerProfile(
            player_key="name:Aimbot", kd_ratio=40.0, total_kills=200,
            total_deaths=5, overall_hit_rate=0.95, total_shots=300,
            total_hits=285, total_headshots=270, matches_played=1,
            updated_at=NOW,
        ))
        await s.commit()

    async with await _admin_client(sm) as c:
        r = await c.post("/admin/anomalies/scan", follow_redirects=False)
        assert r.status_code == 303
        assert r.headers["location"] == "/admin/anomalies"
        follow = await c.get("/admin/anomalies", params={"status": ""})
    assert "name:Aimbot" in follow.text


# --- 5. empty DB -------------------------------------------------------------

async def test_anomaly_queue_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/anomalies")
    assert r.status_code == 200
    assert "No anomaly flags match." in r.text


# --- 6. autoescape / XSS -----------------------------------------------------

async def test_anomaly_notes_are_autoescaped(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    payload = '"><script>alert(1)</script>'
    async with sm() as s:
        s.add(_flag("name:Xss", "kd", 9.0, 4.0, "high", status="dismissed",
                    reviewed_by="dev", reviewed_at=NOW, notes=payload))
        await s.commit()
    async with await _admin_client(sm) as c:
        r = await c.get("/admin/anomalies", params={"status": "dismissed"})
    assert r.status_code == 200
    assert "name:Xss" in r.text
    assert "<script>alert(1)</script>" not in r.text   # not injected raw
    assert "&lt;script&gt;" in r.text                   # escaped instead
