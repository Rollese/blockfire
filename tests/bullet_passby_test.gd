extends TestCase
## BulletPassby (M7): a remote shot's ray (origin+dir, from SHOT_FX) that passes near the local
## eye produces a supersonic crack (very close) or a whiz (a bit further). Pure geometry; view-only.

const CR := BulletPassby.CRACK_RADIUS
const WR := BulletPassby.WHIZ_RADIUS

func test_direct_pass_overhead_cracks() -> void:
	# Shot fired down +Z, passing 1 m above an eye at the origin line -> crack.
	var r := BulletPassby.classify(Vector3(0, 0, -50), Vector3(0, 0, 1), Vector3(0, 1.0, 0))
	assert_eq(r["kind"], "bullet_crack", "a round passing 1 m away snaps as a crack")

func test_medium_pass_whizzes() -> void:
	# Same shot but 3 m off the line -> whiz, not crack.
	var r := BulletPassby.classify(Vector3(0, 0, -50), Vector3(0, 0, 1), Vector3(0, 3.0, 0))
	assert_eq(r["kind"], "bullet_whiz", "a round passing 3 m away whizzes")

func test_far_pass_is_silent() -> void:
	var r := BulletPassby.classify(Vector3(0, 0, -50), Vector3(0, 0, 1), Vector3(0, 20.0, 0))
	assert_eq(r["kind"], "", "a round passing 20 m away is not heard as a passby")

func test_shot_fired_away_from_eye_is_silent() -> void:
	# Eye behind the muzzle (closest approach is at t<0) -> the bullet never comes near us.
	var r := BulletPassby.classify(Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1.0, -10))
	assert_eq(r["kind"], "", "a bullet moving away from us makes no passby")

func test_closest_point_is_foot_of_perpendicular() -> void:
	var r := BulletPassby.classify(Vector3(0, 0, -50), Vector3(0, 0, 1), Vector3(0, 1.0, 7))
	# Foot of perpendicular from eye (z=7) onto the z-axis ray is at z=7.
	var p: Vector3 = r["point"]
	assert_almost_eq(p.z, 7.0, 0.01, "closest-approach point is the perpendicular foot")
	assert_almost_eq(p.x, 0.0, 0.01, "closest point lies on the ray")
	assert_almost_eq(p.y, 0.0, 0.01, "closest point lies on the ray")

func test_denormalized_dir_is_handled() -> void:
	# Quantized SHOT_FX dirs are not unit-length; classify must normalize defensively.
	var r := BulletPassby.classify(Vector3(0, 0, -50), Vector3(0, 0, 0.9), Vector3(0, 1.0, 0))
	assert_eq(r["kind"], "bullet_crack", "a non-unit dir still classifies by true distance")

func test_zero_dir_is_silent() -> void:
	var r := BulletPassby.classify(Vector3(0, 0, -50), Vector3.ZERO, Vector3(0, 1.0, 0))
	assert_eq(r["kind"], "", "a degenerate zero-length ray produces no passby (no crash)")

func test_beyond_max_range_is_silent() -> void:
	# Eye is on the line but far past where the bullet can travel.
	var r := BulletPassby.classify(Vector3(0, 0, 0), Vector3(0, 0, 1),
		Vector3(0, 0.0, BulletPassby.MAX_RANGE + 100.0))
	assert_eq(r["kind"], "", "no passby past the bullet's max travel")

func test_crack_radius_tighter_than_whiz() -> void:
	assert_true(CR < WR, "crack is a tighter near-miss than a whiz")
