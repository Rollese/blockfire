extends TestCase
## Bullet tracers must stop at the first wall they hit instead of drawing a fixed 80 m beam
## straight through cover. clipped_tracer_length() is the pure length computation _spawn_tracer
## uses to scale/position the pooled beam so it spans origin -> first structure/terrain hit.

# Minimal stand-in for StructureStore exposing just the hole-aware march() the tracer clip calls.
class MarchStub extends RefCounted:
	var _dist: float
	var _hit: bool
	func _init(hit: bool, dist: float) -> void:
		_hit = hit
		_dist = dist
	func march(_origin: Vector3, _dir: Vector3, _max_dist: float) -> Dictionary:
		return {"hit": _hit, "dist": _dist, "id": 0}

func test_clips_to_wall_hit_distance() -> void:
	var store := MarchStub.new(true, 12.0)
	var l := WorldRenderer.clipped_tracer_length(store, Vector3.ZERO, Vector3(0, 0, -1))
	assert_almost_eq(l, 12.0, 0.001, "tracer clips to the wall hit distance")

func test_full_length_on_miss() -> void:
	var store := MarchStub.new(false, INF)
	var l := WorldRenderer.clipped_tracer_length(store, Vector3.ZERO, Vector3(0, 0, -1))
	assert_almost_eq(l, WorldRenderer.TRACER_LEN, 0.001, "no hit -> full-length beam")

func test_hit_beyond_range_is_clamped_to_full_length() -> void:
	# A hit farther than TRACER_LEN must not stretch the beam past its mesh length.
	var store := MarchStub.new(true, WorldRenderer.TRACER_LEN + 50.0)
	var l := WorldRenderer.clipped_tracer_length(store, Vector3.ZERO, Vector3(0, 0, -1))
	assert_almost_eq(l, WorldRenderer.TRACER_LEN, 0.001, "distant hit stays clamped to TRACER_LEN")

func test_null_store_is_full_length() -> void:
	var l := WorldRenderer.clipped_tracer_length(null, Vector3.ZERO, Vector3(0, 0, -1))
	assert_almost_eq(l, WorldRenderer.TRACER_LEN, 0.001, "no structure mirror -> full length fallback")
