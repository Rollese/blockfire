extends TestCase
## M19 P3 Task 2: the client-side ClassSelectPanel builds headlessly and, on every edit, emits an
## already-sanitized loadout_changed(cfg). Verifies class re-seeds a legal config for all 4 classes.

var _last_cfg: Dictionary = {}
var _emits := 0

func setup() -> void:
	Weapon.reset_registry()
	var res := Weapon.load_from_file("res://data/weapons.json")
	assert_true(res["ok"], "weapons.json loads: %s" % res.get("error", ""))

func teardown() -> void:
	Weapon.reset_registry()

func _attach() -> Attachment:
	return Attachment.load_file("res://data/attachments.json")

func _on_changed(cfg: Dictionary) -> void:
	_last_cfg = cfg
	_emits += 1

func _make() -> ClassSelectPanel:
	var panel := ClassSelectPanel.new()
	panel.loadout_changed.connect(_on_changed)
	panel.setup(Loadout.default_loadout(Loadout.ASSAULT), _attach())
	return panel

func test_builds_and_seeds_without_error() -> void:
	var panel := _make()
	# setup() sanitized the seeded Assault loadout; a valid gadget must be present.
	assert_true(panel._cfg.get("class", -1) == Loadout.ASSAULT, "seeded class is Assault")
	assert_true(int(panel._cfg.get("gadget", -1)) in Loadout.IMPLEMENTED_GADGETS,
		"seeded gadget is implemented")
	panel.free()

func test_class_change_reseeds_sane_sanitized_cfg() -> void:
	var panel := _make()
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		_last_cfg = {}
		panel._on_class_pressed(cls)
		assert_eq(int(_last_cfg.get("class", -1)), cls, "emitted cfg class matches picked class")
		assert_true(int(_last_cfg.get("gadget", -1)) in Loadout.IMPLEMENTED_GADGETS,
			"class %d emits an implemented gadget" % cls)
		# Primary must be a legal variant for the class.
		assert_true(int(_last_cfg.get("primary", -1)) in Loadout.primary_options(cls),
			"class %d emits an allowed primary" % cls)
	panel.free()

func test_edits_emit_sanitized_copy() -> void:
	var panel := _make()
	var before := _emits
	panel._on_armor_pressed(Armor.HEAVY)
	assert_eq(_emits, before + 1, "armor pick emits once")
	assert_eq(int(_last_cfg.get("armor", -1)), Armor.HEAVY, "emitted cfg reflects the armor pick")
	# Grenade + gadget edits stay legal.
	panel._on_grenade_pressed(Grenade.SMOKE)
	assert_eq(int(_last_cfg.get("grenade", -1)), Grenade.SMOKE, "grenade pick reflected")
	panel.free()

func test_emitted_cfg_is_independent_deep_copy() -> void:
	# _apply emits cfg.duplicate(true); a host mutating the emitted dict (incl. its nested
	# attachments) must NOT corrupt the panel's internal _cfg. Guards the .duplicate(true) at
	# the emit site from being dropped.
	var panel := _make()
	panel._on_armor_pressed(Armor.MEDIUM)
	var emitted := _last_cfg
	var panel_gadget: int = int(panel._cfg.get("gadget", -1))
	var panel_optic := String((panel._cfg.get("attachments", {}) as Dictionary).get("optic", ""))
	# Corrupt the emitted copy (top-level scalar + nested dict).
	emitted["gadget"] = 9999
	(emitted.get("attachments", {}) as Dictionary)["optic"] = "TAMPERED"
	assert_eq(int(panel._cfg.get("gadget", -1)), panel_gadget, "internal gadget unchanged by host mutation")
	assert_eq(String((panel._cfg.get("attachments", {}) as Dictionary).get("optic", "")), panel_optic,
		"internal nested attachments unchanged by host mutation")
	panel.free()

func test_primary_sections_partition_primary_options() -> void:
	# Task 2: primaries are grouped into per-archetype category sections. The set of weapon ids
	# rendered across ALL sections must equal primary_options(cls) exactly, in the allowed-archetype
	# order — nothing lost, nothing added, so single-select still covers every legal gun.
	var panel := _make()
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		panel._on_class_pressed(cls)
		assert_eq(panel.rendered_primary_ids(), Loadout.primary_options(cls),
			"class %d primary sections partition primary_options in order" % cls)
	panel.free()

func test_class_switch_restores_remembered_loadout() -> void:
	# Task 3: switching class no longer wipes choices. With a store injected, editing Assault's primary
	# then leaving and returning restores the edited loadout (not the default).
	var store := ClientSettings.new()
	var panel := ClassSelectPanel.new()
	panel.set_store(store)
	panel.loadout_changed.connect(_on_changed)
	panel.setup(Loadout.default_loadout(Loadout.ASSAULT), _attach())
	var opts := Loadout.primary_options(Loadout.ASSAULT)
	var edited: int = int(opts[opts.size() - 1])   # last option — a DMR variant, != default (first AR)
	assert_ne(edited, Loadout.default_primary(Loadout.ASSAULT), "test picks a non-default primary")
	panel._on_primary_pressed(edited)
	assert_eq(int(panel._cfg.get("primary", -1)), edited, "assault primary edited")
	panel._on_class_pressed(Loadout.MEDIC)     # switch away…
	panel._on_class_pressed(Loadout.ASSAULT)   # …and back
	assert_eq(int(panel._cfg.get("primary", -1)), edited,
		"revisiting assault restores the edited primary, not the default")
	panel.free()

func test_never_visited_class_starts_at_default() -> void:
	# Task 3: a class with nothing remembered in the store gets its clean default_loadout.
	var store := ClientSettings.new()
	var panel := ClassSelectPanel.new()
	panel.set_store(store)
	panel.setup(Loadout.default_loadout(Loadout.ASSAULT), _attach())
	panel._on_class_pressed(Loadout.ENGINEER)
	assert_eq(int(panel._cfg.get("primary", -1)), Loadout.default_primary(Loadout.ENGINEER),
		"never-visited class -> default primary")
	assert_eq(int(panel._cfg.get("gadget", -1)), Loadout.default_gadget(Loadout.ENGINEER),
		"never-visited class -> default gadget")
	panel.free()

func test_edit_persists_to_store() -> void:
	# Task 3/5: every edit writes the sanitized cfg back to the injected store for its class.
	var store := ClientSettings.new()
	var panel := ClassSelectPanel.new()
	panel.set_store(store)
	panel.setup(Loadout.default_loadout(Loadout.ASSAULT), _attach())
	panel._on_armor_pressed(Armor.HEAVY)
	assert_eq(int(store.get_class_loadout(Loadout.ASSAULT).get("armor", -1)), Armor.HEAVY,
		"armor edit persisted to the store under the class key")
	panel.free()

func test_builds_for_every_class_and_missing_icon_ok() -> void:
	# Task 4 smoke: the panel builds/refreshes for every class, and a bogus/missing icon path returns
	# null without crashing the panel (fresh-checkout / missing-art safety).
	tolerate_runtime_errors()   # load() of a deliberately-missing resource pushes an expected error
	var panel := _make()
	assert_true(panel._load_icon("res://client/art/icons/does_not_exist_zzz.svg") == null,
		"missing icon -> null, no crash")
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		panel._on_class_pressed(cls)
		assert_true(panel._summary_box.get_child_count() > 0, "summary rebuilt for class %d" % cls)
	panel.free()

func test_perk_panel_populates_from_trait_blurbs() -> void:
	# Task 3: the always-visible perk panel is one Label per Loadout.trait_blurbs(cls) entry, rebuilt
	# on every class change (no leak/duplicate). Single source of truth = trait_blurbs.
	var panel := _make()
	for cls in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		panel._on_class_pressed(cls)
		var expected: int = Loadout.trait_blurbs(cls).size()
		assert_eq(panel._perk_box.get_child_count(), expected,
			"class %d perk panel has one label per trait blurb" % cls)
	# Re-selecting a class must not accumulate stale labels (clear-before-fill).
	panel._on_class_pressed(Loadout.ASSAULT)
	panel._on_class_pressed(Loadout.ASSAULT)
	assert_eq(panel._perk_box.get_child_count(), Loadout.trait_blurbs(Loadout.ASSAULT).size(),
		"repeated same-class picks do not duplicate perk labels")
	panel.free()
