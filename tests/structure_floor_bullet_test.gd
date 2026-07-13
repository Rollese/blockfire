extends TestCase
## Bug1 (round-2): a `bfloor` (surface:true) renders as a ~0.32 m thin slab but MUST NOT collide
## against bullets/LOS as a full 2.4 m solid cube. The ~2 m of open air above every floor tile was an
## invisible bullet-blocker (walk-through-but-shoot-blocked upstairs / on accent floor tiles).
## Fix: `_ray_piece` caps a flat-surface piece's ray-AABB top to a thin slab. Horizontal shots at
## stand/crouch/prone eye height pass over the slab; vertical shots through a floor are still blocked
## (cover between building levels preserved); non-surface walls are unaffected.

# type 0 = bfloor (surface), type 1 = bwall (solid, full height). CELL_SIZE = 2.4.
const CAT := '{"pieces":[{"id":"bfloor","height":"full","health":350,"blocks":"both","surface":true},{"id":"bwall","height":"full","health":350,"blocks":"both"}]}'

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.from_json_string(CAT)["catalog"])

# --- Horizontal shots from a pawn standing ON a floor cell must NOT be blocked by that floor ---

func _horizontal_not_blocked(eye_y: float, msg: String) -> void:
	var s := _store()
	# bfloor at cell (0,0,0): world AABB x[0,2.4] y[0,2.4] z[0,2.4]. Pawn stands on it, fires +x.
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)
	var origin := Vector3(0.2, eye_y, 1.2)   # inside the floor cell, at eye height
	var r := s.march(origin, Vector3(1, 0, 0), 50.0)
	# Pre-fix this wrongly hit the floor's full-cell AABB at dist ~0.0.
	assert_true(not bool(r["hit"]) or float(r["dist"]) > 2.4,
		"%s: floor must not block a horizontal eye-height shot (hit=%s dist=%s)" % [msg, r["hit"], r.get("dist", "-")])

func test_stand_eye_shot_passes_over_floor() -> void:
	_horizontal_not_blocked(1.6, "stand")

func test_crouch_eye_shot_passes_over_floor() -> void:
	_horizontal_not_blocked(1.0, "crouch")

func test_prone_eye_shot_passes_over_floor() -> void:
	_horizontal_not_blocked(0.45, "prone")   # real prone eye (stance.gd) = 0.45 m, thinnest margin above 0.35 slab

# --- A shot INTO the thin slab band (grazing the floor) is still blocked (floor is solid where it is) ---

func test_shot_inside_slab_band_still_blocks() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(2, 0, 0), 0, 99)   # floor at x[4.8,7.2] z[0,2.4]
	var origin := Vector3(0.0, 0.1, 1.2)       # y within the 0.35 m slab
	var r := s.march(origin, Vector3(1, 0, 0), 50.0)
	assert_true(bool(r["hit"]), "a shot within the slab band hits the floor")
	assert_almost_eq(float(r["dist"]), 4.8, 0.01, "hits the floor's near x face at 4.8")

# --- Vertical LOS through a floor is STILL blocked (cover between levels preserved) ---

func test_vertical_shot_down_still_blocked() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)   # floor slab y[0,0.35]
	var origin := Vector3(0.2, 3.0, 1.2)       # above the floor cell
	var r := s.march(origin, Vector3(0, -1, 0), 50.0)
	assert_true(bool(r["hit"]), "downward shot must be blocked by the floor slab")
	assert_almost_eq(float(r["dist"]), 3.0 - 0.35, 0.05, "blocks at the slab top ~0.35")

func test_vertical_shot_up_still_blocked() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)
	var origin := Vector3(0.2, -1.0, 1.2)      # below the floor cell
	var r := s.march(origin, Vector3(0, 1, 0), 50.0)
	assert_true(bool(r["hit"]), "upward shot must be blocked by the floor slab base")

# --- A regular full-height WALL is UNAFFECTED (guards against over-broadening the exemption) ---

# --- march_normal on a floor deck returns the TOP (0,1,0) face, so grenades bounce off, not through ---

func test_march_normal_floor_top_is_up() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 0, 0), 0, 99)   # floor slab y[0,0.35]
	# Grenade falling onto the centre of the deck (center-of-tile was the worst case: full-cube gave (0,-1,0)).
	var origin := Vector3(1.2, 3.0, 1.2)
	var r := s.march_normal(origin, Vector3(0, -1, 0), 50.0)
	assert_true(bool(r["hit"]), "grenade must strike the floor deck")
	var n: Vector3 = r["normal"]
	assert_almost_eq(n.y, 1.0, 0.01, "deck contact normal points UP (0,1,0), not down/horizontal")
	assert_almost_eq(n.x, 0.0, 0.01, "no horizontal component")
	assert_almost_eq(n.z, 0.0, 0.01, "no horizontal component")

# --- Per-storey: a floor at cell.y=1 caps its slab at the STOREY base [2.4, 2.75], not the world base ---

func test_offset_storey_slab_at_storey_base() -> void:
	var s := _store()
	s.place(1, 0, Vector3i(0, 1, 0), 0, 99)   # upper deck: cell y=1 -> base 2.4, slab [2.4,2.75]
	# Horizontal shot at that storey's stand eye height (2.4 + 1.6 = 4.0) passes over the deck.
	var over := s.march(Vector3(0.2, 4.0, 1.2), Vector3(1, 0, 0), 50.0)
	assert_true(not bool(over["hit"]) or float(over["dist"]) > 2.4,
		"upper-storey eye-height shot passes over the deck (hit=%s dist=%s)" % [over["hit"], over.get("dist", "-")])
	# A shot grazing within the storey slab band still blocks.
	var graze := s.march(Vector3(0.2, 2.5, 1.2), Vector3(1, 0, 0), 50.0)
	assert_true(bool(graze["hit"]), "shot within the storey slab band [2.4,2.75] hits the deck")
	# A vertical shot down through the upper deck is still blocked at the storey base.
	var down := s.march(Vector3(0.2, 5.0, 1.2), Vector3(0, -1, 0), 50.0)
	assert_true(bool(down["hit"]), "downward shot blocked by the upper deck")
	assert_almost_eq(float(down["dist"]), 5.0 - 2.75, 0.05, "blocks at the storey slab top ~2.75")

func test_wall_still_blocks_at_full_height() -> void:
	var s := _store()
	s.place(1, 1, Vector3i(2, 0, -1), 0, 99)   # bwall, cell (2,0,-1): x[4.8,7.2] y[0,2.4] z[-2.4,0]
	var origin := Vector3(0.0, 1.6, -1.2)
	var r := s.march(origin, Vector3(1, 0, 0), 50.0)
	assert_true(bool(r["hit"]), "wall must still block an eye-height shot")
	assert_almost_eq(float(r["dist"]), 4.8, 0.01, "wall blocks at its near face")
