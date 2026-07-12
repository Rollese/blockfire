import datetime as dt

from sqlalchemy.ext.asyncio import AsyncSession

from app.identity import player_key
from app.models import Event, IngestedBatch, Match, MatchPlayer, MatchPlayerWeapon, Player
from app.schemas import EventBatchIn, MatchReportIn


async def ingest_event_batch(session: AsyncSession, batch: EventBatchIn) -> bool:
    """Insert a batch's events. Returns False (and writes nothing) if this
    (match_id, batch_seq) was already ingested. Idempotent.

    Idempotency assumes a single writer per match: the check-then-insert on
    (match_id, batch_seq) is not DB-atomic, so truly concurrent duplicate POSTs
    could collide on the ingested_batches PK. Acceptable because the game-server
    StatsReporter retries/drains NDJSON sequentially (spec §5)."""
    already = await session.get(IngestedBatch, (batch.match_id, batch.batch_seq))
    if already is not None:
        return False
    now = dt.datetime.now(dt.timezone.utc)
    for ev in batch.events:
        session.add(Event(
            match_id=batch.match_id, tick=ev.tick, type=ev.type,
            actor_key=ev.actor, target_key=ev.target, weapon_id=ev.weapon_id,
            payload=ev.payload, created_at=now,
        ))
    session.add(IngestedBatch(match_id=batch.match_id, batch_seq=batch.batch_seq))
    await session.commit()
    return True


async def _upsert_player(session: AsyncSession, key: str, steam_id: int | None,
                         name: str, now: dt.datetime) -> None:
    existing = await session.get(Player, key)
    if existing is None:
        session.add(Player(player_key=key, steam_id=steam_id or None, name=name,
                           first_seen=now, last_seen=now))
    else:
        existing.last_seen = now
        if steam_id:
            existing.steam_id = steam_id


async def ingest_match_report(session: AsyncSession, report: MatchReportIn,
                              trusted: bool = False) -> None:
    """Upsert the match, its players, per-player summaries and per-weapon
    counters. `trusted` records whether the POST carried a valid official
    signature (ADR-0011). Idempotent: re-POSTing the same match overwrites the summary.

    P1 limitation: this overwrites/inserts only rows present in the incoming
    report; it does NOT delete stale MatchPlayer/MatchPlayerWeapon rows from a
    prior report. Acceptable because reports are POSTed once at match end and
    NDJSON replay re-POSTs the identical report (spec §4/§5), so rosters never
    shrink."""
    now = dt.datetime.now(dt.timezone.utc)
    m = report.match
    duration = None
    if m.started_at and m.ended_at:
        duration = int((m.ended_at - m.started_at).total_seconds())

    match_row = await session.get(Match, m.match_id)
    if match_row is None:
        match_row = Match(match_id=m.match_id)
        session.add(match_row)
    match_row.server_id = m.server_id
    match_row.map = m.map
    match_row.mode = m.mode
    match_row.started_at = m.started_at
    match_row.ended_at = m.ended_at
    match_row.duration_s = duration
    match_row.winner = m.winner
    match_row.report_version = report.report_version
    match_row.complete = True
    match_row.ingested_at = now
    match_row.trusted = trusted

    for p in report.players:
        key = player_key(p.steam_id, p.name)
        await _upsert_player(session, key, p.steam_id, p.name, now)
        mp = await session.get(MatchPlayer, (m.match_id, key))
        if mp is None:
            mp = MatchPlayer(match_id=m.match_id, player_key=key)
            session.add(mp)
        mp.team = p.team
        mp.kills, mp.deaths, mp.assists = p.kills, p.deaths, p.assists
        mp.downs, mp.revives = p.downs, p.revives
        mp.captures, mp.neutralizes = p.captures, p.neutralizes
        mp.xp_earned, mp.longest_kill_m = p.xp_earned, p.longest_kill_m
        mp.playtime_s, mp.result = p.playtime_s, p.result
        for w in p.weapons:
            mpw = await session.get(MatchPlayerWeapon, (m.match_id, key, w.weapon_id))
            if mpw is None:
                mpw = MatchPlayerWeapon(match_id=m.match_id, player_key=key, weapon_id=w.weapon_id)
                session.add(mpw)
            mpw.shots, mpw.hits, mpw.kills = w.shots, w.hits, w.kills
            mpw.headshots, mpw.damage, mpw.time_used_s = w.headshots, w.damage, w.time_used_s
    await session.commit()
