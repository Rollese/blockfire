extends TestCase
## M11 Gate-B R5: the walkable, INDESTRUCTIBLE rubble remnant a collapsed building leaves behind (real
## collidable pieces, not cosmetic mounds) — so nobody hides invisibly inside a pile of rubble.

func _cat() -> PieceCatalog:
	return PieceCatalog.load_file("res://pieces/pieces.json")

func test_brubble_is_low_solid_cover() -> void:
	var cat := _cat()
	var t := cat.index_of("brubble")
	assert_true(t >= 0, "brubble piece exists in the catalog")
	assert_true(cat.is_half(t), "brubble is low (half height) cover, not a full wall")
	# NOT a flat surface: a surface piece short-circuits the movement resolver to non-blocking
	# (structure.gd::_blocks_ground), which made rubble completely walk-through in every stance
	# (owner playtest 2026-07-13). Rubble is SOLID low cover — it blocks the feet and is vaulted over,
	# never a floor you pass through. Collision is proven in collapse_rubble_collision_test.gd.
	assert_false(cat.is_flat_surface(t), "brubble is solid low cover you vault over, NOT a walk-through floor surface")

func test_brubble_is_indestructible() -> void:
	var cat := _cat()
	var t := cat.index_of("brubble")
	assert_false(cat.takes_damage(t, PieceCatalog.SRC_EXPLOSIVE), "rubble ignores explosives")
	assert_false(cat.takes_damage(t, PieceCatalog.SRC_BULLET), "rubble ignores bullets")
	assert_false(cat.takes_damage(t, PieceCatalog.SRC_MELEE), "rubble ignores melee")
	var store := StructureStore.new(cat)
	store.place(1, t, Vector3i(0, 0, 0), 0, 0, 0)
	var r := store.damage_chunks(1, PieceCatalog.SRC_EXPLOSIVE, Vector3(1, 0.5, 1), 5.0)
	assert_false(bool(r["hit"]), "a point-blank blast does not carve rubble")
	assert_false(store.get_record(1).is_empty(), "rubble survives the blast")

func test_brubble_is_cover_but_you_can_shoot_over_it() -> void:
	var cat := _cat()
	var t := cat.index_of("brubble")
	var store := StructureStore.new(cat)
	store.place(1, t, Vector3i(0, 0, 0), 0, 0, 0)   # cell x[0,2] z[0,2]; half -> AABB y[0,1]
	assert_true(store.march(Vector3(1, 0.5, -3), Vector3(0, 0, 1), 50.0)["hit"], "rubble stops a knee-high shot (cover)")
	assert_false(store.march(Vector3(1, 1.5, -3), Vector3(0, 0, 1), 50.0)["hit"], "you can shoot over ~1m rubble")

func test_brubble_is_not_structural() -> void:
	var cat := _cat()
	var store := StructureStore.new(cat)
	store.place(1, cat.index_of("brubble"), Vector3i(0, 0, 0), 0, 0, 5)
	assert_false(store.is_structural(1), "rubble bears no load (never props up a building)")
