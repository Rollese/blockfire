import datetime as dt

import pytest

from app.anomaly import flag_summary, list_flags, set_flag_status
from app.models import AnomalyFlag

NOW = dt.datetime(2026, 7, 12, 12, 0, 0, tzinfo=dt.timezone.utc)


def _flag(metric: str, value: float, severity: str, status: str = "open",
          *, offset: int = 0) -> AnomalyFlag:
    ts = NOW - dt.timedelta(minutes=offset)
    return AnomalyFlag(
        player_key=f"steam:{metric}:{value}:{severity}",
        metric=metric,
        value=value,
        threshold=4.0,
        sample_size=42,
        severity=severity,
        status=status,
        context={},
        created_at=ts,
        last_seen_at=ts,
    )


async def _seed_ordering(sm) -> None:
    """Six flags inserted in a fixed order (flag_id == insertion order 1..6).

    #1 high  kd            value=8.0  open
    #2 high  headshot_rate value=9.0  confirmed
    #3 med   kd            value=5.0  open
    #4 low   hit_rate      value=7.0  dismissed
    #5 high  hit_rate      value=8.0  open      (ties #1 on severity+value)
    #6 med   headshot_rate value=6.0  open

    Expected list_flags order (high->med->low, value DESC, flag_id ASC):
        [#2, #1, #5, #6, #3, #4]  i.e. flag_ids [2, 1, 5, 6, 3, 4]
    """
    async with sm() as s:
        s.add(_flag("kd", 8.0, "high", "open", offset=1))
        s.add(_flag("headshot_rate", 9.0, "high", "confirmed", offset=2))
        s.add(_flag("kd", 5.0, "med", "open", offset=3))
        s.add(_flag("hit_rate", 7.0, "low", "dismissed", offset=4))
        s.add(_flag("hit_rate", 8.0, "high", "open", offset=5))
        s.add(_flag("headshot_rate", 6.0, "med", "open", offset=6))
        await s.commit()


async def test_list_flags_no_filter_order(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ordering(sm)
    async with sm() as s:
        rows = await list_flags(s)

    assert len(rows) == 6
    assert [r["flag_id"] for r in rows] == [2, 1, 5, 6, 3, 4]
    # spot-check the shape: full column set, no ORM leak.
    assert set(rows[0].keys()) == {
        "flag_id", "player_key", "metric", "value", "threshold",
        "sample_size", "severity", "status", "detector_version", "context",
        "created_at", "last_seen_at", "reviewed_at", "reviewed_by", "notes",
    }
    assert rows[0]["metric"] == "headshot_rate"
    assert rows[0]["value"] == 9.0


async def test_list_flags_status_filter(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ordering(sm)
    async with sm() as s:
        rows = await list_flags(s, status="open")

    assert {r["flag_id"] for r in rows} == {1, 3, 5, 6}
    assert all(r["status"] == "open" for r in rows)


async def test_list_flags_metric_filter(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ordering(sm)
    async with sm() as s:
        rows = await list_flags(s, metric="kd")

    assert {r["flag_id"] for r in rows} == {1, 3}
    assert all(r["metric"] == "kd" for r in rows)


async def test_list_flags_combined_filter(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ordering(sm)
    async with sm() as s:
        rows = await list_flags(s, status="open", metric="kd")

    assert {r["flag_id"] for r in rows} == {1, 3}


async def test_list_flags_limit_clamp_low(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ordering(sm)
    async with sm() as s:
        rows_zero = await list_flags(s, limit=0)
        rows_neg = await list_flags(s, limit=-5)

    assert len(rows_zero) <= 1
    assert len(rows_neg) <= 1


async def test_list_flags_limit_clamp_high(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_ordering(sm)
    async with sm() as s:
        rows = await list_flags(s, limit=9999)

    # 6 seeded rows, clamp upper bound (min(9999, 500)) passes them all through.
    assert len(rows) == 6


async def _seed_summary(sm) -> None:
    """Statuses: open x3, confirmed x1, dismissed x0 (zero-safe status).
    Metrics: kd x2, hit_rate x2, headshot_rate x0 (zero-safe metric).
    open_high: 2 open+high rows.
    """
    async with sm() as s:
        s.add(_flag("kd", 8.0, "high", "open"))       # open + high
        s.add(_flag("kd", 6.0, "med", "open"))
        s.add(_flag("hit_rate", 9.0, "high", "open"))  # open + high
        s.add(_flag("hit_rate", 5.0, "low", "confirmed"))
        await s.commit()


async def test_flag_summary_counts(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _seed_summary(sm)
    async with sm() as s:
        summary = await flag_summary(s)

    assert summary["total"] == 4
    assert summary["by_status"] == {"open": 3, "confirmed": 1, "dismissed": 0}
    assert summary["by_metric"] == {"kd": 2, "headshot_rate": 0, "hit_rate": 2}
    assert summary["open_high"] == 2


async def test_set_flag_status_open_to_confirmed(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(_flag("kd", 8.0, "high", "open"))
        await s.commit()

    async with sm() as s:
        out = await set_flag_status(
            s, 1, "confirmed", reviewed_by="admin:1", notes="looks cheaty",
            now=NOW,
        )

    assert out is not None
    assert out["status"] == "confirmed"
    assert out["reviewed_at"] == NOW
    assert out["reviewed_by"] == "admin:1"
    assert out["notes"] == "looks cheaty"

    async with sm() as s:
        got = await s.get(AnomalyFlag, 1)
        assert got.status == "confirmed"
        assert got.reviewed_at == NOW
        assert got.reviewed_by == "admin:1"
        assert got.notes == "looks cheaty"


async def test_set_flag_status_reopen_clears_reviewed_at(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(_flag("kd", 8.0, "high", "confirmed"))
        await s.commit()

    # First confirm (sets reviewed_at), then re-open (must clear it).
    async with sm() as s:
        await set_flag_status(s, 1, "confirmed", reviewed_by="admin:1", now=NOW)
    async with sm() as s:
        out = await set_flag_status(s, 1, "open", reviewed_by="admin:2", now=NOW)

    assert out is not None
    assert out["status"] == "open"
    assert out["reviewed_at"] is None

    async with sm() as s:
        got = await s.get(AnomalyFlag, 1)
        assert got.status == "open"
        assert got.reviewed_at is None


async def test_set_flag_status_invalid_status_raises(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        s.add(_flag("kd", 8.0, "high", "open"))
        await s.commit()

    async with sm() as s:
        with pytest.raises(ValueError):
            await set_flag_status(s, 1, "bogus", now=NOW)


async def test_set_flag_status_unknown_id_returns_none(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        out = await set_flag_status(s, 999999, "confirmed", now=NOW)
    assert out is None


async def test_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        rows = await list_flags(s)
        summary = await flag_summary(s)

    assert rows == []
    assert summary == {
        "total": 0,
        "by_status": {"open": 0, "confirmed": 0, "dismissed": 0},
        "by_metric": {"kd": 0, "headshot_rate": 0, "hit_rate": 0},
        "open_high": 0,
    }
