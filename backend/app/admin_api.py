"""Admin-only JSON API over the admin_stats read layer.

Every route requires `require_admin` (see app.admin_auth): either
`settings.admin_dev_open` is True (dev/LAN only) or the caller's
`bf_session` cookie carries an allowlisted steam_id. All routes are
read-only thin wrappers -- no aggregation logic lives here, only wiring.
"""

from fastapi import Depends, FastAPI, Request

from app.admin_auth import require_admin


def register_admin_api_routes(app: FastAPI) -> None:
    from app.admin_stats import (  # local import avoids import cycle
        hitzone_breakdown, kill_distance_stats, longest_kills,
        query_kill_events, weapon_balance, weapon_outliers,
    )

    @app.get("/admin/api/weapons", dependencies=[Depends(require_admin)])
    async def admin_weapons(request: Request) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            weapons = await weapon_balance(session)
        return {"weapons": weapons}

    @app.get("/admin/api/combat", dependencies=[Depends(require_admin)])
    async def admin_combat(request: Request) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            kill_distance = await kill_distance_stats(session)
            hitzone = await hitzone_breakdown(session)
            longest = await longest_kills(session)
        return {
            "kill_distance": kill_distance,
            "hitzone": hitzone,
            "longest_kills": longest,
        }

    @app.get("/admin/api/events", dependencies=[Depends(require_admin)])
    async def admin_events(
        request: Request,
        weapon_id: str | None = None,
        min_distance_m: float | None = None,
        hitzone: str | None = None,
        order: str = "distance",
        limit: int = 50,
    ) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            events = await query_kill_events(
                session, weapon_id=weapon_id, min_distance_m=min_distance_m,
                hitzone=hitzone, order=order, limit=limit,
            )
        return {"events": events}

    @app.get("/admin/api/outliers", dependencies=[Depends(require_admin)])
    async def admin_outliers(request: Request) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            weapons = await weapon_outliers(session)
        return {"weapons": weapons}
