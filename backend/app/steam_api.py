"""Optional Steam Web API profile enrichment.

Populates player_profiles.display_name + avatar_url from Steam's
GetPlayerSummaries for rows that carry a real steam_id. All current
production data is name:-keyed (steam_id NULL), so this is dormant but must
be correct: with no api_key configured it is a strict no-op (no network,
no commit).
"""

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import PlayerProfile

_SUMMARIES_URL = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/"
_BATCH = 100


async def fetch_summaries(
    client: httpx.AsyncClient, api_key: str, steam_ids: list[int]
) -> dict[int, dict]:
    """Fetch player summaries from Steam, chunking into batches of <=100.

    Returns {steam_id: {"display_name", "avatar_url"}}. Missing / private
    accounts are simply absent from Steam's response and thus from the map.
    Empty input performs no request and returns {}.
    """
    out: dict[int, dict] = {}
    for i in range(0, len(steam_ids), _BATCH):
        chunk = steam_ids[i:i + _BATCH]
        resp = await client.get(
            _SUMMARIES_URL,
            params={"key": api_key, "steamids": ",".join(str(s) for s in chunk)},
        )
        resp.raise_for_status()
        players = (resp.json().get("response") or {}).get("players") or []
        for p in players:
            sid = p.get("steamid")
            if sid is None:
                continue
            out[int(sid)] = {
                "display_name": p.get("personaname"),
                "avatar_url": p.get("avatarfull"),
            }
    return out


async def enrich_profiles(
    session: AsyncSession,
    api_key: str | None,
    client: httpx.AsyncClient | None = None,
) -> int:
    """Enrich player_profiles that have a steam_id via the Steam Web API.

    Updates display_name + avatar_url on each matching profile and commits.
    Returns the count of profiles enriched. No key -> strict no-op (0, no
    network, no commit). An injected `client` is used for tests; otherwise one
    is created internally.
    """
    if not api_key:
        return 0

    profiles = (await session.execute(
        select(PlayerProfile).where(PlayerProfile.steam_id.is_not(None))
    )).scalars().all()
    if not profiles:
        return 0

    steam_ids = [p.steam_id for p in profiles]

    if client is None:
        async with httpx.AsyncClient() as c:
            summaries = await fetch_summaries(c, api_key, steam_ids)
    else:
        summaries = await fetch_summaries(client, api_key, steam_ids)

    count = 0
    for prof in profiles:
        data = summaries.get(prof.steam_id)
        if data is None:
            continue
        if data.get("display_name") is not None:
            prof.display_name = data["display_name"]
        if data.get("avatar_url") is not None:
            prof.avatar_url = data["avatar_url"]
        count += 1

    await session.commit()
    return count
