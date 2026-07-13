class_name ClassSelectPanel
extends Control
## Deploy loadout screen (BattleBit-faithful): pick class -> primary(+attachments) -> armor ->
## grenade -> 1-of-3 gadget. Built entirely in code like the sibling menus (player_menu.gd /
## deploy_menu.gd). Holds a WORKING COPY of a loadout dict and emits loadout_changed(cfg) — an
## already-sanitized copy — on every edit.
##
## Loadout-UI redesign (4 owner complaints from a live playtest):
##   1. Selected option was near-invisible -> selected buttons get an accent StyleBoxFlat + a "✓ "
##      prefix so the pick is unmistakable at a glance.
##   2. Switching class wiped choices back to default -> class switch now LOADS the working copy from
##      the persisted per-class store (falls back to default only for a never-visited class).
##   3. Choices didn't stick -> every edit writes the sanitized _cfg back to the injected store
##      (ClientSettings) and saves settings.cfg, so loadouts persist across matches AND servers.
##   4. Flat primary row -> primaries are now grouped into per-archetype category sections
##      (Assault Rifles / SMG / DMR / LMG …), single-select preserved, with small SVG slot/category
##      icons throughout. Layout is two-column: primary+slots on the left, perks+live summary right.
##
## Every option list comes from the Loadout / Weapon / Armor / Grenade authorities — no duplicated
## option tables. The one exception is the per-slot attachment id list: the Attachment catalog
## validates by slot (slot_of) but does not publicly ENUMERATE its ids, so we read the canonical
## data/attachments.json directly to populate the slot pickers (not a hardcoded table — the same
## file the catalog is built from). Sanitize still runs against the passed catalog.

signal loadout_changed(cfg: Dictionary)
## Emitted when the player dismisses the editor (the "Done" button). The host hides the overlay.
## Needed because the panel is a full-rect Control (mouse_filter STOP) and would otherwise trap
## input over whatever opened it.
signal closed()

const _ATTACH_PATH := "res://data/attachments.json"
const _ICON_DIR := "res://client/art/icons"

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
	Loadout.GADGET_GRAPPLE: "Grappling Hook — fires a rope up a ledge to climb",
	Loadout.GADGET_RIOT_SHIELD: "Riot Shield — bulletproof frontal cover; slower, no primary fire",
	Loadout.GADGET_LMG_NEST: "LMG Nest",
}

# Slot/category glyph filenames (under _ICON_DIR). Missing files degrade gracefully (null guard in
# _load_icon), so a fresh checkout with no imported textures still renders the panel.
const _SLOT_ICON := {
	"class": "class", "optic": "optic", "barrel": "barrel", "underbarrel": "underbarrel",
	"armor": "armor", "grenade": "grenade", "gadget": "gadget",
}
# Weapon archetype -> glyph filename. Keyed by the Weapon enum.
const _ARCH_ICON := {
	Weapon.AR: "ar", Weapon.SMG: "smg", Weapon.DMR: "dmr", Weapon.LMG: "lmg", Weapon.PISTOL: "pistol",
}

# ---- state -----------------------------------------------------------------
var _cfg: Dictionary = {}                # working copy of the loadout (always sanitized)
var _attach: Attachment                  # catalog passed by the host; used for sanitize
var _attach_options: Dictionary = {}     # slot -> Array[String] of ids (from the data file)
var _store = null                        # injected persistence store (ClientSettings); may be null
var _icon_cache: Dictionary = {}         # res_path -> Texture2D|null (loaded once)

# ---- section rows (rebuilt on refresh) -------------------------------------
var _class_row: HBoxContainer
var _primary_box: VBoxContainer          # per-archetype category sections live here
var _attach_rows: Dictionary = {}        # slot -> HBoxContainer
var _armor_row: HBoxContainer
var _grenade_row: HBoxContainer
var _gadget_row: HBoxContainer
var _perk_box: VBoxContainer             # one Label per Loadout.trait_blurbs()
var _summary_box: VBoxContainer          # live text summary of the current loadout
var _built := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ensure_built()
	if _cfg.is_empty():
		# Standalone/default seed so the panel renders even before a host calls setup().
		setup(Loadout.default_loadout(Loadout.ASSAULT), _attach)

## Inject the per-class persistence store (a ClientSettings, duck-typed: needs get_class_loadout /
## set_class_loadout / save_to). May be null (the panel then just behaves session-locally). Called by
## DeployMenu.set_loadout_store / client_main so class switches remember prior picks.
func set_store(store) -> void:
	_store = store

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

	# Dimmed backdrop behind the panel content (matches DeployMenu's ~60%-black full-rect overlay) so
	# the editor reads as a modal instead of floating over the still-visible spawn list. Input is
	# already blocked by this Control's default STOP filter — this is purely visual. IGNORE so it
	# never eats clicks meant for the panel buttons drawn on top of it.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.6)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

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
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "LOADOUT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)

	# Class tabs span the full width above the two-column body.
	_class_row = _add_section(vbox, "Class", "class")

	# Two-column body: left = primary categories + slot rows; right = perks + live summary.
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	vbox.add_child(body)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.custom_minimum_size = Vector2(560, 0)
	body.add_child(left)

	body.add_child(VSeparator.new())

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.custom_minimum_size = Vector2(320, 0)
	body.add_child(right)

	# --- left column ---
	_caption(left, "PRIMARY", "ar", 16)
	_primary_box = VBoxContainer.new()   # per-archetype category sections, rebuilt on _refresh()
	_primary_box.add_theme_constant_override("separation", 4)
	left.add_child(_primary_box)

	# Attachments: one labelled row per slot (optic / barrel / underbarrel).
	for slot in Attachment.SLOTS:
		_attach_rows[slot] = _add_section(left, String(slot).capitalize(), String(slot))
	_armor_row = _add_section(left, "Armor", "armor")
	_grenade_row = _add_section(left, "Grenade", "grenade")
	_gadget_row = _add_section(left, "Gadget", "gadget")

	# --- right column ---
	_caption(right, "PERKS", "", 16)
	_perk_box = VBoxContainer.new()   # filled from Loadout.trait_blurbs() on every _refresh()
	right.add_child(_perk_box)
	right.add_child(HSeparator.new())
	_caption(right, "SUMMARY", "", 16)
	_summary_box = VBoxContainer.new()   # live text summary of the equipped loadout, per _refresh()
	right.add_child(_summary_box)

	vbox.add_child(HSeparator.new())
	var done_btn := Button.new()
	done_btn.text = "Done"
	done_btn.custom_minimum_size = Vector2(0, 40)
	done_btn.pressed.connect(func() -> void: closed.emit())
	vbox.add_child(done_btn)

## A labelled section: an HBox whose first child is an optional icon, then the caption Label; option
## buttons are appended after it on refresh. Returns the HBox so refresh can clear/refill its option
## children (everything after the caption Label).
func _add_section(parent: VBoxContainer, caption: String, icon_key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_add_icon(row, icon_key)
	var lbl := Label.new()
	lbl.text = caption
	lbl.custom_minimum_size = Vector2(96, 0)
	row.add_child(lbl)
	parent.add_child(row)
	return row

## A standalone caption Label (optionally icon-prefixed), used for the PRIMARY / PERKS / SUMMARY
## headers that sit above a VBox rather than beside inline options. `size` sets the header font size
## so all three captions render consistently. Returns the Label.
func _caption(parent: VBoxContainer, text: String, icon_key: String, size: int) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_add_icon(row, icon_key)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	row.add_child(lbl)
	parent.add_child(row)
	return lbl

## Append a small icon TextureRect to `row` for `icon_key` (a _SLOT_ICON/_ARCH_ICON filename stem, or
## "" for none). Null-guarded: a missing/undecodable icon simply adds nothing — the panel still builds.
func _add_icon(row: HBoxContainer, icon_key: String) -> void:
	if icon_key == "":
		return
	var tex := _load_icon("%s/%s.svg" % [_ICON_DIR, icon_key])
	if tex == null:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = Vector2(20, 20)
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(tr)

## Load (and cache) a menu icon texture. Uses MenuArt.load_texture, whose runtime-decode fallback
## keeps art appearing on a fresh checkout; a null result is cached so we don't retry a missing file.
func _load_icon(res_path: String) -> Texture2D:
	if _icon_cache.has(res_path):
		return _icon_cache[res_path]
	var tex := MenuArt.load_texture(res_path)
	_icon_cache[res_path] = tex
	return tex

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

	# Primary — grouped into per-archetype category sections (single-select across ALL sections).
	_refresh_primary(cls, primary)

	# Attachments — one row per slot, all catalog ids for that slot.
	for slot in Attachment.SLOTS:
		var row: HBoxContainer = _attach_rows[slot]
		_clear_options(row)
		var chosen := String(attachments.get(slot, ""))
		for aid: String in _attach_options.get(slot, []):
			_add_button(row, _attach_label(aid), aid == chosen, false,
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

	# Passive perks + live summary — always-visible, refreshed on every edit.
	_refresh_perks(cls)
	_refresh_summary(cls, primary, armor, grenade, gadget, attachments)

## Rebuild the primary picker as one category section per allowed archetype: a header (icon + name
## from Weapon.archetype_name — no duplicated label table) followed by a row of the archetype's
## variant buttons. Single-select is preserved because exactly one id across ALL sections equals
## `primary`. Each weapon button carries set_meta("weapon_id", wid) so tests can read what rendered.
func _refresh_primary(cls: int, primary: int) -> void:
	for c in _primary_box.get_children():
		_primary_box.remove_child(c)
		c.queue_free()
	for arch in Loadout.allowed_archetypes(cls):
		var variants := Weapon.variants_of(arch)
		if variants.is_empty():
			continue   # a data change could leave an allowed archetype with no variants — no lonely header
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 6)
		_add_icon(header, String(_ARCH_ICON.get(arch, "")))
		var hlbl := Label.new()
		hlbl.text = Weapon.archetype_name(arch)
		hlbl.add_theme_color_override("font_color", Color(0.68, 0.74, 0.82))
		header.add_child(hlbl)
		_primary_box.add_child(header)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		for wid: int in variants:
			var btn := _add_button(row, Weapon.display_name(wid), wid == primary, false,
				_on_primary_pressed.bind(wid))
			btn.set_meta("weapon_id", wid)
			btn.icon = _load_icon("%s/%s.svg" % [_ICON_DIR, String(_ARCH_ICON.get(arch, ""))])
		_primary_box.add_child(row)

## Every weapon id currently rendered across the primary category sections, in render order. Used by
## tests to assert the sections partition primary_options(cls) with nothing lost or added.
func rendered_primary_ids() -> Array:
	var out: Array = []
	for section in _primary_box.get_children():
		for child in section.get_children():
			if child is Button and (child as Button).has_meta("weapon_id"):
				out.append(int((child as Button).get_meta("weapon_id")))
	return out

## Rebuild the passive-perk panel from Loadout.trait_blurbs(cls). Clears the old labels first (same
## remove_child+queue_free idiom as _clear_options) so repeated class changes don't leak/duplicate
## rows. One Label per blurb — never a hardcoded perk string.
func _refresh_perks(cls: int) -> void:
	for c in _perk_box.get_children():
		_perk_box.remove_child(c)
		c.queue_free()
	for blurb: String in Loadout.trait_blurbs(cls):
		var lbl := Label.new()
		lbl.text = "• %s" % blurb
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(300, 0)
		_perk_box.add_child(lbl)

## Live plain-text summary of the equipped loadout (right column). One Label per slot, rebuilt every
## edit; reads the same authorities the pickers do so it can never disagree with the selection.
func _refresh_summary(cls: int, primary: int, armor: int, grenade: int, gadget: int, attachments: Dictionary) -> void:
	for c in _summary_box.get_children():
		_summary_box.remove_child(c)
		c.queue_free()
	var lines := [
		"Class: %s" % String(_CLASS_LABELS.get(cls, "?")),
		"Primary: %s" % Weapon.display_name(primary),
		"Optic: %s" % _attach_label(String(attachments.get("optic", ""))),
		"Barrel: %s" % _attach_label(String(attachments.get("barrel", ""))),
		"Underbarrel: %s" % _attach_label(String(attachments.get("underbarrel", ""))),
		"Armor: %s" % _armor_name(armor),
		"Grenade: %s" % String(_GRENADE_LABELS.get(grenade, "?")),
		"Gadget: %s" % String(_GADGET_LABELS.get(gadget, "Gadget %d" % gadget)).split(" —")[0],
	]
	for line: String in lines:
		var lbl := Label.new()
		lbl.text = line
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(300, 0)
		_summary_box.add_child(lbl)

## Tier display name (Armor.gd exposes no name authority, so this is the panel's single source; both
## the armor picker line and the summary route through it rather than duplicating the array).
func _armor_name(tier: int) -> String:
	return ["Light", "Medium", "Heavy"][tier] if tier >= 0 and tier <= 2 else "?"

## Armor picker line built from Armor.speed_mult / Armor.body_mult (no invented numbers). body_mult
## is the fraction of damage that LANDS, so damage-reduction = (1 - body_mult).
func _armor_label(tier: int) -> String:
	var speed_pct: int = int(round((Armor.speed_mult(tier) - 1.0) * 100.0))
	var dr_pct: int = int(round((1.0 - Armor.body_mult(tier)) * 100.0))
	return "%s  %+d%% speed, %d%% dmg reduction" % [_armor_name(tier), speed_pct, dr_pct]

## Attachment button label. The catalog carries no display names, so ids are title-cased; the
## per-slot empty option (e.g. "none_ub") renders as a plain "None" rather than the raw id.
func _attach_label(aid: String) -> String:
	if aid == "" or aid.begins_with("none"):
		return "None"
	return aid.capitalize()

## Remove option buttons from a section, keeping the leading caption (icon + Label). Options are every
## child that is a Button — the icon TextureRect and caption Label are left in place.
func _clear_options(row: HBoxContainer) -> void:
	for c in row.get_children():
		if c is Button:
			row.remove_child(c)
			c.queue_free()

## Add a toggle-style option button. `selected` gives it the accent style + a "✓ " prefix so the
## pick is unmistakable; unselected buttons get a dark translucent style. `disabled` greys it out.
func _add_button(row: HBoxContainer, text: String, selected: bool, disabled: bool, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = ("✓ " + text) if selected else text
	btn.toggle_mode = true
	btn.button_pressed = selected
	btn.disabled = disabled
	_style_button(btn, selected, disabled)
	if not disabled:
		btn.pressed.connect(cb)
	row.add_child(btn)
	return btn

## Ad-hoc styling (no .theme resource exists — matches the codebase's add_theme_*_override idiom).
## Selected = accent fill + bright border + white bold-ish text across normal/hover/pressed; that
## triple override is what makes the choice readable regardless of hover/pressed engine states.
func _style_button(btn: Button, selected: bool, disabled: bool) -> void:
	var fill: Color
	var border: Color
	var bw: int
	if selected:
		fill = Color(0.14, 0.42, 0.70)
		border = Color(0.48, 0.78, 1.0)
		bw = 2
	else:
		fill = Color(0.10, 0.11, 0.13, 0.85)
		border = Color(0.30, 0.32, 0.36)
		bw = 1
	for state in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(state, _mk_style(fill, border, bw))
	var font_col := Color(1, 1, 1) if selected else Color(0.78, 0.80, 0.84)
	if disabled:
		font_col = Color(0.45, 0.46, 0.50)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		btn.add_theme_color_override(c, font_col)

func _mk_style(fill: Color, border: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_border_width_all(bw)
	sb.border_color = border
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb

# ---- pick handlers ---------------------------------------------------------
func _on_class_pressed(cls: int) -> void:
	# Per-class memory: adopt the class's REMEMBERED loadout from the store (sanitized) if one exists,
	# else its default. This is the fix for "switching class wipes my choices" — a revisited class
	# restores exactly what was last equipped for it, a never-visited class gets a clean default.
	var stored: Dictionary = {}
	if _store != null:
		stored = _store.get_class_loadout(cls)
	if stored.is_empty():
		_cfg = Loadout.default_loadout(cls)
	else:
		stored["class"] = cls   # authoritative — the store key is the class
		_cfg = stored
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

## Sanitize the working copy against the catalog, PERSIST it to the per-class store (so the choice
## sticks across matches/servers), reflect the (possibly-corrected) result in the UI so an illegal
## combo can never appear selected, then emit a deep copy for the host.
func _apply() -> void:
	_cfg = Loadout.sanitize(_cfg, _attach)
	if _store != null:
		_store.set_class_loadout(int(_cfg.get("class", Loadout.ASSAULT)), _cfg)
		_store.save_to()
	_refresh()
	loadout_changed.emit(_cfg.duplicate(true))
