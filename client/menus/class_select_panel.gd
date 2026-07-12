class_name ClassSelectPanel
extends Control
## M19 P3 deploy loadout screen (BattleBit-faithful): pick class -> primary(+attachments) ->
## armor -> grenade -> 1-of-3 gadget. Built entirely in code like the sibling menus
## (player_menu.gd / deploy_menu.gd). Holds a WORKING COPY of a loadout dict and emits
## loadout_changed(cfg) — an already-sanitized copy — on every edit. Task 3 wires this signal into
## client_main + deploy_menu; the perk panel (trait_blurbs) is Task 3, stubbed empty here.
##
## Every option list comes from the Loadout / Weapon / Armor / Grenade authorities — no duplicated
## option tables. The one exception is the per-slot attachment id list: the Attachment catalog
## validates by slot (slot_of) but does not publicly ENUMERATE its ids, so we read the canonical
## data/attachments.json directly to populate the slot pickers (not a hardcoded table — the same
## file the catalog is built from). Sanitize still runs against the passed catalog.

signal loadout_changed(cfg: Dictionary)

const _ATTACH_PATH := "res://data/attachments.json"

# Grenade id -> display label. Source: shared/sim/grenade.gd constants + client/hud/hud_view.gd's
# _THROWABLE_LABELS idiom (which lists Frag/Smoke only); Flash added from Grenade.FLASHBANG. Mirrored
# locally (small map) rather than coupling to hud_view, per task note.
const _GRENADE_LABELS := {
	Grenade.FRAG: "Frag",
	Grenade.SMOKE: "Smoke",
	Grenade.FLASHBANG: "Flash",
}

# Class id -> display name (Loadout enum order).
const _CLASS_LABELS := {
	Loadout.ASSAULT: "Assault",
	Loadout.MEDIC: "Medic",
	Loadout.ENGINEER: "Engineer",
	Loadout.SUPPORT: "Support",
}

# Gadget id -> one-line effect label (covers every GADGET_* a class may list; unimplemented ones are
# shown greyed+disabled). Kept here purely for DISPLAY — selectability is gated by Loadout.
const _GADGET_LABELS := {
	Loadout.GADGET_C4: "C4 — remote demolition charge",
	Loadout.GADGET_HEAL: "Medkit — heals nearby teammates",
	Loadout.GADGET_AMMO: "Ammo Bag — resupplies teammates",
	Loadout.GADGET_RPG: "RPG — anti-vehicle / structure rocket",
	Loadout.GADGET_REPAIR: "Repair Tool — mends structures & vehicles",
	Loadout.GADGET_BREACH: "Breaching Charge — blows open walls",
	Loadout.GADGET_STIM: "Stim — fast self / ally heal",
	Loadout.GADGET_SMOKE_WALL: "Smoke Wall — deployable smoke screen",
	Loadout.GADGET_GRAPPLE: "Grappling Hook — (coming soon)",
	Loadout.GADGET_RIOT_SHIELD: "Riot Shield — (coming soon)",
	Loadout.GADGET_LMG_NEST: "LMG Nest — (coming soon)",
}

# ---- state -----------------------------------------------------------------
var _cfg: Dictionary = {}                # working copy of the loadout (always sanitized)
var _attach: Attachment                  # catalog passed by the host; used for sanitize
var _attach_options: Dictionary = {}     # slot -> Array[String] of ids (from the data file)

# ---- section rows (rebuilt on refresh) -------------------------------------
var _class_row: HBoxContainer
var _primary_row: HBoxContainer
var _attach_rows: Dictionary = {}        # slot -> HBoxContainer
var _armor_row: HBoxContainer
var _grenade_row: HBoxContainer
var _gadget_row: HBoxContainer
var _perk_box: VBoxContainer             # Task 3 populates this; stubbed empty here
var _built := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ensure_built()
	if _cfg.is_empty():
		# Standalone/default seed so the panel renders even before a host calls setup().
		setup(Loadout.default_loadout(Loadout.ASSAULT), _attach)

## Public entry point: adopt a working copy of `cfg` + the attachment catalog and rebuild every
## section to reflect it. Stores a deep copy so the caller's dict is never mutated in place.
func setup(cfg: Dictionary, attach) -> void:
	_ensure_built()
	if attach != null:
		_attach = attach
	if _attach == null:
		# No catalog handed in — load our own so sanitize always has one (matches client_main).
		_attach = Attachment.load_file(_ATTACH_PATH)
	_cfg = (cfg if cfg != null else {}).duplicate(true)
	_cfg = Loadout.sanitize(_cfg, _attach)
	_refresh()

# ---- construction ----------------------------------------------------------
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_load_attach_options()

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(520, 0)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "LOADOUT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)

	_class_row = _add_section(vbox, "Class")
	_primary_row = _add_section(vbox, "Primary")
	# Attachments: one labelled row per slot (optic / barrel / underbarrel).
	for slot in Attachment.SLOTS:
		_attach_rows[slot] = _add_section(vbox, String(slot).capitalize())
	_armor_row = _add_section(vbox, "Armor")
	_grenade_row = _add_section(vbox, "Grenade")
	_gadget_row = _add_section(vbox, "Gadget")

	vbox.add_child(HSeparator.new())
	_perk_box = VBoxContainer.new()   # Task 3 fills this from Loadout.trait_blurbs()
	vbox.add_child(_perk_box)

## A labelled section: an HBox whose first child is the caption Label; option buttons are appended
## after it on refresh. Returns the HBox so refresh can clear/refill its button children.
func _add_section(parent: VBoxContainer, caption: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = caption
	lbl.custom_minimum_size = Vector2(110, 0)
	row.add_child(lbl)
	parent.add_child(row)
	return row

## Read the canonical attachment data file into slot -> [ids]. Robust: leaves a slot's list empty
## if the file is missing or malformed (the section then simply shows no buttons, never crashes).
func _load_attach_options() -> void:
	_attach_options = {}
	for slot in Attachment.SLOTS:
		_attach_options[slot] = []
	if not FileAccess.file_exists(_ATTACH_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(_ATTACH_PATH))
	if not (data is Dictionary):
		return
	var raw = data.get("attachments", [])
	if not (raw is Array):
		return
	for a in raw:
		if not (a is Dictionary):
			continue
		var slot := String(a.get("slot", ""))
		var id := String(a.get("id", ""))
		if id != "" and _attach_options.has(slot):
			(_attach_options[slot] as Array).append(id)

# ---- refresh (rebuild every section's buttons from _cfg) --------------------
func _refresh() -> void:
	var cls: int = int(_cfg.get("class", Loadout.ASSAULT))
	var primary: int = int(_cfg.get("primary", Loadout.default_primary(cls)))
	var armor: int = int(_cfg.get("armor", Armor.MEDIUM))
	var grenade: int = int(_cfg.get("grenade", Grenade.FRAG))
	var gadget: int = int(_cfg.get("gadget", Loadout.default_gadget(cls)))
	var attachments: Dictionary = _cfg.get("attachments", {})

	# Class.
	_clear_options(_class_row)
	for c in [Loadout.ASSAULT, Loadout.MEDIC, Loadout.ENGINEER, Loadout.SUPPORT]:
		_add_button(_class_row, String(_CLASS_LABELS.get(c, "?")), c == cls, false,
			_on_class_pressed.bind(c))

	# Primary (variant ids for the class's allowed archetypes).
	_clear_options(_primary_row)
	for wid: int in Loadout.primary_options(cls):
		_add_button(_primary_row, Weapon.display_name(wid), wid == primary, false,
			_on_primary_pressed.bind(wid))

	# Attachments — one row per slot, all catalog ids for that slot.
	for slot in Attachment.SLOTS:
		var row: HBoxContainer = _attach_rows[slot]
		_clear_options(row)
		var chosen := String(attachments.get(slot, ""))
		for aid: String in _attach_options.get(slot, []):
			_add_button(row, aid.capitalize(), aid == chosen, false,
				_on_attachment_pressed.bind(String(slot), aid))

	# Armor — trade-off text derived from the real Armor multipliers.
	_clear_options(_armor_row)
	for tier in [Armor.LIGHT, Armor.MEDIUM, Armor.HEAVY]:
		_add_button(_armor_row, _armor_label(tier), tier == armor, false,
			_on_armor_pressed.bind(tier))

	# Grenade.
	_clear_options(_grenade_row)
	for g in [Grenade.FRAG, Grenade.SMOKE, Grenade.FLASHBANG]:
		_add_button(_grenade_row, String(_GRENADE_LABELS.get(g, "?")), g == grenade, false,
			_on_grenade_pressed.bind(g))

	# Gadget — the class's three options; unimplemented ones are greyed + disabled.
	_clear_options(_gadget_row)
	for gd: int in Loadout.gadget_options(cls):
		var implemented: bool = gd in Loadout.IMPLEMENTED_GADGETS
		_add_button(_gadget_row, String(_GADGET_LABELS.get(gd, "Gadget %d" % gd)),
			gd == gadget, not implemented, _on_gadget_pressed.bind(gd))

## Armor picker line built from Armor.speed_mult / Armor.body_mult (no invented numbers). body_mult
## is the fraction of damage that LANDS, so damage-reduction = (1 - body_mult).
func _armor_label(tier: int) -> String:
	var tier_name: String = ["Light", "Medium", "Heavy"][tier] if tier >= 0 and tier <= 2 else "?"
	var speed_pct: int = int(round((Armor.speed_mult(tier) - 1.0) * 100.0))
	var dr_pct: int = int(round((1.0 - Armor.body_mult(tier)) * 100.0))
	return "%s  %+d%% speed, %d%% dmg reduction" % [tier_name, speed_pct, dr_pct]

## Remove option buttons from a section, keeping the leading caption Label (child 0).
func _clear_options(row: HBoxContainer) -> void:
	var kids := row.get_children()
	for i in range(kids.size() - 1, 0, -1):
		var c: Node = kids[i]
		row.remove_child(c)
		c.queue_free()

## Add a toggle-style option button. `selected` shows it pressed; `disabled` greys it out.
func _add_button(row: HBoxContainer, text: String, selected: bool, disabled: bool, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.button_pressed = selected
	btn.disabled = disabled
	if not disabled:
		btn.pressed.connect(cb)
	row.add_child(btn)
	return btn

# ---- pick handlers ---------------------------------------------------------
func _on_class_pressed(cls: int) -> void:
	# Pick-class-first: fully re-seed primary/gadget/armor/grenade to the class defaults.
	_cfg = Loadout.default_loadout(cls)
	_apply()

func _on_primary_pressed(weapon_id: int) -> void:
	_cfg["primary"] = weapon_id
	_apply()

func _on_attachment_pressed(slot: String, id: String) -> void:
	var attachments: Dictionary = (_cfg.get("attachments", {}) as Dictionary).duplicate()
	attachments[slot] = id
	_cfg["attachments"] = attachments
	_apply()

func _on_armor_pressed(tier: int) -> void:
	_cfg["armor"] = tier
	_apply()

func _on_grenade_pressed(g: int) -> void:
	_cfg["grenade"] = g
	_apply()

func _on_gadget_pressed(g: int) -> void:
	_cfg["gadget"] = g
	_apply()

## Sanitize the working copy against the catalog, reflect the (possibly-corrected) result in the UI
## so an illegal combo can never appear selected, then emit a deep copy for the host.
func _apply() -> void:
	_cfg = Loadout.sanitize(_cfg, _attach)
	_refresh()
	loadout_changed.emit(_cfg.duplicate(true))
