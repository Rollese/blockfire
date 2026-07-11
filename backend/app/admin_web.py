"""Admin-only server-rendered HTML dashboards (Jinja2): overview, combat
analytics, and a kill-event filter explorer.

Every route requires `require_admin` (see app.admin_auth): either
`settings.admin_dev_open` is True (dev/LAN only) or the caller's
`bf_session` cookie carries an allowlisted steam_id. Templates extend
`admin_base.html`, which itself extends the public `base.html` (reusing its
nav/CSS) and adds an admin sub-nav. All routes are read-only thin wrappers
over `app.admin_stats` -- no aggregation logic lives here, only wiring.

`/static` is already mounted by `app.web.register_web_routes`, so this
module does NOT mount it again -- it only builds its own `Jinja2Templates`
instance pointed at the same `app/templates` directory.
"""

import pathlib

from fastapi import Depends, FastAPI, Request
from fastapi.templating import Jinja2Templates

from app.admin_auth import require_admin

_HERE = pathlib.Path(__file__).parent


def register_admin_web_routes(app: FastAPI) -> None:
    from app.admin_stats import (  # local import avoids import cycle
        admin_summary, hitzone_breakdown, kill_distance_stats, longest_kills,
        query_kill_events, weapon_balance,
    )
    from app.steam_openid import current_steam_id

    templates = Jinja2Templates(directory=str(_HERE / "templates"))

    @app.get("/admin", dependencies=[Depends(require_admin)])
    async def admin_dashboard(request: Request):
        sm = request.app.state.sessionmaker
        async with sm() as session:
            weapons = await weapon_balance(session)
            summary = await admin_summary(session)
        return templates.TemplateResponse(
            request, "admin_index.html",
            {"weapons": weapons, "summary": summary,
             "current_steam_id": current_steam_id(request)},
        )

    @app.get("/admin/combat", dependencies=[Depends(require_admin)])
    async def admin_combat_page(request: Request):
        sm = request.app.state.sessionmaker
        async with sm() as session:
            kill_distance = await kill_distance_stats(session)
            hitzone = await hitzone_breakdown(session)
            longest = await longest_kills(session)
        max_bucket = max((b["count"] for b in kill_distance["histogram"]), default=0)
        return templates.TemplateResponse(
            request, "admin_combat.html",
            {"kill_distance": kill_distance, "hitzone": hitzone,
             "longest_kills": longest, "max_bucket": max_bucket,
             "current_steam_id": current_steam_id(request)},
        )

    @app.get("/admin/events", dependencies=[Depends(require_admin)])
    async def admin_events_page(
        request: Request,
        weapon_id: str | None = None,
        min_distance_m: float | None = None,
        hitzone: str | None = None,
        order: str = "distance",
        limit: int = 50,
    ):
        sm = request.app.state.sessionmaker
        async with sm() as session:
            events = await query_kill_events(
                session, weapon_id=weapon_id, min_distance_m=min_distance_m,
                hitzone=hitzone, order=order, limit=limit,
            )
        filters = {
            "weapon_id": weapon_id, "min_distance_m": min_distance_m,
            "hitzone": hitzone, "order": order, "limit": limit,
        }
        return templates.TemplateResponse(
            request, "admin_events.html",
            {"events": events, "filters": filters,
             "current_steam_id": current_steam_id(request)},
        )
