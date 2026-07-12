"""Admin-only JSON API over the admin_stats read layer.

Every route requires `require_admin` (see app.admin_auth): either
`settings.admin_dev_open` is True (dev/LAN only) or the caller's
`bf_session` cookie carries an allowlisted steam_id. All routes are
read-only thin wrappers -- no aggregation logic lives here, only wiring.
"""

from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel

from app.admin_auth import require_admin


class ReviewBody(BaseModel):
    status: str
    notes: str | None = None


def register_admin_api_routes(app: FastAPI) -> None:
    from app.admin_stats import (  # local import avoids import cycle
        hitzone_breakdown, kill_distance_stats, longest_kills,
        query_kill_events, weapon_balance, weapon_outliers,
    )
    from app.anomaly import (
        detect_anomalies, flag_summary, list_flags, set_flag_status,
    )
    from app.rating_read import leaderboard, rating_summary

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

    @app.get("/admin/api/anomalies", dependencies=[Depends(require_admin)])
    async def admin_anomalies(
        request: Request,
        status: str | None = None,
        metric: str | None = None,
        limit: int = 100,
    ) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            flags = await list_flags(session, status=status, metric=metric,
                                     limit=limit)
            summary = await flag_summary(session)
        return {"flags": flags, "summary": summary}

    @app.get("/admin/api/ratings", dependencies=[Depends(require_admin)])
    async def admin_ratings(
        request: Request, limit: int = 100, offset: int = 0,
    ) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            rows = await leaderboard(session, limit=limit, offset=offset)
        return {"players": [
            {
                "player_key": r.player_key, "mu": r.mu, "sigma": r.sigma,
                "ordinal": r.ordinal, "tier": r.tier,
                "matches_rated": r.matches_rated,
                "last_match_id": r.last_match_id,
            }
            for r in rows
        ]}

    @app.get("/admin/api/ratings/summary",
             dependencies=[Depends(require_admin)])
    async def admin_ratings_summary(request: Request) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            return await rating_summary(session)

    @app.post("/admin/api/anomaly/scan", dependencies=[Depends(require_admin)])
    async def admin_anomaly_scan(request: Request) -> dict:
        sm = request.app.state.sessionmaker
        async with sm() as session:
            written = await detect_anomalies(session, request.app.state.settings)
        return {"written": written}

    @app.post("/admin/api/anomalies/{flag_id}/review",
              dependencies=[Depends(require_admin)])
    async def admin_anomaly_review(
        request: Request, flag_id: int, body: ReviewBody,
    ) -> dict:
        from app.steam_openid import current_steam_id

        sm = request.app.state.sessionmaker
        steam_id = current_steam_id(request)
        reviewed_by = str(steam_id) if steam_id is not None else "dev"
        try:
            async with sm() as session:
                updated = await set_flag_status(
                    session, flag_id, body.status,
                    reviewed_by=reviewed_by, notes=body.notes,
                )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        if updated is None:
            raise HTTPException(status_code=404, detail="anomaly flag not found")
        return {"flag": updated}
