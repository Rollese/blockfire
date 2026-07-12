import hashlib
import hmac
from dataclasses import dataclass
from enum import Enum


class SignatureStatus(Enum):
    TRUSTED = "trusted"    # valid signature from a configured key
    UNSIGNED = "unsigned"  # no X-BF-* headers present at all
    INVALID = "invalid"    # present but wrong / unknown / stale / partial


@dataclass(frozen=True)
class SignatureResult:
    status: SignatureStatus
    reason: str = ""


def parse_signing_keys(raw: str) -> dict[str, str]:
    """Parse 'key_id:secret key_id2:secret2' (space/comma separated) into a map.

    Skips malformed tokens (no colon, empty id, or empty secret) rather than
    raising, so a deploy-time typo in INGEST_SIGNING_KEYS can't crash startup
    (mirrors config.admin_steam_id_set)."""
    out: dict[str, str] = {}
    for token in raw.replace(",", " ").split():
        key_id, sep, secret = token.partition(":")
        if not sep or not key_id or not secret:
            continue
        out[key_id] = secret
    return out


def compute_signature(secret: str, key_id: str, timestamp: str, body: bytes) -> str:
    """Lowercase-hex HMAC-SHA256 of key_id + "\n" + timestamp + "\n" + body.
    `timestamp` is the ASCII decimal string exactly as it appears on the wire."""
    msg = key_id.encode("utf-8") + b"\n" + timestamp.encode("utf-8") + b"\n" + body
    return hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def verify(key_id: str | None, timestamp: str | None, signature: str | None,
           body: bytes, keys: dict[str, str], now: int, max_skew_s: int) -> SignatureResult:
    """Pure verification. No FastAPI/DB coupling; `now` is injected (int unix s)."""
    supplied = [h for h in (key_id, timestamp, signature) if h]
    if not supplied:
        return SignatureResult(SignatureStatus.UNSIGNED)
    if not (key_id and timestamp and signature):
        return SignatureResult(SignatureStatus.INVALID, "partial signing headers")
    secret = keys.get(key_id)
    if secret is None:
        return SignatureResult(SignatureStatus.INVALID, "unknown key_id")
    try:
        ts = int(timestamp)
    except ValueError:
        return SignatureResult(SignatureStatus.INVALID, "non-integer timestamp")
    if abs(now - ts) > max_skew_s:
        return SignatureResult(SignatureStatus.INVALID, "timestamp out of window")
    expected = compute_signature(secret, key_id, timestamp, body)
    if not hmac.compare_digest(expected, signature):
        return SignatureResult(SignatureStatus.INVALID, "signature mismatch")
    return SignatureResult(SignatureStatus.TRUSTED)
