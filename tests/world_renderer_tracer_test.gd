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

# The pooled box mesh spans local Z ±TRACER_LEN/2; -Z is the forward face (Godot looking_at points
# -Z at the aim). The transform's front face must land at origin+fwd*length for ANY direction —
# this catches the global-vs-local scale bug that left non-world-Z shots at the full 80 m length.
func _front_face(xf: Transform3D) -> Vector3:
	return xf * Vector3(0.0, 0.0, -WorldRenderer.TRACER_LEN * 0.5)

func test_transform_front_face_clips_for_diagonal_shot() -> void:
	var origin := Vector3(5, 2, -3)
	var fwd := Vector3(1, 0, 1).normalized()   # non-axis-aligned, horizontal
	var length := 12.0
	var xf := WorldRenderer.tracer_transform(origin, fwd, Vector3.UP, length)
	var want := origin + fwd * length
	assert_true(_front_face(xf).distance_to(want) < 0.01,
		"diagonal-shot beam front face lands at the clip point, not 80 m away")
	# And it must NOT reach the full-length end (proves the length axis really was scaled).
	var full := origin + fwd * WorldRenderer.TRACER_LEN
	assert_true(_front_face(xf).distance_to(full) > 1.0,
		"diagonal-shot beam does not run out to the full TRACER_LEN")

func test_transform_front_face_clips_for_east_shot() -> void:
	var origin := Vector3.ZERO
	var fwd := Vector3(1, 0, 0)   # pure east — the case .scaled() silently left unclipped
	var length := 9.0
	var xf := WorldRenderer.tracer_transform(origin, fwd, Vector3.UP, length)
	assert_true(_front_face(xf).distance_to(fwd * length) < 0.01,
		"east-west beam front face clips to the wall, not the full length")
