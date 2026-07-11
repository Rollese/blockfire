"""Admin auth guard: gate admin-only routes behind an allowlisted SteamID.

Two modes, controlled by Settings:
  - admin_dev_open=True: admin routes are open to anyone, no Steam auth
    required. dev/LAN only — MUST stay False in any internet-facing deploy.
  - admin_dev_open=False (default): the caller must have a valid `bf_session`
    cookie (see app.steam_openid) whose steam_id is in admin_steam_id_set().

No DB access here — purely cookie + config based, so it's cheap to call on
every admin request.
"""

from fastapi import HTTPException, Request

from app.steam_openid import current_steam_id


def is_admin(request: Request) -> bool:
    settings = request.app.state.settings
    if settings.admin_dev_open:
        return True
    steam_id = current_steam_id(request)
    return steam_id is not None and steam_id in settings.admin_steam_id_set()


def require_admin(request: Request) -> None:
    """FastAPI dependency: raises 403 unless the caller is an admin."""
    if not is_admin(request):
        raise HTTPException(status_code=403, detail="admin access required")
