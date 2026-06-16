extends TestCase

const MAP_JSON := '{"points":[{"id":"A","pos":[100,0,0],"radius":30,"start_owner":-1},{"id":"B","pos":[200,0,0],"radius":30,"start_owner":-1}],"bases":[{"team":0,"pos":[-900,0,0],"radius":40},{"team":1,"pos":[900,0,0],"radius":40}]}'

func _map() -> MapDef:
	return MapDef.from_json_string(MAP_JSON)["map"]

# Mirrors server deploy placement: an awaiting pawn (alive=false) becomes alive at a valid
# spawn ref; an invalid ref leaves it awaiting.
func _try_deploy(p: Pawn, team: int, ref: int, map: MapDef, conquest: ConquestState) -> void:
	if not DeploySpawn.is_valid(team, ref, map, conquest):
		return
	p.pos = DeploySpawn.resolve(team, ref, map, conquest)
	p.alive = true
	p.health = 100

func test_valid_ref_deploys_awaiting_pawn() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	var p := Pawn.new(1); p.team = 0; p.alive = false
	_try_deploy(p, 0, 0, m, c)   # HQ
	assert_true(p.alive, "valid HQ ref deploys")
	assert_eq(p.health, 100)

func test_invalid_ref_leaves_pawn_awaiting() -> void:
	var m := _map()
	var c := ConquestState.new(m)
	var p := Pawn.new(1); p.team = 1; p.alive = false
	_try_deploy(p, 1, 1, m, c)   # point index 0 not owned by team 1
	assert_false(p.alive, "invalid ref does not deploy")
