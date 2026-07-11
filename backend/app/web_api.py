"""Public (no-auth) JSON API consuming the profiles read layer.

Routes are read-only rollup views: a leaderboard and a per-player profile
(with weapon totals + recent matches). player_key values contain a colon
(e.g. "name:BotAlpha"), so the profile route uses the {player_key:path}
converter to keep the colon in one path segment.
"""

from fastapi import FastAPI, HTTPException, Request

_LEADERBOARD_MAX = 200


def register_api_routes(app: FastAPI) -> None:
    from app.profiles import (  # local import avoids import cycle
        get_profile, get_recent_matches, get_weapon_totals, list_leaderboard,
    )

    @app.get("/api/leaderboard")
    async def leaderboard(request: Request, sort: str = "kills",
                          limit: int = 50) -> dict:
        limit = max(1, min(limit, _LEADERBOARD_MAX))
        sm = request.app.state.sessionmaker
        async with sm() as session:
            players = await list_leaderboard(session, limit=limit, sort=sort)
        return {"players": players}

    @app.get("/api/players/{player_key:path}")
    async def player_profile(player_key: str, request: Request) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            profile = await get_profile(session, player_key)
            if profile is None:
                raise HTTPException(status_code=404, detail="player not found")
            weapons = await get_weapon_totals(session, player_key)
            recent = await get_recent_matches(session, player_key)
        return {**profile, "weapons": weapons, "recent_matches": recent}
