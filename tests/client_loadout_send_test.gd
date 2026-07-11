extends TestCase
## M19 P3 Task 1: the client stores a real loadout and sends it via SET_LOADOUT on join instead of
## silently relying on the server's fresh-connection default (Loadout.default_loadout(ASSAULT)).
## This test proves the wire contract the client's _send_loadout() relies on: a class's default
## loadout survives an encode/decode round trip through Protocol.encode_set_loadout intact.

func setup() -> void:
	Weapon.reset_registry()
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "weapons.json loads: %s" % res.get("error", ""))

func teardown() -> void:
	Weapon.reset_registry()

func test_default_loadout_roundtrips_through_set_loadout_wire() -> void:
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		var cfg := Loadout.default_loadout(cls)
		var d := Protocol.decode_set_loadout(Protocol.encode_set_loadout(cfg))
		assert_eq(int(d["class"]), cls)
		assert_eq(int(d["gadget"]), int(cfg["gadget"]))
		assert_eq(int(d["armor"]), int(cfg["armor"]))
