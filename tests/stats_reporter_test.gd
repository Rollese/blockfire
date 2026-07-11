extends TestCase

const Reporter := preload("res://server/stats/stats_reporter.gd")

func test_weapon_key_maps_enum_to_lowercase_label() -> void:
	# Weapon.AR == 0; get_def(0)["name"] == "AR"
	assert_eq(Reporter.weapon_key(0), "ar", "AR enum -> 'ar'")

func test_weapon_key_unknown_falls_back() -> void:
	assert_eq(Reporter.weapon_key(9999), "ar", "unknown id -> Weapon fallback name")
