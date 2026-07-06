extends TestCase
## WorldRenderer supply-bag presentation (M7): each deployed bag renders an amber ammo box / green
## medic bag with a camera-facing glyph, plus a resupply/heal ground ring drawn only for FRIENDLY bags
## (team == viewer's team). Pure presentation over the GADGET_LIST render entries — no gameplay effect.

func _bag(pos: Vector3, subtype: int, team: int) -> Dictionary:
	return {"kind": GadgetList.BAG, "pos": pos, "face": Vector3.ZERO, "subtype": subtype, "team": team}

func test_friendly_bag_gets_a_ring_enemy_bag_does_not() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	# Ammo bag on our team (0) -> box + ring; medic bag on the enemy team (1) -> box only.
	wr.set_gadgets([
		_bag(Vector3(0, 0, 0), Gadget.KIND_AMMO, 0),
		_bag(Vector3(4, 0, 0), Gadget.KIND_HEAL, 1),
	], 0)
	# 2 bag roots + 1 friendly ring = 3 tracked nodes.
	assert_eq(wr._gadget_nodes.size(), 3, "friendly bag adds a ring; the enemy bag does not")

func test_no_ring_when_local_team_unknown() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.set_gadgets([_bag(Vector3.ZERO, Gadget.KIND_AMMO, 0)], -1)
	assert_eq(wr._gadget_nodes.size(), 1, "team unknown (-1) -> box only, no ring")

func test_bag_box_carries_a_glyph_child() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.set_gadgets([_bag(Vector3.ZERO, Gadget.KIND_HEAL, 0)], 0)
	var bag_root: Node3D = wr._gadget_nodes[0]
	var has_glyph := false
	for c in bag_root.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).name == "BagGlyph":
			has_glyph = true
	assert_true(has_glyph, "the bag box mounts a readable glyph quad")

func test_ring_radius_matches_the_sim_dispense_radius() -> void:
	# The ring must read the real bag_radius (3.0 m for both medkit + ammobag) so it matches gameplay.
	assert_almost_eq(WorldRenderer.BAG_SUPPLY_RADIUS, 3.0, 0.001, "resupply/heal ring uses the sim radius")

func test_glyph_images_build_distinctly_for_ammo_and_heal() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	var ammo_img: Image = wr._bag_glyph_image(true)
	var heal_img: Image = wr._bag_glyph_image(false)
	assert_eq(ammo_img.get_width(), 32, "glyph is a 32px texture")
	assert_true(ammo_img.get_data() != heal_img.get_data(), "ammo icon differs from the medic cross")
