extends TestCase

func _vs(pos: Vector3, hp: int, seats: Array) -> VehicleState:
	var s := VehicleState.new()
	s.pos = pos; s.hp = hp; s.type = 0; s.heading = 0.25; s.turret_yaw = -0.5; s.seats = seats
	return s

func test_vehicle_enter_then_apply_roundtrips() -> void:
	var cur := {Vehicle.id_for(0): _vs(Vector3(3, 0, 4), 900, [7, 0, 0, 0, 0])}
	var bytes := Snapshot.encode(10, 1, 0, 0, {}, {}, cur, {})   # baseline_seq 0 = keyframe
	var view := {}; var vview := {}
	Snapshot.decode_apply(bytes, view, vview)
	var got: VehicleState = vview[Vehicle.id_for(0)]
	assert_almost_eq(got.pos.x, 3.0, 0.05)
	assert_eq(got.hp, 900)
	assert_eq(int(got.seats[0]), 7)

func test_vehicle_change_and_leave() -> void:
	var vid := Vehicle.id_for(0)
	var base := {vid: _vs(Vector3(0, 0, 0), 1000, [0, 0, 0, 0, 0])}
	# CHANGED: hp drop + move
	var cur := {vid: _vs(Vector3(2, 0, 0), 500, [0, 0, 0, 0, 0])}
	var b1 := Snapshot.encode(11, 2, 1, 0, {}, {}, cur, base)
	var view := {}; var vview := {vid: base[vid].clone()}
	Snapshot.decode_apply(b1, view, vview)
	assert_eq((vview[vid] as VehicleState).hp, 500)
	# LEAVE: vehicle gone from current
	var b2 := Snapshot.encode(12, 3, 2, 0, {}, {}, {}, cur)
	Snapshot.decode_apply(b2, view, vview)
	assert_false(vview.has(vid))

func test_pawns_and_vehicles_coexist_in_one_snapshot() -> void:
	var e := EntityState.new(); e.pos = Vector3(1, 0, 1); e.health = 80
	var pcur := {5: e}
	var vcur := {Vehicle.id_for(0): _vs(Vector3(9, 0, 9), 1000, [5, 0, 0, 0, 0])}
	var bytes := Snapshot.encode(20, 1, 0, 0, pcur, {}, vcur, {})
	var view := {}; var vview := {}
	Snapshot.decode_apply(bytes, view, vview)
	assert_eq((view[5] as EntityState).health, 80)
	assert_eq((vview[Vehicle.id_for(0)] as VehicleState).hp, 1000)
