extends TestCase
## G3b: WorldRenderer.nest_barrel_visible — the LOCAL manning player sees only their own weapon
## viewmodel, so the turret barrel is hidden exactly when this client IS the nest's occupant. Every
## other case (remote-manned, unmanned, or an unknown local id) keeps the full barrel visible.

func test_hidden_when_local_player_is_the_occupant() -> void:
	assert_false(WorldRenderer.nest_barrel_visible(7, 7), "we man this nest -> hide its turret barrel")

func test_visible_for_a_remote_manned_nest() -> void:
	assert_true(WorldRenderer.nest_barrel_visible(42, 7), "someone else mans it -> barrel stays visible")

func test_visible_for_an_unmanned_nest() -> void:
	assert_true(WorldRenderer.nest_barrel_visible(0, 7), "unmanned -> barrel visible")

func test_visible_when_local_id_unknown() -> void:
	# my_id == 0 (pre-WELCOME / no local pawn) never hides — occupant 0 would otherwise falsely match.
	assert_true(WorldRenderer.nest_barrel_visible(0, 0), "no local id -> never hide")
	assert_true(WorldRenderer.nest_barrel_visible(5, 0), "no local id, remote occupant -> visible")
