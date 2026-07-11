extends TestCase

func test_version_is_8() -> void:
	assert_eq(Protocol.VERSION, 8)

func test_set_loadout_round_trips() -> void:
	var cfg := {"class": 3, "primary": 29, "secondary": 4, "gadget": 4, "armor": 2, "grenade": 1,
		"attachments": {"optic": "reddot", "barrel": "standard", "underbarrel": "none_ub"}}
	var out := Protocol.decode_set_loadout(Protocol.encode_set_loadout(cfg))
	assert_eq(int(out["class"]), 3)
	assert_eq(int(out["primary"]), 29)
	assert_eq(int(out["secondary"]), 4)
	assert_eq(int(out["gadget"]), 4)
	assert_eq(int(out["armor"]), 2)
	assert_eq(int(out["grenade"]), 1)
	assert_eq(String(out["attachments"]["optic"]), "reddot")
	assert_eq(String(out["attachments"]["barrel"]), "standard")
	assert_eq(String(out["attachments"]["underbarrel"]), "none_ub")

func test_decode_truncated_is_safe() -> void:
	# only the msg-type byte present — must return all-default, never crash
	var out := Protocol.decode_set_loadout(PackedByteArray([Protocol.Msg.SET_LOADOUT]))
	assert_eq(int(out["class"]), 0)
	assert_eq(int(out["primary"]), 0)
	assert_eq(String(out["attachments"]["optic"]), "")

func test_empty_attachment_ids_round_trip() -> void:
	var cfg := {"class": 0, "primary": 16, "secondary": 4, "gadget": 0, "armor": 1, "grenade": 0,
		"attachments": {"optic": "", "barrel": "", "underbarrel": ""}}
	var out := Protocol.decode_set_loadout(Protocol.encode_set_loadout(cfg))
	assert_eq(String(out["attachments"]["optic"]), "")
	assert_eq(int(out["primary"]), 16)

func test_long_attachment_id_survives() -> void:
	# a 200-char id encodes/decodes intact at the wire layer (catalog validation happens in sanitize)
	var long_id := "x".repeat(200)
	var cfg := {"class": 0, "primary": 16, "secondary": 4, "gadget": 0, "armor": 1, "grenade": 0,
		"attachments": {"optic": long_id, "barrel": "", "underbarrel": ""}}
	var out := Protocol.decode_set_loadout(Protocol.encode_set_loadout(cfg))
	assert_eq(String(out["attachments"]["optic"]), long_id)
