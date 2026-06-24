extends TestCase
## ArmorVisual maps each tier to a distinct vest material + helmet scale on a procedural soldier.

func test_distinct_vest_material_per_tier() -> void:
	var light := CharacterKit.build()
	var heavy := CharacterKit.build()
	ArmorVisual.apply(light, Armor.LIGHT)
	ArmorVisual.apply(heavy, Armor.HEAVY)
	var lt := light.find_child("Torso", true, false) as MeshInstance3D
	var ht := heavy.find_child("Torso", true, false) as MeshInstance3D
	assert_true(lt != null and ht != null, "procedural soldier has a Torso")
	var lc: Color = (lt.material_override as StandardMaterial3D).albedo_color
	var hc: Color = (ht.material_override as StandardMaterial3D).albedo_color
	assert_true(lc != hc, "LIGHT and HEAVY vests are visually distinct")
	assert_true(hc.v < lc.v, "HEAVY vest is darker than LIGHT")
	light.free(); heavy.free()

func test_heavy_helmet_is_bulkier_than_light() -> void:
	var light := CharacterKit.build()
	var heavy := CharacterKit.build()
	ArmorVisual.apply(light, Armor.LIGHT)
	ArmorVisual.apply(heavy, Armor.HEAVY)
	var lh := light.find_child("Helmet", true, false) as MeshInstance3D
	var hh := heavy.find_child("Helmet", true, false) as MeshInstance3D
	assert_true(hh.scale.x > lh.scale.x, "HEAVY helmet scales up vs LIGHT")
	light.free(); heavy.free()

func test_shared_material_reused_across_calls() -> void:
	var a := CharacterKit.build()
	var b := CharacterKit.build()
	ArmorVisual.apply(a, Armor.MEDIUM)
	ArmorVisual.apply(b, Armor.MEDIUM)
	var am := (a.find_child("Torso", true, false) as MeshInstance3D).material_override
	var bm := (b.find_child("Torso", true, false) as MeshInstance3D).material_override
	assert_true(am == bm, "same tier reuses one shared material (no per-entity alloc)")
	a.free(); b.free()
