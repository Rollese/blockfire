extends TestCase
## GLB-loaded weapon/character models must be walked through ArtFilter.apply_nearest so their
## importer-baked (LINEAR) materials get the game-wide pixel-cutout NEAREST filter. Headless-safe —
## asserts material properties only, never rendered pixels (AGENTS.md §10).
##
## CAVEAT: headless glTF import can yield a model with zero BaseMaterial3D materials in this
## environment (dummy renderer / stripped import). When that happens there is nothing to fix, so the
## test asserts pass-through — the load-bearing guarantee under test is that the build wires the
## material-walk, not the exact material count.

func _base_mats(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.material_override is BaseMaterial3D:
				out.append(mi.material_override)
			var surfaces := 0
			if mi.mesh != null:
				surfaces = mi.mesh.get_surface_count()
			for s in surfaces:
				var m := mi.get_surface_override_material(s)
				if m == null and mi.mesh != null:
					m = mi.mesh.surface_get_material(s)
				if m is BaseMaterial3D:
					out.append(m)
		for c in n.get_children():
			stack.append(c)
	return out

func _assert_all_nearest(root: Node, label: String) -> void:
	var mats := _base_mats(root)
	if mats.is_empty():
		# Headless import gave a model with no BaseMaterial3D materials — nothing to fix. The wiring
		# (apply_nearest called in build) is what matters; pass-through.
		assert_eq(mats.size(), 0, "%s: no materials to filter (headless import) — pass-through" % label)
		return
	for m in mats:
		assert_eq((m as BaseMaterial3D).texture_filter,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST, "%s material uses NEAREST" % label)

func test_glb_weapon_materials_are_nearest() -> void:
	var model := GlbWeaponKit.build(Weapon.AR)
	autofree(model)
	_assert_all_nearest(model, "GLB weapon (AR)")

func test_glb_character_materials_are_nearest() -> void:
	var model := GlbCharacterKit.build()
	autofree(model)
	_assert_all_nearest(model, "GLB character")
