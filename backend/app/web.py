"""Server-rendered HTML pages (Jinja2): leaderboard index + player profile.

Static assets are mounted at /static; templates live in app/templates. player_key
values contain a colon (e.g. "name:BotAlpha") so the profile route uses the
{player_key:path} converter to keep the colon in one path segment.
"""

import pathlib

from fastapi import FastAPI, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

_HERE = pathlib.Path(__file__).parent


def register_web_routes(app: FastAPI) -> None:
    from app.profiles import (  # local import avoids import cycle
        get_profile, get_recent_matches, get_weapon_totals, list_leaderboard,
    )
    from app.steam_openid import current_steam_id

    templates = Jinja2Templates(directory=str(_HERE / "templates"))
    app.mount("/static", StaticFiles(directory=str(_HERE / "static")),
              name="static")

    @app.get("/")
    async def index(request: Request):
        sm = request.app.state.sessionmaker
        async with sm() as session:
            players = await list_leaderboard(session, limit=50, sort="kills")
        return templates.TemplateResponse(
            request, "index.html",
            {"players": players,
             "current_steam_id": current_steam_id(request)},
        )

    @app.get("/players/{player_key:path}")
    async def profile(player_key: str, request: Request):
        sm = request.app.state.sessionmaker
        async with sm() as session:
            prof = await get_profile(session, player_key)
            if prof is None:
                raise HTTPException(status_code=404, detail="player not found")
            weapons = await get_weapon_totals(session, player_key)
            recent = await get_recent_matches(session, player_key)
        return templates.TemplateResponse(
            request, "profile.html",
            {"profile": prof, "weapons": weapons, "recent_matches": recent,
             "current_steam_id": current_steam_id(request)},
        )
