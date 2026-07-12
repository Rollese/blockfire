class_name StatsSigner
extends RefCounted

# Server-only. Pure HMAC-SHA256 signer for the M9-P1 ingest envelope (ADR-0011).
# Signing string = key_id + "\n" + str(timestamp) + "\n" + <raw body bytes>.
# Mirrors backend app/signing.py::compute_signature byte-for-byte (golden vector
# asserted in both tests/stats_signer_test.gd and backend/tests/test_signing.py).

static func sign(key_id: String, secret: String, timestamp: int, body: PackedByteArray) -> String:
	if secret.is_empty():
		return ""
	var ctx := HMACContext.new()
	if ctx.start(HashingContext.HASH_SHA256, secret.to_utf8_buffer()) != OK:
		return ""
	ctx.update((key_id + "\n" + str(timestamp) + "\n").to_utf8_buffer())
	ctx.update(body)
	return ctx.finish().hex_encode()

static func headers(key_id: String, timestamp: int, signature: String) -> PackedStringArray:
	return PackedStringArray([
		"X-BF-Key-Id: %s" % key_id,
		"X-BF-Timestamp: %d" % timestamp,
		"X-BF-Signature: %s" % signature,
	])
