class_name AudioDirector
extends Node
## Thin spatial-audio orchestrator. Presentation-only (AGENTS.md §7): renders cues from client signals
## + replicated state; decides which sound, gain, cutoff, bus, and voice via the pure helpers
## (AudioMix / VoicePool / AudioCatalog). The AudioStreamPlayer3D binding is owner-playtested, not
## asserted. NOT autoloaded and NOT wired into client_main on this branch (see audio.md §8 / Task 6).

var _catalog: AudioCatalog
var _pool: VoicePool
var _suppression: float = 0.0   # fed from the replicated Pawn.suppression byte at integration

func setup(catalog: AudioCatalog, max_voices: int) -> void:
	_catalog = catalog
	_pool = VoicePool.new(max_voices)

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

## Node-only shell (owner-playtested, not asserted): the deferred wiring (Task 6) calls this from the
## connected client signals; it binds an AudioStreamPlayer3D to the returned slot. Kept minimal here.
func play_event(event_type: String, world_pos: Vector3, listener_pos: Vector3, coverage: float) -> Dictionary:
	var distance := listener_pos.distance_to(world_pos)
	return decide(event_type, distance, coverage, _suppression)

func set_suppression(s: float) -> void:
	_suppression = clampf(s, 0.0, 1.0)
