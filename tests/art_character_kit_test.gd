extends TestCase

func test_builds_named_body_parts_neutral_uniform() -> void:
	var soldier := CharacterKit.build(0)
	assert_true(soldier is Node3D, "returns a Node3D root")
	assert_true(soldier.has_node("Torso"), "has a torso")
	assert_true(soldier.has_node("Head"), "has a head")
	assert_true(soldier.has_node("GunMount"), "has the aim-direction gun mount")
	var torso := soldier.get_node("Torso") as MeshInstance3D
	assert_eq((torso.material_override as StandardMaterial3D).albedo_color, ArtPalette.UNIFORM,
		"body wears the shared neutral uniform — NOT a team tint (friend/foe is the marker)")

func test_both_teams_render_identically_no_tint() -> void:
	var a := CharacterKit.build(0).get_node("Torso") as MeshInstance3D
	var b := CharacterKit.build(1).get_node("Torso") as MeshInstance3D
	assert_eq((a.material_override as StandardMaterial3D).albedo_color,
		(b.material_override as StandardMaterial3D).albedo_color,
		"all players look alike regardless of team (BattleBit-style)")

func test_stand_height_matches_sim_body_height() -> void:
	assert_almost_eq(CharacterKit.STAND_HEIGHT, Stance.body_height(Stance.STAND), 0.01,
		"kit built to the sim's standing body height so renderer scaling stays 1.0 at STAND")
	var soldier := CharacterKit.build(1)
	var aabb := CharacterKit.aabb(soldier)
	assert_almost_eq(aabb.size.y, CharacterKit.STAND_HEIGHT, 0.05, "overall height == STAND_HEIGHT")

func test_gun_mount_points_forward_plus_z() -> void:
	var soldier := CharacterKit.build(0)
	var gun := soldier.get_node("GunMount") as Node3D
	assert_true(gun.position.z > 0.0, "gun mount sits at +Z (forward / aim direction)")

func test_held_weapon_xform_ar_is_baseline() -> void:
	var x := CharacterKit.held_weapon_xform(Weapon.AR)
	assert_almost_eq((x["scale"] as Vector3).z, 1.0, 0.001, "AR barrel is the baseline length")
	assert_almost_eq((x["scale"] as Vector3).x, 1.0, 0.001, "AR girth is the baseline")

func test_held_weapon_xform_dmr_longer_than_smg() -> void:
	var dmr := (CharacterKit.held_weapon_xform(Weapon.DMR)["scale"] as Vector3).z
	var smg := (CharacterKit.held_weapon_xform(Weapon.SMG)["scale"] as Vector3).z
	assert_true(dmr > smg, "the DMR barrel reads longer than the SMG")

func test_held_weapon_xform_rpg_is_fattest() -> void:
	var rpg := (CharacterKit.held_weapon_xform(Weapon.RPG)["scale"] as Vector3).x
	for w in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.PISTOL]:
		assert_true(rpg > (CharacterKit.held_weapon_xform(w)["scale"] as Vector3).x, "RPG tube is the fattest")

func test_held_weapon_xform_muzzle_extends_forward_grip_fixed() -> void:
	# A longer barrel must push the muzzle forward (pos_z grows), not shift the grip back into the body.
	var ar := float(CharacterKit.held_weapon_xform(Weapon.AR)["pos_z"])
	var dmr := float(CharacterKit.held_weapon_xform(Weapon.DMR)["pos_z"])
	assert_true(dmr > ar, "longer DMR barrel centre sits further forward")

func test_held_weapon_xform_unknown_falls_back_to_ar() -> void:
	var unknown := CharacterKit.held_weapon_xform(999)
	var ar := CharacterKit.held_weapon_xform(Weapon.AR)
	assert_eq((unknown["scale"] as Vector3), (ar["scale"] as Vector3), "unknown weapon id falls back to AR")
