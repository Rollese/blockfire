extends TestCase

func test_can_vault_half_blocker_while_standing_moving() -> void:
	# A 1.0 m blocker (half piece) is vaultable when standing + moving.
	assert_true(Vault.can_vault(1.0, Stance.STAND, true))

func test_cannot_vault_full_blocker() -> void:
	# A 2.0 m wall exceeds VAULT_MAX_HEIGHT -> not vaultable.
	assert_false(Vault.can_vault(2.0, Stance.STAND, true))

func test_cannot_vault_when_crouched_or_prone() -> void:
	assert_false(Vault.can_vault(1.0, Stance.CROUCH, true))
	assert_false(Vault.can_vault(1.0, Stance.PRONE, true))

func test_cannot_vault_when_not_moving_or_no_blocker() -> void:
	assert_false(Vault.can_vault(1.0, Stance.STAND, false))
	assert_false(Vault.can_vault(0.0, Stance.STAND, true))

func test_arc_pos_endpoints_and_peak() -> void:
	var a := Vector3(0, 0, 0)
	var b := Vector3(0, 0, 2.5)
	assert_eq(Vault.arc_pos(a, b, 0.0), a)
	var mid := Vault.arc_pos(a, b, 0.5)
	assert_almost_eq(mid.z, 1.25)
	assert_true(mid.y > 0.0, "arc lifts off the ground at the midpoint")
	var end := Vault.arc_pos(a, b, 1.0)
	assert_almost_eq(end.z, 2.5)
	assert_almost_eq(end.y, 0.0)
