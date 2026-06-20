class_name AudioDirector
extends Node
## Thin spatial-audio orchestrator. Presentation-only (AGENTS.md §7): renders cues from client signals
## + replicated state; decides which sound, gain, cutoff, bus, and voice via the pure helpers
## (AudioMix / VoicePool / AudioCatalog). The AudioStreamPlayer3D binding is owner-playtested, not
## asserted. NOT autoloaded and NOT wired into client_main on this branch (see audio.md §8 / Task 6).

var _catalog: AudioCatalog
var _pool: VoicePool
var _suppression: float = 0.0   # fed from the replicated Pawn.suppression byte at integration

# ---- playback layer (Node-only; owner-playtested, not headless-asserted) -----
# Created in _ready() — so the pure resolve/decide path stays usable headless (tests never add the
# director to a tree, so _ready never fires and no AudioStreamPlayer is allocated).
var _max_voices: int = 32
var _players: Array = []          # slot index -> AudioStreamPlayer3D (1:1 with the VoicePool slots)
var _ui_player: AudioStreamPlayer = null   # non-spatial (UI bus): hitmarker, reload, ui_click
var _streams: Dictionary = {}     # stream-id -> AudioStream (lazily generated placeholder tones)
var _listener_pos: Vector3 = Vector3.ZERO

func setup(catalog: AudioCatalog, max_voices: int) -> void:
	_catalog = catalog
	_max_voices = maxi(1, max_voices)
	_pool = VoicePool.new(_max_voices)

## Pure decision: type + listener distance + occlusion coverage + suppression -> final cue, or culled.
## No engine objects, no side effects -> headless-testable.
func resolve(event_type: String, distance: float, coverage: float, suppression: float) -> Dictionary:
	var def: Dictionary = _catalog.def_for(event_type)
	var spatial: bool = float(def["max_distance"]) > 0.0
	var dist_gain := 1.0
	if spatial:
		dist_gain = AudioMix.distance_gain(distance, float(def["unit_size"]), float(def["max_distance"]))
		if dist_gain <= 0.0:
			return {"culled": true}
	var cov := coverage if spatial else 0.0
	var mixed: Dictionary = AudioMix.combine(dist_gain, cov, float(def["cutoff_hz"]))
	var gain: float = float(mixed["gain"]) * db_to_linear(float(def["gain_db"]))
	# Listener-global suppression duck composes on top (cutoff handled on the Listener bus separately).
	gain *= AudioMix.suppression_duck(suppression)
	return {
		"culled": false,
		"gain": gain,
		"cutoff": mixed["cutoff"],
		"bus": String(def["bus"]),
		"priority": int(def["priority"]),
		"spatial": spatial,
	}

## resolve() + voice allocation. Returns the resolve dict plus {"slot", "evicted"} (slot -1 if dropped).
func decide(event_type: String, distance: float, coverage: float, suppression: float) -> Dictionary:
	var r := resolve(event_type, distance, coverage, suppression)
	if r.get("culled", false):
		r["slot"] = -1
		r["evicted"] = -1
		return r
	var v := _pool.request(int(r["priority"]), float(r["gain"]))
	r["slot"] = v["slot"]
	r["evicted"] = v["evicted"]
	return r

func set_suppression(s: float) -> void:
	_suppression = clampf(s, 0.0, 1.0)

# ---- Node-only playback (owner-playtested, not headless-asserted) ------------

## Allocate the AudioStreamPlayer pool once we're in the scene tree. Spatialization is relative to the
## active Camera3D listener; players hold a fixed slot id matching the VoicePool, and release it on
## natural finish. Placeholder tones until real assets land (audio.md §10 Q4 / plan Task 6 step 4).
func _ready() -> void:
	if _catalog == null:
		return   # setup() wasn't called (defensive) — stay inert
	for i in _max_voices:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		add_child(p)
		var slot := i
		p.finished.connect(func() -> void: _pool.release(slot))
		_players.append(p)
	_ui_player = AudioStreamPlayer.new()
	_ui_player.bus = "UI"
	add_child(_ui_player)

## Each render frame: where the local listener (camera/eye) is, for distance cull + voice-stealing.
func set_listener_pos(pos: Vector3) -> void:
	_listener_pos = pos

## Play a spatial world event at world_pos. coverage in [0,1] (0 = clear LOS; occlusion is a later
## refinement — audio.md §10 Q2). Culled out of range or dropped when the voice pool is full.
func play_at(event_type: String, world_pos: Vector3, coverage: float = 0.0) -> void:
	if _catalog == null:
		return
	var distance := _listener_pos.distance_to(world_pos)
	var r := decide(event_type, distance, coverage, _suppression)
	var slot := int(r.get("slot", -1))
	if bool(r.get("culled", false)) or slot < 0 or slot >= _players.size():
		return
	var evicted := int(r.get("evicted", -1))
	if evicted >= 0 and evicted != slot and evicted < _players.size():
		_players[evicted].stop()
	var def: Dictionary = _catalog.def_for(event_type)
	var p: AudioStreamPlayer3D = _players[slot]
	p.stop()
	p.stream = _stream_for(event_type)
	p.global_position = world_pos
	p.unit_size = float(def["unit_size"])
	p.max_distance = float(def["max_distance"])
	p.bus = String(def["bus"])
	var occ := AudioMix.occlusion_gain(coverage) * AudioMix.suppression_duck(_suppression)
	p.volume_db = float(def["gain_db"]) + linear_to_db(maxf(occ, 0.0001))
	p.play()

## Play a non-spatial (2D / UI-bus) event — hitmarker, reload, ui_click. Bypasses the 3D voice pool.
func play_2d(event_type: String) -> void:
	if _catalog == null or _ui_player == null:
		return
	var def: Dictionary = _catalog.def_for(event_type)
	_ui_player.stop()
	_ui_player.stream = _stream_for(event_type)
	_ui_player.bus = String(def["bus"])
	_ui_player.volume_db = float(def["gain_db"])
	_ui_player.play()

## Compatibility shell kept from the pre-wiring stub: resolve+bind in one call with an explicit
## listener position. Equivalent to set_listener_pos(listener_pos) + play_at(...).
func play_event(event_type: String, world_pos: Vector3, listener_pos: Vector3, coverage: float) -> Dictionary:
	_listener_pos = listener_pos
	play_at(event_type, world_pos, coverage)
	var distance := listener_pos.distance_to(world_pos)
	return resolve(event_type, distance, coverage, _suppression)

# ---- placeholder tone synthesis ---------------------------------------------
# Generated 16-bit PCM cues so the owner can playtest spatialization/voice-stealing now; swapped for
# real .ogg/.wav assets at audio.md §10 Q4. Distinct pitch/length per event for legibility.
const _TONE_SR := 22050

const _SFX_DIR := "res://assets/audio/sfx/"

func _stream_for(event_type: String) -> AudioStream:
	if _streams.has(event_type):
		return _streams[event_type]
	# Prefer a real CC0 .wav asset named after the def's `stream`; fall back to the synth tone for any
	# event whose asset hasn't been authored yet (crack/whiz/impact/footstep/explosion/...).
	var s: AudioStream = _load_asset(event_type)
	if s == null:
		s = _gen_tone(event_type)
	_streams[event_type] = s
	return s

func _load_asset(event_type: String) -> AudioStream:
	if _catalog == null:
		return null
	var stream_name := String(_catalog.def_for(event_type).get("stream", ""))
	if stream_name == "":
		return null
	var path := _SFX_DIR + stream_name + ".wav"
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path) as AudioStream

static func _gen_tone(event_type: String) -> AudioStreamWAV:
	var freq := 440.0
	var secs := 0.12
	match event_type:
		"gunfire", "gunfire_supp": freq = 170.0; secs = 0.10
		"bullet_crack": freq = 2200.0; secs = 0.04
		"bullet_whiz": freq = 1500.0; secs = 0.06
		"impact": freq = 260.0; secs = 0.08
		"footstep": freq = 130.0; secs = 0.07
		"reload": freq = 320.0; secs = 0.16
		"melee": freq = 200.0; secs = 0.09
		"explosion": freq = 70.0; secs = 0.45
		"engine": freq = 90.0; secs = 0.30
		"flashbang": freq = 60.0; secs = 0.50
		"hitmarker": freq = 1300.0; secs = 0.045
		"ui_click": freq = 900.0; secs = 0.04
	var n := int(_TONE_SR * secs)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / float(_TONE_SR)
		var env := 1.0 - float(i) / float(n)        # linear decay so it doesn't click off
		var v: float = sin(TAU * freq * t) * env * 0.45
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = _TONE_SR
	wav.stereo = false
	wav.data = data
	return wav
