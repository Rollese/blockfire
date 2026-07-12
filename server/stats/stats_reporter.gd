class_name StatsReporter
extends Node

# Server-only. Owns a StatsBuffer + StatsSpool + an HTTPRequest child. Flushes
# event batches (~1 Hz) and the final match report to the P1-A ingest API;
# spools failed POSTs to NDJSON and drains them on the next success.

const Buffer := preload("res://server/stats/stats_buffer.gd")
const Spool := preload("res://server/stats/stats_spool.gd")

var buffer: Buffer = Buffer.new()

var _endpoint: String = ""
var _token: String = ""
var _spool: Spool = Spool.new()
var _http: HTTPRequest
var _inflight: bool = false
var _signing_key_id: String = ""
var _signing_secret: String = ""

static func weapon_key(weapon_id: int) -> String:
	return String(Weapon.get_def(weapon_id).get("name", "unknown")).to_lower()

func configure(endpoint: String, token: String, spool_path: String = "user://stats_spool.ndjson",
		signing_key_id: String = "", signing_secret: String = "") -> void:
	_endpoint = endpoint.rstrip("/")
	_token = token
	_spool = Spool.new(spool_path)
	_signing_key_id = signing_key_id
	_signing_secret = signing_secret

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

# --- serialization passthroughs used by server_main taps ---
func begin_match(match_id: String, server_id: String, map_name: String, mode: String) -> void:
	buffer.begin_match(match_id, server_id, map_name, mode)

# --- flushing ---
func flush_events() -> void:
	var batch := buffer.take_event_batch()
	if batch.is_empty():
		return
	_post("/ingest/events", batch)

func end_match(winner_team: int, elapsed_s: int, started_at: String, ended_at: String) -> void:
	buffer.set_results(winner_team)
	flush_events()  # drain any remaining events first
	_post("/ingest/match", buffer.build_match_report(started_at, ended_at))

func _post(path: String, body: Dictionary) -> void:
	if _endpoint.is_empty():
		return
	# Best-effort: if a request is already inflight, spool rather than block the tick.
	if _inflight:
		_spool.append({"path": path, "body": body})
		return
	_drain_spool_then(path, body)

func _drain_spool_then(path: String, body: Dictionary) -> void:
	# Re-send anything previously spooled, oldest first, then the new payload.
	var pending := _spool.read_all()
	pending.append({"path": path, "body": body})
	_spool.clear()
	_send_queue(pending)

var _queue: Array = []
func _send_queue(items: Array) -> void:
	_queue = items
	_send_next()

func _build_headers(body_str: String) -> PackedStringArray:
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % _token,
		"Content-Type: application/json",
	])
	# M9-P1 (ADR-0011): sign the EXACT bytes we transmit so the backend verifies
	# against the same body it receives. No signing config -> unsigned (backward
	# compatible; ingested as trusted=false).
	if not _signing_key_id.is_empty() and not _signing_secret.is_empty():
		var ts := int(Time.get_unix_time_from_system())
		var sig := StatsSigner.sign(_signing_key_id, _signing_secret, ts, body_str.to_utf8_buffer())
		if not sig.is_empty():
			headers.append_array(StatsSigner.headers(_signing_key_id, ts, sig))
	return headers

func _send_next() -> void:
	if _queue.is_empty():
		return
	var item: Dictionary = _queue[0]
	var body_str := JSON.stringify(item["body"])
	var headers := _build_headers(body_str)
	_inflight = true
	var err := _http.request(_endpoint + String(item["path"]), headers,
		HTTPClient.METHOD_POST, body_str)
	if err != OK:
		_inflight = false
		# Transport could not even start — spool the whole queue and give up for now.
		for it in _queue:
			_spool.append(it)
		_queue = []

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_inflight = false
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	if not ok:
		# Failed — spool this item and the rest of the queue for a later retry.
		for it in _queue:
			_spool.append(it)
		_queue = []
		return
	_queue.pop_front()
	if not _queue.is_empty():
		_send_next()
		return
	# Queue drained. Pick up anything spooled while we were inflight — e.g. the
	# final match report deferred by end_match, or events diverted mid-flight —
	# so it delivers without waiting for the next _post.
	var pending := _spool.read_all()
	if not pending.is_empty():
		_spool.clear()
		_send_queue(pending)
