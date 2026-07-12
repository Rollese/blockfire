import datetime as dt
import statistics

import pytest
from sqlalchemy import func, select

from app.anomaly import ANOMALY_DETECTOR_VERSION, detect_anomalies
from app.config import Settings
from app.models import AnomalyFlag, PlayerProfile

NOW = dt.datetime(2026, 7, 12, 12, 0, 0, tzinfo=dt.timezone.utc)


def _settings() -> Settings:
    # DATABASE_URL from env; ingest_token explicit like conftest.
    return Settings(ingest_token="test-token")


def _profile(key: str, *, kills=0, deaths=0, shots=0, hits=0, headshots=0,
             kd=0.0, hit_rate=0.0, matches=1, updated_at=NOW) -> PlayerProfile:
    return PlayerProfile(
        player_key=key,
        total_kills=kills,
        total_deaths=deaths,
        total_shots=shots,
        total_hits=hits,
        total_headshots=headshots,
        kd_ratio=kd,
        overall_hit_rate=hit_rate,
        matches_played=matches,
        updated_at=updated_at,
    )


def _normal(i: int) -> PlayerProfile:
    # kd ~1.0, hs ~0.15, hit_rate ~0.35 — comfortably below all floors.
    return _profile(
        f"name:N{i}",
        kills=10, deaths=10, kd=1.0,
        shots=200, hits=70, headshots=10,
        hit_rate=0.35,
    )


def _cheater() -> PlayerProfile:
    # kd 25, hs 0.95, hit_rate 0.9 — egregious on all three metrics.
    # NOTE: deaths=5 (not 2) so the kd gate (min_deaths=5) is satisfied while
    # kd stays 25 (kills 125 / deaths 5). headshots 171 / hits 180 = 0.95.
    return _profile(
        "name:CHEAT",
        kills=125, deaths=5, kd=25.0,
        shots=200, hits=180, headshots=171,
        hit_rate=0.9,
    )


async def _add(sm, *rows):
    async with sm() as s:
        for r in rows:
            s.add(r)
        await s.commit()


async def _flags_for(sm, pk):
    async with sm() as s:
        return (await s.execute(
            select(AnomalyFlag).where(AnomalyFlag.player_key == pk)
        )).scalars().all()


async def _count(sm):
    async with sm() as s:
        return (await s.execute(select(func.count()).select_from(AnomalyFlag))).scalar_one()


async def test_population_and_egregious_outlier(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    normals = [_normal(i) for i in range(8)]
    await _add(sm, *normals, _cheater())

    async with sm() as s:
        n = await detect_anomalies(s, _settings(), now=NOW)
    assert n > 0

    cheat = await _flags_for(sm, "name:CHEAT")
    by_metric = {f.metric: f for f in cheat}
    assert set(by_metric) == {"kd", "headshot_rate", "hit_rate"}
    for f in cheat:
        assert f.status == "open"
        assert f.severity == "high"
        assert f.context["population_median"] is not None
        # 8 identical normals + 1 cheater -> MAD collapses to 0, so pop_thr sits
        # at the (low) median and the absolute floor is the binding threshold.
        assert f.threshold == f.context["absolute_floor"]
        assert f.value >= f.threshold
        assert f.detector_version == ANOMALY_DETECTOR_VERSION

    # A normal profile has zero flags.
    assert await _flags_for(sm, "name:N0") == []


async def test_min_sample_gate(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    # High kd but too few kills/deaths -> not flagged for kd.
    thin_kd = _profile("name:THINKD", kills=2, deaths=1, kd=99.0)
    # hs 1.0 but hits below anomaly_min_hits (40) -> not flagged for headshot_rate.
    thin_hs = _profile("name:THINHS", hits=3, headshots=3)
    await _add(sm, thin_kd, thin_hs)

    async with sm() as s:
        await detect_anomalies(s, _settings(), now=NOW)

    for f in await _flags_for(sm, "name:THINKD"):
        assert f.metric != "kd"
    for f in await _flags_for(sm, "name:THINHS"):
        assert f.metric != "headshot_rate"


async def test_small_population_floor_only(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    # Only 2 qualifying kd profiles (< anomaly_min_population=5).
    over = _profile("name:OVER", kills=50, deaths=5, kd=10.0)   # > floor 4.0
    under = _profile("name:UNDER", kills=15, deaths=5, kd=3.0)  # < floor 4.0
    await _add(sm, over, under)

    async with sm() as s:
        await detect_anomalies(s, _settings(), now=NOW)

    over_flags = await _flags_for(sm, "name:OVER")
    kd_flags = [f for f in over_flags if f.metric == "kd"]
    assert len(kd_flags) == 1
    assert kd_flags[0].context["population_median"] is None
    assert kd_flags[0].threshold == 4.0

    under_kd = [f for f in await _flags_for(sm, "name:UNDER") if f.metric == "kd"]
    assert under_kd == []


async def test_idempotent_rescan(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _add(sm, *[_normal(i) for i in range(8)], _cheater())

    async with sm() as s:
        await detect_anomalies(s, _settings(), now=NOW)
    count1 = await _count(sm)
    kd_id_before = [f for f in await _flags_for(sm, "name:CHEAT")
                    if f.metric == "kd"][0].flag_id

    later = NOW + dt.timedelta(hours=6)
    async with sm() as s:
        await detect_anomalies(s, _settings(), now=later)
    count2 = await _count(sm)

    assert count2 == count1  # no duplicates

    kd = [f for f in await _flags_for(sm, "name:CHEAT") if f.metric == "kd"][0]
    assert kd.created_at == NOW
    assert kd.last_seen_at == later
    assert kd.flag_id == kd_id_before  # in-place update, not delete+reinsert


async def test_no_resurrection_of_triaged_flag(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    await _add(sm, *[_normal(i) for i in range(8)], _cheater())

    async with sm() as s:
        await detect_anomalies(s, _settings(), now=NOW)

    # Reviewer dismisses the cheater's kd flag.
    async with sm() as s:
        kd = (await s.execute(select(AnomalyFlag).where(
            AnomalyFlag.player_key == "name:CHEAT",
            AnomalyFlag.metric == "kd",
        ))).scalar_one()
        kd.status = "dismissed"
        await s.commit()

    later = NOW + dt.timedelta(hours=1)
    async with sm() as s:
        await detect_anomalies(s, _settings(), now=later)

    kd_flags = [f for f in await _flags_for(sm, "name:CHEAT") if f.metric == "kd"]
    assert len(kd_flags) == 1
    assert kd_flags[0].status == "dismissed"


async def test_empty_db(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    async with sm() as s:
        n = await detect_anomalies(s, _settings(), now=NOW)
    assert n == 0
    assert await _count(sm) == 0


async def test_mad_population_threshold_drives_flagging(app_and_sessionmaker):
    """A DISPERSED population must push the effective threshold ABOVE the floor
    via median + k*1.4826*MAD, and that computed threshold — not the floor — must
    be the binding constraint. Guards the MAD formula against regressions
    (dropped 1.4826, wrong sign, MAD-vs-mean, etc.). Uses hit_rate so `value`
    is set directly via overall_hit_rate.
    """
    _, sm = app_and_sessionmaker
    st = _settings()
    # 7 qualifying profiles (>= anomaly_min_population=5), all shots>=100.
    # Spread is tuned so pop_thr lands ABOVE the floor (0.55) and the outlier
    # (0.70) clears it while the "between" player (0.58 > floor) does not.
    hit_rates = {
        "name:C0": 0.30, "name:C1": 0.32, "name:C2": 0.35,
        "name:C3": 0.38, "name:C4": 0.40,
        "name:BETWEEN": 0.58,   # above floor 0.55, below pop_thr -> NOT flagged
        "name:OUT": 0.70,       # above pop_thr -> flagged
    }
    rows = [_profile(k, shots=200, hits=0, hit_rate=v) for k, v in hit_rates.items()]
    await _add(sm, *rows)

    async with sm() as s:
        await detect_anomalies(s, st, now=NOW)

    # Independently reproduce the population statistic the same way the code does.
    values = sorted(hit_rates.values())
    med = statistics.median(values)
    mad = statistics.median([abs(v - med) for v in values])
    pop_thr = med + st.anomaly_mad_k * 1.4826 * mad
    effective = max(st.anomaly_hit_rate_floor, pop_thr)
    # Sanity: the population statistic must have tightened above the floor.
    assert pop_thr > st.anomaly_hit_rate_floor

    # Outlier IS flagged, at the population-derived threshold (not the floor).
    out = [f for f in await _flags_for(sm, "name:OUT") if f.metric == "hit_rate"]
    assert len(out) == 1
    assert out[0].threshold == pytest.approx(effective, abs=1e-4)
    assert out[0].threshold > st.anomaly_hit_rate_floor
    assert out[0].context["population_median"] == pytest.approx(round(med, 4), abs=1e-4)
    assert out[0].context["population_mad"] == pytest.approx(round(mad, 4), abs=1e-4)

    # Player above the FLOOR but below the (higher) pop_thr is NOT flagged —
    # proving the population stat, not the floor, drew the line.
    assert 0.58 > st.anomaly_hit_rate_floor  # would be flagged on a floor-only path
    between = [f for f in await _flags_for(sm, "name:BETWEEN") if f.metric == "hit_rate"]
    assert between == []


async def test_severity_med_and_low_branches(app_and_sessionmaker):
    """Exercise the med ([1.2,1.5)) and low ((1.0,1.2)) severity branches.
    Only 2 qualifying profiles (< anomaly_min_population) so the floor (0.55) is
    the effective threshold, making value/effective easy to pin.
    """
    _, sm = app_and_sessionmaker
    st = _settings()
    floor = st.anomaly_hit_rate_floor  # 0.55
    med_val = 0.70   # 0.70/0.55 = 1.27 -> "med"
    low_val = 0.58   # 0.58/0.55 = 1.05 -> "low"
    await _add(
        sm,
        _profile("name:MED", shots=200, hit_rate=med_val),
        _profile("name:LOW", shots=200, hit_rate=low_val),
    )

    async with sm() as s:
        await detect_anomalies(s, st, now=NOW)

    medf = [f for f in await _flags_for(sm, "name:MED") if f.metric == "hit_rate"][0]
    lowf = [f for f in await _flags_for(sm, "name:LOW") if f.metric == "hit_rate"][0]
    assert medf.threshold == floor and lowf.threshold == floor
    assert 1.2 <= med_val / floor < 1.5
    assert 1.0 < low_val / floor < 1.2
    assert medf.severity == "med"
    assert lowf.severity == "low"


async def test_detector_version_agrees_with_model_default(app_and_sessionmaker):
    _, sm = app_and_sessionmaker
    # The model's hardcoded column default must equal the detector constant.
    assert AnomalyFlag.__table__.c.detector_version.default.arg == ANOMALY_DETECTOR_VERSION
