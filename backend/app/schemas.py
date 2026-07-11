import datetime as dt

from pydantic import BaseModel, Field


class EventIn(BaseModel):
    tick: int
    type: str
    actor: str | None = None
    target: str | None = None
    weapon_id: str | None = None
    payload: dict = Field(default_factory=dict)


class EventBatchIn(BaseModel):
    match_id: str
    batch_seq: int = Field(ge=0)
    events: list[EventIn]


class WeaponStatIn(BaseModel):
    weapon_id: str
    shots: int = 0
    hits: int = 0
    kills: int = 0
    headshots: int = 0
    damage: int = 0
    time_used_s: int = 0


class PlayerReportIn(BaseModel):
    name: str
    steam_id: int | None = None
    team: str = ""
    kills: int = 0
    deaths: int = 0
    assists: int = 0
    downs: int = 0
    revives: int = 0
    captures: int = 0
    neutralizes: int = 0
    xp_earned: int = 0
    longest_kill_m: float = 0.0
    playtime_s: int = 0
    result: str = ""
    weapons: list[WeaponStatIn] = Field(default_factory=list)


class MatchMetaIn(BaseModel):
    match_id: str
    server_id: str
    map: str
    mode: str
    started_at: dt.datetime | None = None
    ended_at: dt.datetime | None = None
    winner: str | None = None


class MatchReportIn(BaseModel):
    report_version: int = 1
    match: MatchMetaIn
    players: list[PlayerReportIn]
