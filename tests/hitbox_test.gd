extends TestCase

func test_ray_hits_body_center_not_headshot() -> void:
	var origin := Vector3(0, 0.9, 5)
	var dir := Vector3(0, 0, -1)
	var r := Hitbox.raycast_pawn(origin, dir, Vector3.ZERO, Stance.STAND, 100.0)
	assert_true(r["hit"], "should hit body")
	assert_eq(r["headshot"], false)

func test_ray_at_head_height_is_headshot() -> void:
	var origin := Vector3(0, Stance.head_center(Stance.STAND), 5)
	var dir := Vector3(0, 0, -1)
	var r := Hitbox.raycast_pawn(origin, dir, Vector3.ZERO, Stance.STAND, 100.0)
	assert_true(r["hit"])
	assert_eq(r["headshot"], true)

func test_ray_wide_miss() -> void:
	var origin := Vector3(5, 0.9, 5)
	var dir := Vector3(0, 0, -1)
	var r := Hitbox.raycast_pawn(origin, dir, Vector3.ZERO, Stance.STAND, 100.0)
	assert_eq(r["hit"], false)
