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


class IngestedBatch(Base):
    __tablename__ = "ingested_batches"
    # Plain String, no FK to matches.match_id: batch rows are recorded during
    # mid-match /ingest/events POSTs, before the matches row exists (spec §5).
    match_id: Mapped[str] = mapped_column(String, primary_key=True)
    batch_seq: Mapped[int] = mapped_column(Integer, primary_key=True)
