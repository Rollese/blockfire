extends TestCase
## G3 round-2: the deployable LMG nest is a CURVED SANDBAG emplacement with a firing embrasure and
## NO mounted turret. The prone gunner (server pins them to seat_world() = pos - forward*SEAT_BACK,
## eye at Stance PRONE height 0.45) must see + shoot OUT through a slit at their eye level, while the
## sandbags read as sandy (textured, NEAREST) cover tall enough to protect them. Presentation-only.

# The gunner's eye in the kit's LOCAL frame (+Z forward): seat is SEAT_BACK(0.6) behind the pivot at
# ground, prone eye height 0.45. Verified against Emplacement.seat_world() + Stance.eye_height(PRONE).
const EYE := Vector3(0.0, 0.45, -0.6)

func _sand_children(node: Node3D) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("Sand"):
			out.append(c)
	return out

# A child box's AABB expressed in the root's LOCAL frame (accounts for its position + yaw rotation).
func _local_aabb(mi: MeshInstance3D) -> AABB:
	return mi.transform * (mi.mesh as Mesh).get_aabb()

func test_no_turret_or_gun_child() -> void:
	var nest: Node3D = autofree(LmgNestKit.build(0))
	assert_true(nest.get_node_or_null("Barrel") == null, "mounted turret Barrel pivot removed")
	for bad in ["Gun", "Receiver", "Stock", "Mount"]:
		assert_true(nest.get_node_or_null(bad) == null, "no turret hardware child '%s'" % bad)

func test_sandbag_meshes_present_and_sandy() -> void:
	var nest: Node3D = autofree(LmgNestKit.build(0))
	var bags := _sand_children(nest)
	assert_true(bags.size() >= 12, "a ring of stacked sandbag blocks (got %d)" % bags.size())
	var mat := (bags[0] as MeshInstance3D).material_override as StandardMaterial3D
	assert_true(mat != null, "sandbag has a material")
	# sandy albedo: warm, r > g > b, mid-bright (not team blue/red, not gun-metal black)
	var a := mat.albedo_color
	assert_true(a.r > a.g and a.g > a.b, "warm sandy tint (r>g>b), got %s" % str(a))
	assert_true(a.r > 0.5 and a.b < 0.6, "sand is bright+warm, not dark/cool: %s" % str(a))
	# pixelated look: a NEAREST-filtered texture like the other structure/building sandbags
	assert_true(mat.albedo_texture != null, "sandbag carries a texture")
	assert_eq(mat.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "NEAREST pixel filter")

func test_parapet_is_tall_enough_to_cover_the_gunner() -> void:
	# Old berm topped out at 0.5 m (didn't cover the gunner). The new parapet must rise well above that.
	var nest: Node3D = autofree(LmgNestKit.build(0))
	var top := 0.0
	for mi in _sand_children(nest):
		top = maxf(top, _local_aabb(mi).end.y)
	assert_true(top >= 1.8, "sandbag parapet reaches head-cover height (top=%.2f)" % top)

func test_rests_on_the_ground() -> void:
	var nest: Node3D = autofree(LmgNestKit.build(0))
	var bottom := 999.0
	for mi in _sand_children(nest):
		bottom = minf(bottom, _local_aabb(mi).position.y)
	assert_almost_eq(bottom, 0.0, 0.05, "feet sit at y=0 (rests on the ground)")

# The gunner must SEE + SHOOT out: no sandbag may occlude the eye's forward cone across the ±45° yaw
# traverse and up to the pitch-up limit. We sample rays inside the clamp arc and assert every sample
# point is clear of every sandbag block AABB (the slit band is open).
func test_firing_embrasure_is_open_across_the_arc() -> void:
	var nest: Node3D = autofree(LmgNestKit.build(0))
	var boxes: Array = []
	for mi in _sand_children(nest):
		boxes.append(_local_aabb(mi))
	for yaw_deg in [-40.0, -20.0, 0.0, 20.0, 40.0]:
		for pitch_deg in [0.0, 10.0, 20.0]:
			var yaw := deg_to_rad(yaw_deg)
			var pitch := deg_to_rad(pitch_deg)
			var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
			var t := 0.2
			while t <= 1.5:
				var p: Vector3 = EYE + dir * t
				for b: AABB in boxes:
					assert_false(b.has_point(p),
						"sandbag blocks the gunner's view/fire at yaw %.0f pitch %.0f (p=%s)" % [yaw_deg, pitch_deg, str(p)])
				t += 0.1

func test_hp_tint_darkens_the_sandbags_and_survives_no_barrel() -> void:
	# The renderer's _apply_nest_damage must walk the sandbag meshes (name begins with "Sand") and
	# darken them toward scorched as HP -> 0, and must NOT crash on a node that has no "Barrel" child.
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	var nest: Node3D = autofree(LmgNestKit.build(0))
	wr._apply_nest_damage(nest, 0, 1.0)
	var full: Color = ((_sand_children(nest)[0]) as MeshInstance3D).material_override.albedo_color
	wr._apply_nest_damage(nest, 0, 0.0)
	var dead: Color = ((_sand_children(nest)[0]) as MeshInstance3D).material_override.albedo_color
	assert_true(dead.v < full.v, "0%% HP sandbag darker than full HP")
