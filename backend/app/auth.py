import secrets
import time

from fastapi import HTTPException, Request

from app.signing import SignatureStatus, verify


async def require_ingest_token(request: Request) -> None:
    expected = request.app.state.settings.ingest_token
    header = request.headers.get("Authorization", "")
    prefix = "Bearer "
    supplied = header[len(prefix):] if header.startswith(prefix) else ""
    if not supplied or not secrets.compare_digest(supplied, expected):
        raise HTTPException(status_code=401, detail="invalid ingest token")


async def require_valid_signature(request: Request) -> None:
    """M9-P1 (ADR-0011). Verifies the X-BF-* signing envelope over the raw body
    and stashes request.state.ingest_trusted. Rejects a present-but-invalid
    signature (401); rejects unsigned only when require_signed_ingest is set.
    Reading request.body() here caches it, so Pydantic body parsing still works."""
    settings = request.app.state.settings
    body = await request.body()
    result = verify(
        request.headers.get("X-BF-Key-Id"),
        request.headers.get("X-BF-Timestamp"),
        request.headers.get("X-BF-Signature"),
        body,
        settings.signing_key_map(),
        int(time.time()),
        settings.ingest_max_skew_s,
    )
    if result.status == SignatureStatus.INVALID:
        raise HTTPException(status_code=401, detail=f"invalid signature: {result.reason}")
    if result.status == SignatureStatus.UNSIGNED and settings.require_signed_ingest:
        raise HTTPException(status_code=401, detail="signed ingest required")
    request.state.ingest_trusted = result.status == SignatureStatus.TRUSTED
