extends TestCase
## M19-P5 Task 5: un-grey the Riot Shield gadget in the loadout registry. GADGET_RIOT_SHIELD must
## join IMPLEMENTED_GADGETS so sanitize() accepts it for Support instead of snapping to the
## class's default gadget (AMMO).

func setup() -> void:
	Weapon.reset_registry()
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "weapons.json loads: %s" % res.get("error", ""))

func teardown() -> void:
	Weapon.reset_registry()

func _attach() -> Attachment:
	var res := Attachment.from_dict({"attachments": [
		{"id": "iron", "slot": "optic"},
		{"id": "reddot", "slot": "optic"},
		{"id": "standard", "slot": "barrel"},
		{"id": "none_ub", "slot": "underbarrel"},
	]})
	return res["catalog"]

func test_riot_shield_is_implemented() -> void:
	assert_true(Loadout.GADGET_RIOT_SHIELD in Loadout.IMPLEMENTED_GADGETS, "riot shield is built")

func test_support_can_select_riot_shield() -> void:
	var lo := Loadout.default_loadout(Loadout.SUPPORT)
	lo["gadget"] = Loadout.GADGET_RIOT_SHIELD
	var san := Loadout.sanitize(lo, _attach())
	assert_eq(int(san["gadget"]), Loadout.GADGET_RIOT_SHIELD, "sanitize keeps a Support riot shield")

func test_non_support_cannot() -> void:
	var lo := Loadout.default_loadout(Loadout.ASSAULT)
	lo["gadget"] = Loadout.GADGET_RIOT_SHIELD
	var san := Loadout.sanitize(lo, _attach())
	assert_true(int(san["gadget"]) != Loadout.GADGET_RIOT_SHIELD, "riot shield not offered to Assault")
