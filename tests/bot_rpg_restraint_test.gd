extends TestCase
## Bot RPG restraint (bot-ai.md §8 balance gap): with vehicles removed from every shipping map,
## maybe_rpg always fell through to maybe_rpg_building, which rocketed the nearest wall every
## RPG_FIRE_COOLDOWN (~4 s) for the whole match — ~815 rockets / 28 min, ~27% of conquest_town wrecked.
## The fix is a 5× longer structure-specific cadence (the rate lever) plus an enemy-cover PREFERENCE in
## rpg_structure_target so the rockets that do fly concentrate on contested cover; a nearest-piece
## fallback keeps the destruction mechanic exercised on sparse maps (the M11 gate). Pure decision.
const BotExercisers := preload("res://bots/exercisers.gd")
const BuildGrid := preload("res://shared/sim/build_grid.gd")

const RANGE := 120.0
const ENEMY_R := 6.0

# Piece A is closer than B; only B has an enemy standing behind it.
func _structs() -> Dictionary:
	return {
		10: {"cell": Vector3i(1, 0, 0), "building_id": 1},   # nearer, no enemy
		11: {"cell": Vector3i(5, 0, 0), "building_id": 1},   # farther, enemy behind it
	}

func test_prefers_the_piece_an_enemy_hides_behind_over_a_closer_empty_wall() -> void:
	var wpB := BuildGrid.world_of(Vector3i(5, 0, 0))
	var enemies: Array = [wpB + Vector3(2.0, 0, 0)]   # within ENEMY_R of the farther piece 11
	var sid := BotExercisers.rpg_structure_target(_structs(), enemies, Vector3.ZERO, RANGE, ENEMY_R)
	assert_eq(sid, 11, "rockets the wall the enemy is using as cover, not the closer empty one")

func test_falls_back_to_nearest_piece_when_no_enemy_is_in_cover() -> void:
	# Enemy out in the open (a rifle target, not near any wall) -> fall back to the nearest piece so
	# the destruction mechanic still gets exercised on sparse maps; the cadence cap limits the rate.
	var enemies: Array = [Vector3(60, 0, 60)]
	var sid := BotExercisers.rpg_structure_target(_structs(), enemies, Vector3.ZERO, RANGE, ENEMY_R)
	assert_eq(sid, 10, "no enemy-occupied piece -> nearest structural piece (fallback)")

func test_no_enemies_still_targets_nearest_piece() -> void:
	var sid := BotExercisers.rpg_structure_target(_structs(), [], Vector3.ZERO, RANGE, ENEMY_R)
	assert_eq(sid, 10, "fallback holds with no enemies at all (rate is limited by the cadence, not this)")

func test_out_of_range_pieces_are_skipped() -> void:
	var wpB := BuildGrid.world_of(Vector3i(5, 0, 0))
	var enemies: Array = [wpB + Vector3(1.0, 0, 0)]
	# Range shorter than either piece distance -> nothing in range at all.
	var sid := BotExercisers.rpg_structure_target(_structs(), enemies, Vector3.ZERO, 2.0, ENEMY_R)
	assert_eq(sid, 0, "pieces beyond RPG range are never targeted")

func test_non_building_pieces_are_ignored() -> void:
	var structs := {5: {"cell": Vector3i(1, 0, 0), "building_id": 0}}   # e.g. a sandbag / cover prop
	var wp := BuildGrid.world_of(Vector3i(1, 0, 0))
	var sid := BotExercisers.rpg_structure_target(structs, [wp], Vector3.ZERO, RANGE, ENEMY_R)
	assert_eq(sid, 0, "only structural building pieces (building_id != 0) are RPG targets")
