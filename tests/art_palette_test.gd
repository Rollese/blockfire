extends TestCase

func test_team_materials_are_distinct_and_tinted() -> void:
	var m0 := ArtPalette.team_material(0)
	var m1 := ArtPalette.team_material(1)
	assert_true(m0 is StandardMaterial3D, "returns a StandardMaterial3D")
	assert_eq(m0.albedo_color, Color(0.2, 0.5, 1.0), "team 0 == renderer blue")
	assert_eq(m1.albedo_color, Color(1.0, 0.3, 0.2), "team 1 == renderer red")
	assert_true(m0.albedo_color != m1.albedo_color, "teams visually distinct")

func test_damage_tint_darkens_as_bucket_drops() -> void:
	var base := Color(0.7, 0.7, 0.7)
	var pristine := ArtPalette.damage_tint(base, 3)
	var heavy := ArtPalette.damage_tint(base, 0)
	assert_eq(pristine, base, "bucket 3 (pristine) is untinted")
	assert_true(heavy.v < pristine.v, "bucket 0 (heavy) is darker")

func test_unknown_team_falls_back_to_neutral() -> void:
	assert_eq(ArtPalette.team_material(99).albedo_color, ArtPalette.NEUTRAL, "high oob -> neutral")
	assert_eq(ArtPalette.team_material(-1).albedo_color, ArtPalette.NEUTRAL, "negative -> neutral")
