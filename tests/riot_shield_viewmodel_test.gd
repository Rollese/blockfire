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
