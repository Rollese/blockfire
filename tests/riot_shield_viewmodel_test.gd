extends TestCase
## G2b: the pure "should the first-person riot-shield plate render?" predicate + the built
## viewmodel geometry. Client presentation only — no wire, no shield on remote pawns.


func test_visible_when_equipped_held_and_pool_left() -> void:
	assert_true(WorldRenderer.shield_viewmodel_visible(true, true, 255), "equipped + held + full pool shows")
	assert_true(WorldRenderer.shield_viewmodel_visible(true, true, 1), "any pool left still shows")


func test_hidden_when_not_equipped() -> void:
	assert_false(WorldRenderer.shield_viewmodel_visible(false, true, 255), "not the equipped gadget -> no plate")


func test_hidden_when_not_held() -> void:
	assert_false(WorldRenderer.shield_viewmodel_visible(true, false, 255), "not raised -> no plate")


func test_hidden_when_pool_empty() -> void:
	assert_false(WorldRenderer.shield_viewmodel_visible(true, true, 0), "broken/empty pool -> no plate")


func test_build_shield_viewmodel_geometry() -> void:
	var vm := WorldRenderer.build_shield_viewmodel()
	assert_eq(vm.name, "ShieldViewmodel", "named holder")
	assert_true(vm.get_child_count() >= 1, "has at least the plate mesh")
	assert_eq(vm.position, WorldRenderer.SHIELD_VM_OFFSET, "placed at the camera-space offset")
	vm.free()


func test_shield_is_shorter_than_before() -> void:
	# Owner: the shield must not occlude the top of the view — the player should see a
	# strip of sky above it. It used to be 0.60 tall; the tactical shield is shorter.
	assert_true(WorldRenderer.SHIELD_VM_SIZE.y < 0.60,
			"shield height must be shorter than the old 0.60 so the sky above is visible")


func test_has_transparent_center_window() -> void:
	# Tactical shield: a real see-through window in the middle the player looks THROUGH.
	var vm := WorldRenderer.build_shield_viewmodel()
	var window: MeshInstance3D = vm.find_child("Window", true, false)
	assert_true(window != null, "has a central Window mesh")
	var wmat := window.material_override as StandardMaterial3D
	assert_true(wmat != null, "window has a StandardMaterial3D")
	assert_eq(wmat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA,
			"window material uses alpha transparency")
	assert_true(wmat.albedo_color.a < 1.0, "window is genuinely see-through (alpha < 1)")
	vm.free()


func test_frame_bars_are_opaque_and_distinct_from_window() -> void:
	# The window is a hole in an opaque frame, not painted onto a solid slab: the old top "Slit"
	# is gone and there are distinct opaque frame bars around the see-through centre.
	var vm := WorldRenderer.build_shield_viewmodel()
	assert_true(vm.find_child("Slit", true, false) == null, "old top slit removed")
	var frame_top: MeshInstance3D = vm.find_child("FrameTop", true, false)
	assert_true(frame_top != null, "has a distinct FrameTop bar")
	var fmat := frame_top.material_override as StandardMaterial3D
	assert_true(fmat != null and fmat.albedo_color.a >= 1.0, "frame bar is opaque")
	vm.free()
