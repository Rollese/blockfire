import secrets

from fastapi import HTTPException, Request


async def require_ingest_token(request: Request) -> None:
    expected = request.app.state.settings.ingest_token
    header = request.headers.get("Authorization", "")
    prefix = "Bearer "
    supplied = header[len(prefix):] if header.startswith(prefix) else ""
    if not supplied or not secrets.compare_digest(supplied, expected):
        raise HTTPException(status_code=401, detail="invalid ingest token")
