from app.signing import (
    SignatureStatus, compute_signature, parse_signing_keys, verify,
)

SECRET = "test-secret"
KEY_ID = "game2-dev-1"
TS = 1752307200
BODY = b'{"match_id":"m-golden","batch_seq":0,"events":[]}'
GOLDEN = "a25a99340ae1d0bb369662ea87f2a536d19588292d856a35ec2f3395e1169585"
KEYS = {KEY_ID: SECRET}


def test_golden_vector():
    assert compute_signature(SECRET, KEY_ID, str(TS), BODY) == GOLDEN


def test_parse_signing_keys_space_and_comma():
    m = parse_signing_keys("a:sa, b:sb  c:sc")
    assert m == {"a": "sa", "b": "sb", "c": "sc"}


def test_parse_signing_keys_skips_malformed():
    assert parse_signing_keys("nocolon :sx x:  a:sa") == {"a": "sa"}


def test_verify_trusted():
    r = verify(KEY_ID, str(TS), GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.TRUSTED


def test_verify_unsigned_when_no_headers():
    r = verify(None, None, None, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.UNSIGNED


def test_verify_invalid_partial_headers():
    r = verify(KEY_ID, None, GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_unknown_key():
    r = verify("nope", str(TS), GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_bad_signature():
    r = verify(KEY_ID, str(TS), "0" * 64, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_stale_timestamp():
    r = verify(KEY_ID, str(TS), GOLDEN, BODY, KEYS, now=TS + 3600, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_invalid_noninteger_timestamp():
    r = verify(KEY_ID, "not-a-number", GOLDEN, BODY, KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID


def test_verify_body_tamper_fails():
    r = verify(KEY_ID, str(TS), GOLDEN, BODY + b" ", KEYS, now=TS, max_skew_s=300)
    assert r.status == SignatureStatus.INVALID
