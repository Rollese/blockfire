extends TestCase

# Mirror of the _fire_shot penetration branch, isolated to the pure helpers so the contract is
# unit-tested without the full server harness (server _physics_process can't be cheaply driven).
func _resolve(body_dmg: int, enemy_dmg: int, material: int, piece_survives_after: bool) -> Dictionary:
	if not PieceCatalog.is_penetrable(material):
		return {"piece_damage": body_dmg, "enemy_damage": 0}   # non-pen stops the shot
	var p := Combat.apply_penetration(body_dmg, enemy_dmg,
		PieceCatalog.absorption_of(material), PieceCatalog.transmit_of(material))
	if not piece_survives_after:
		return {"piece_damage": p["piece_damage"], "enemy_damage": 0}  # destroyed -> bullet consumed
	return {"piece_damage": p["piece_damage"], "enemy_damage": p["exit_damage"]}

func test_wood_penetrates_to_enemy() -> void:
	var r := _resolve(25, 25, PieceCatalog.MAT_WOOD, true)
	assert_eq(r["piece_damage"], 10)
	assert_eq(r["enemy_damage"], 15)

func test_concrete_stops_shot() -> void:
	var r := _resolve(25, 25, PieceCatalog.MAT_CONCRETE, true)
	assert_eq(r["enemy_damage"], 0, "non-penetrable absorbs the whole shot")
	assert_eq(r["piece_damage"], 25)

func test_destroyed_piece_consumes_bullet() -> void:
	var r := _resolve(25, 25, PieceCatalog.MAT_METAL_THIN, false)
	assert_eq(r["enemy_damage"], 0, "1-pen: bullet does not pass a piece it destroyed")
