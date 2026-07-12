import datetime as dt

from sqlalchemy import BigInteger, Boolean, DateTime, Float, ForeignKey, Integer, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Player(Base):
    __tablename__ = "players"
    player_key: Mapped[str] = mapped_column(String, primary_key=True)
    steam_id: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    name: Mapped[str | None] = mapped_column(String, nullable=True)
    first_seen: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    last_seen: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))


class Match(Base):
    __tablename__ = "matches"
    match_id: Mapped[str] = mapped_column(String, primary_key=True)
    server_id: Mapped[str] = mapped_column(String)
    map: Mapped[str] = mapped_column(String)
    mode: Mapped[str] = mapped_column(String)
    started_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ended_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    duration_s: Mapped[int | None] = mapped_column(Integer, nullable=True)
    winner: Mapped[str | None] = mapped_column(String, nullable=True)
    report_version: Mapped[int] = mapped_column(Integer, default=1)
    complete: Mapped[bool] = mapped_column(Boolean, default=False)
    ingested_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))


class MatchPlayer(Base):
    __tablename__ = "match_players"
    match_id: Mapped[str] = mapped_column(ForeignKey("matches.match_id"), primary_key=True)
    player_key: Mapped[str] = mapped_column(ForeignKey("players.player_key"), primary_key=True)
    team: Mapped[str] = mapped_column(String, default="")
    kills: Mapped[int] = mapped_column(Integer, default=0)
    deaths: Mapped[int] = mapped_column(Integer, default=0)
    assists: Mapped[int] = mapped_column(Integer, default=0)
    downs: Mapped[int] = mapped_column(Integer, default=0)
    revives: Mapped[int] = mapped_column(Integer, default=0)
    captures: Mapped[int] = mapped_column(Integer, default=0)
    neutralizes: Mapped[int] = mapped_column(Integer, default=0)
    xp_earned: Mapped[int] = mapped_column(Integer, default=0)
    longest_kill_m: Mapped[float] = mapped_column(Float, default=0.0)
    playtime_s: Mapped[int] = mapped_column(Integer, default=0)
    result: Mapped[str] = mapped_column(String, default="")


class MatchPlayerWeapon(Base):
    __tablename__ = "match_player_weapons"
    match_id: Mapped[str] = mapped_column(ForeignKey("matches.match_id"), primary_key=True)
    player_key: Mapped[str] = mapped_column(ForeignKey("players.player_key"), primary_key=True)
    weapon_id: Mapped[str] = mapped_column(String, primary_key=True)
    shots: Mapped[int] = mapped_column(Integer, default=0)
    hits: Mapped[int] = mapped_column(Integer, default=0)
    kills: Mapped[int] = mapped_column(Integer, default=0)
    headshots: Mapped[int] = mapped_column(Integer, default=0)
    damage: Mapped[int] = mapped_column(Integer, default=0)
    time_used_s: Mapped[int] = mapped_column(Integer, default=0)


class Event(Base):
    __tablename__ = "events"
    event_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    # Plain String, no FK to matches.match_id: events are POSTed via /ingest/events
    # DURING the match, before the /ingest/match summary creates the matches row
    # (spec §5), so an FK would reject legitimate mid-match event ingestion.
    match_id: Mapped[str] = mapped_column(String, index=True)
    tick: Mapped[int] = mapped_column(Integer)
    type: Mapped[str] = mapped_column(String, index=True)
    actor_key: Mapped[str | None] = mapped_column(String, nullable=True)
    target_key: Mapped[str | None] = mapped_column(String, nullable=True)
    weapon_id: Mapped[str | None] = mapped_column(String, nullable=True)
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)


class PlayerProfile(Base):
    __tablename__ = "player_profiles"
    # Derived rollup table: no FK to players, kept decoupled like `events`.
    player_key: Mapped[str] = mapped_column(String, primary_key=True)
    steam_id: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    display_name: Mapped[str | None] = mapped_column(String, nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String, nullable=True)
    total_kills: Mapped[int] = mapped_column(Integer, default=0)
    total_deaths: Mapped[int] = mapped_column(Integer, default=0)
    total_assists: Mapped[int] = mapped_column(Integer, default=0)
    total_downs: Mapped[int] = mapped_column(Integer, default=0)
    total_revives: Mapped[int] = mapped_column(Integer, default=0)
    total_captures: Mapped[int] = mapped_column(Integer, default=0)
    total_neutralizes: Mapped[int] = mapped_column(Integer, default=0)
    wins: Mapped[int] = mapped_column(Integer, default=0)
    losses: Mapped[int] = mapped_column(Integer, default=0)
    matches_played: Mapped[int] = mapped_column(Integer, default=0)
    xp_total: Mapped[int] = mapped_column(Integer, default=0)
    kd_ratio: Mapped[float] = mapped_column(Float, default=0.0)
    total_shots: Mapped[int] = mapped_column(Integer, default=0)
    total_hits: Mapped[int] = mapped_column(Integer, default=0)
    total_headshots: Mapped[int] = mapped_column(Integer, default=0)
    overall_hit_rate: Mapped[float] = mapped_column(Float, default=0.0)
    longest_kill_m: Mapped[float] = mapped_column(Float, default=0.0)
    favorite_weapon_id: Mapped[str | None] = mapped_column(String, nullable=True)
    total_playtime_s: Mapped[int] = mapped_column(Integer, default=0)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))


class PlayerWeaponTotal(Base):
    __tablename__ = "player_weapon_totals"
    # Derived rollup table: no FK, decoupled like `events`.
    player_key: Mapped[str] = mapped_column(String, primary_key=True)
    weapon_id: Mapped[str] = mapped_column(String, primary_key=True)
    shots: Mapped[int] = mapped_column(Integer, default=0)
    hits: Mapped[int] = mapped_column(Integer, default=0)
    kills: Mapped[int] = mapped_column(Integer, default=0)
    headshots: Mapped[int] = mapped_column(Integer, default=0)
    damage: Mapped[int] = mapped_column(Integer, default=0)
    time_used_s: Mapped[int] = mapped_column(Integer, default=0)
    matches_used: Mapped[int] = mapped_column(Integer, default=0)


class AnomalyFlag(Base):
    __tablename__ = "anomaly_flags"
    # Additive P4 review-queue table: no FK, decoupled like `events`/`player_profiles`.
    flag_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    player_key: Mapped[str] = mapped_column(String, index=True)
    metric: Mapped[str] = mapped_column(String, index=True)  # "kd" | "headshot_rate" | "hit_rate"
    value: Mapped[float] = mapped_column(Float)
    threshold: Mapped[float] = mapped_column(Float)
    sample_size: Mapped[int] = mapped_column(Integer)
    severity: Mapped[str] = mapped_column(String)  # "low" | "med" | "high"
    status: Mapped[str] = mapped_column(String, index=True, default="open")  # "open" | "confirmed" | "dismissed"
    # keep in sync with app.anomaly.ANOMALY_DETECTOR_VERSION (Task 2)
    detector_version: Mapped[int] = mapped_column(Integer, default=1)
    context: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)
    last_seen_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    reviewed_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reviewed_by: Mapped[str | None] = mapped_column(String, nullable=True)
    notes: Mapped[str | None] = mapped_column(String, nullable=True)


class IngestedBatch(Base):
    __tablename__ = "ingested_batches"
    # Plain String, no FK to matches.match_id: batch rows are recorded during
    # mid-match /ingest/events POSTs, before the matches row exists (spec §5).
    match_id: Mapped[str] = mapped_column(String, primary_key=True)
    batch_seq: Mapped[int] = mapped_column(Integer, primary_key=True)
