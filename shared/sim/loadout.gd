class_name Loadout
extends Object
## Class -> weapon + gadget + default attachments mapping. Gadget identity per spec
## §"Class gadget assignment". M18 transition: Weapon.RPG is still the Engineer-only weapon-slot
## choice (can_equip/secondary_for gate) today, while the new GADGET_RPG gadget-slot id coexists
## with it; RPG becomes gadget-only in P1b.

enum { ASSAULT = 0, MEDIC = 1, ENGINEER = 2, SUPPORT = 3 }

# Gadget kinds owned by a class (mirror Gadget.Kind values; kept here so loadout has no hard dep
# on the Gadget catalog). GADGET_NONE = class has no active gadget in v1.
const GADGET_NONE := -1
const GADGET_C4 := 0
const GADGET_MINE := 1
const GADGET_HEAL := 3
const GADGET_AMMO := 4

# M18 gadget ids. The 0-5 values mirror Gadget.KIND_* so a loadout gadget maps 1:1 to a gadget
# entity; the 6+ ids are M18-new gadgets whose entities land in later phases. GADGET_MEDKIT is a
# display alias of HEAL.
const GADGET_RPG := 2          # mirrors Gadget.KIND_RPG (RPG is a gadget now, not a primary)
const GADGET_REPAIR := 5       # mirrors Gadget.KIND_REPAIR
const GADGET_MEDKIT := GADGET_HEAL   # display alias
const GADGET_STIM := 6
const GADGET_SMOKE_WALL := 7
const GADGET_BREACH := 8
const GADGET_GRAPPLE := 9
const GADGET_RIOT_SHIELD := 10
const GADGET_SANDBAG := 11
const GADGET_LMG_NEST := 12

# Gadgets whose selection is actually supported so far. GROWS PER PHASE (spec §D/§L): P1b adds RPG;
# P2 adds STIM/BREACH/SMOKE_WALL/REPAIR; P4 adds LMG_NEST; later GRAPPLE/RIOT_SHIELD. An unbuilt
# gadget is not selectable (sanitize + client hide it) and its class falls back to the first BUILT
# option (default_gadget). GADGET_SANDBAG is a RESERVED interim filler: it is intentionally NOT in
# any class's gadget_options yet, so adding it here alone would not surface it — a later phase wires
# it into specific class slots first.
const IMPLEMENTED_GADGETS := [GADGET_C4, GADGET_HEAL, GADGET_AMMO]

static func weapon_for(cls: int) -> int:
	match cls:
		ENGINEER: return Weapon.SMG
		_: return Weapon.AR   # assault/medic/support (DMR is an Assault loadout choice, not a default)

static func gadget_for(cls: int) -> int:
	match cls:
		ENGINEER: return GADGET_C4   # default; the claymore alternative is via gadget_for_player
		MEDIC: return GADGET_HEAL
		SUPPORT: return GADGET_AMMO
		_: return GADGET_NONE   # assault (frag/smoke are M4 grenades, not a gadget slot)

## The three gadgets a class may choose between (spec §A). The target roster; availability is
## gated by IMPLEMENTED_GADGETS (see sanitize/default_gadget).
static func gadget_options(cls: int) -> Array:
	match cls:
		ASSAULT: return [GADGET_C4, GADGET_GRAPPLE, GADGET_BREACH]
		MEDIC: return [GADGET_HEAL, GADGET_STIM, GADGET_SMOKE_WALL]
		ENGINEER: return [GADGET_RPG, GADGET_C4, GADGET_REPAIR]
		SUPPORT: return [GADGET_AMMO, GADGET_RIOT_SHIELD, GADGET_LMG_NEST]
		_: return [GADGET_C4]

static func is_valid_gadget(cls: int, gadget: int) -> bool:
	return gadget in gadget_options(cls)

## Weapon ARCHETYPES (AR/SMG/DMR/LMG…) a class may field — the stable, loadout-owned matrix that
## class gating is expressed against (spec §A). Distinct from the concrete selectable weapon *ids*
## returned by primary_options(): with the weapon-variants registry, one archetype fans out to many
## named variant ids. This function does NOT change when variants land — only primary_options() does.
static func allowed_archetypes(cls: int) -> Array:
	match cls:
		ASSAULT: return [Weapon.AR, Weapon.SMG, Weapon.DMR]
		SUPPORT: return [Weapon.AR, Weapon.SMG, Weapon.LMG]
		_: return [Weapon.AR, Weapon.SMG]   # medic, engineer

## WEAPON-VARIANTS SEAM — the archetype an equippable weapon id belongs to. Today every primary id
## IS its own archetype (0-5), so this is identity. When the weapon-variants registry lands (variant
## ids ≥16, owned by the weapon-variants track — see docs/superpowers/specs/2026-07-11-weapon-variants-design.md),
## change ONLY this body to `return Weapon.archetype_of(weapon_id)`. Everything below routes through
## it, so class gating stays correct for both archetype and variant ids with no other edits.
static func _archetype_of(weapon_id: int) -> int:
	return weapon_id

## The concrete primary weapon ids a class may select (what the class-select "primary picker" lists).
## Today == allowed_archetypes(cls) (one id per archetype). WHEN VARIANTS LAND: this becomes the
## concatenation of Weapon.variants_of(a) for each a in allowed_archetypes(cls) — the picker then
## lists named guns (variant ids) via Weapon.display_name(). Nothing else in this file needs editing.
static func primary_options(cls: int) -> Array:
	return allowed_archetypes(cls)

## True if a class may take this primary weapon id: its ARCHETYPE is class-allowed AND passes
## can_equip. Archetype-based so it accepts any variant of an allowed archetype once variants exist.
static func is_primary_allowed(cls: int, weapon_id: int) -> bool:
	return (_archetype_of(weapon_id) in allowed_archetypes(cls)) and can_equip(cls, weapon_id)

## Default primary weapon id for a class (AR for every class today). WHEN VARIANTS LAND: change to
## `Weapon.default_variant(allowed_archetypes(cls)[0])` so the default is the category's stock gun.
static func default_primary(cls: int) -> int:
	return primary_options(cls)[0]

## The first gadget option that is actually built (in IMPLEMENTED_GADGETS). Guarantees a working
## default even while later options are still unimplemented.
static func default_gadget(cls: int) -> int:
	for g in gadget_options(cls):
		if g in IMPLEMENTED_GADGETS:
			return g
	return GADGET_C4   # unreachable given every class has an implemented option; safe fallback

## M18 deploy-screen STARTING armor tier (MEDIUM for every class); the player overrides it via the
## loadout. Intentionally differs from the legacy per-class armor_for() below (e.g. MEDIC starts
## MEDIUM here but armor_for(MEDIC)==LIGHT) — see armor_for for why both exist during M18.
static func default_armor(_cls: int) -> int:
	return Armor.MEDIUM

## Deterministic per-player gadget selection (used by both server and bots, so they agree with
## no replication): the ENGINEER alternates C4 / claymore by id parity so the fleet exercises
## both; every other class uses its single gadget. Human deploy-screen selection wires in later
## (M7 client / M12-P3).
static func gadget_for_player(cls: int, id: int) -> int:
	if cls == ENGINEER:
		return GADGET_C4 if (id % 2 == 0) else GADGET_MINE
	return gadget_for(cls)

## Server-authoritative loadout validation: only Engineer may equip the RPG; DMR is Assault-only;
## all other weapons are unrestricted. Loadout-time only (spec §"RPG", §"DMR").
static func secondary_for(_cls: int) -> int:
	return Weapon.PISTOL   # v1: universal sidearm

## Class weapon locks, resolved on the ARCHETYPE (so a variant of a locked archetype is gated the
## same as its base): RPG⇒Engineer, DMR⇒Assault, LMG⇒Support; everything else unrestricted.
static func can_equip(cls: int, weapon_id: int) -> bool:
	var arch := _archetype_of(weapon_id)
	if arch == Weapon.RPG:
		return cls == ENGINEER
	if arch == Weapon.DMR:
		return cls == ASSAULT
	if arch == Weapon.LMG:
		return cls == SUPPORT
	return true

## The Engineer's melee is a sledgehammer: it demolishes structure cells (heavy carve) and bonks
## pawns; every other class carries the universal quick-knife (M5.5-P3, spec §3).
static func has_sledgehammer(cls: int) -> bool:
	return cls == ENGINEER

static func default_attachments() -> Dictionary:
	return {"optic": "iron", "barrel": "standard", "underbarrel": "none_ub"}

## LEGACY class-derived armor tier (M5.5-P2), still used by the server until P1b wires the
## player-picked armor from the loadout. Recon was removed (M12-P1), so the four live classes
## span all three tiers: the mobile Medic runs LIGHT to reach downed teammates, frontline Assault
## takes MEDIUM, and the durable Engineer/Support take HEAVY. This intentionally differs from the
## M18 default_armor() (which starts every class at MEDIUM as a deploy-screen default the player
## then overrides); both coexist during M18.
static func armor_for(cls: int) -> int:
	match cls:
		MEDIC: return Armor.LIGHT
		ENGINEER, SUPPORT: return Armor.HEAVY
		_: return Armor.MEDIUM   # assault (and any unknown)

## Centralized passive class traits ("perks") — the single source the server reads (P1b) and the
## class-select screen displays (P3) so what you see equals what you get. Keys:
##   revive_fast(bool) bandages(int) sledgehammer(bool) blast_mult(float)
##   regen_fast(bool)  grenade_count(int) reserve_mult(float)
static func class_traits(cls: int) -> Dictionary:
	match cls:
		MEDIC:
			return {"revive_fast": true, "bandages": Revive.MEDIC_BANDAGE_COUNT, "sledgehammer": false,
				"blast_mult": 1.0, "regen_fast": false, "grenade_count": 3, "reserve_mult": 1.0}
		ENGINEER:
			return {"revive_fast": false, "bandages": Revive.BANDAGE_COUNT, "sledgehammer": true,
				"blast_mult": 1.2, "regen_fast": false, "grenade_count": 3, "reserve_mult": 1.0}
		SUPPORT:
			return {"revive_fast": false, "bandages": Revive.BANDAGE_COUNT, "sledgehammer": false,
				"blast_mult": 1.0, "regen_fast": false, "grenade_count": 5, "reserve_mult": 1.25}
		_:  # ASSAULT (and unknown)
			return {"revive_fast": false, "bandages": Revive.BANDAGE_COUNT, "sledgehammer": false,
				"blast_mult": 1.0, "regen_fast": true, "grenade_count": 3, "reserve_mult": 1.0}

## Plain-language perk lines for the class-select screen (spec §G) — generated from class_traits so
## the display can never disagree with the sim. Order: signature perk(s) first, then utility.
static func trait_blurbs(cls: int) -> Array:
	var t := class_traits(cls)
	var out: Array = []
	if bool(t["regen_fast"]):
		out.append("Combat Vigor — heals faster after taking damage")
	if bool(t["revive_fast"]):
		out.append("Field Medic — revives teammates faster")
	if int(t["bandages"]) > Revive.BANDAGE_COUNT:
		out.append("Carries %d bandages" % int(t["bandages"]))
	if bool(t["sledgehammer"]):
		out.append("Sledgehammer melee — smashes through structures")
	if float(t["blast_mult"]) > 1.0:
		out.append("Demolitions — +%d%% explosive blast radius" % int(round((float(t["blast_mult"]) - 1.0) * 100.0)))
	if int(t["grenade_count"]) > 3:
		out.append("Ammo Hauler — carries %d grenades" % int(t["grenade_count"]))
	if float(t["reserve_mult"]) > 1.0:
		out.append("Extra reserve ammo")
	# Weapon-access lines (derived from the primary list so they track the matrix).
	if Weapon.DMR in primary_options(cls):
		out.append("Can equip the DMR (marksman)")
	if Weapon.LMG in primary_options(cls):
		out.append("Can equip the LMG (heavy suppression)")
	return out

## A full, valid starting loadout for a class (server per-connection default + client screen seed).
static func default_loadout(cls: int) -> Dictionary:
	return {
		"class": cls,
		"primary": default_primary(cls),
		"secondary": Weapon.PISTOL,
		"gadget": default_gadget(cls),
		"armor": default_armor(cls),
		"grenade": Grenade.FRAG,
		"attachments": default_attachments(),
	}

## THE loadout validation authority — called by BOTH client (grey-out) and server (authoritative).
## Total (never returns an invalid config) and idempotent. `attach` is the Attachment catalog.
static func sanitize(cfg: Dictionary, attach: Attachment) -> Dictionary:
	var cls: int = int(cfg.get("class", ASSAULT))
	if not (cls in [ASSAULT, MEDIC, ENGINEER, SUPPORT]):
		cls = ASSAULT
	var primary: int = int(cfg.get("primary", default_primary(cls)))
	if not is_primary_allowed(cls, primary):
		primary = default_primary(cls)
	var gadget: int = int(cfg.get("gadget", default_gadget(cls)))
	if not ((gadget in gadget_options(cls)) and (gadget in IMPLEMENTED_GADGETS)):
		gadget = default_gadget(cls)
	var armor: int = int(cfg.get("armor", Armor.MEDIUM))
	if not (armor in [Armor.LIGHT, Armor.MEDIUM, Armor.HEAVY]):
		armor = Armor.MEDIUM
	var grenade: int = int(cfg.get("grenade", Grenade.FRAG))
	if not (grenade in [Grenade.FRAG, Grenade.SMOKE, Grenade.FLASHBANG]):
		grenade = Grenade.FRAG
	return {
		"class": cls,
		"primary": primary,
		"secondary": Weapon.PISTOL,   # v1: universal sidearm, never client-chosen
		"gadget": gadget,
		"armor": armor,
		"grenade": grenade,
		"attachments": _sanitize_attachments(cfg.get("attachments", {}), attach),
	}

## Per-slot: keep a chosen attachment only if the catalog knows it AND it belongs to that slot;
## otherwise fall back to the slot default. Guarantees all three slots present + valid.
static func _sanitize_attachments(raw, attach: Attachment) -> Dictionary:
	var defaults := default_attachments()
	var out := {}
	if not (raw is Dictionary):
		raw = {}
	for slot in Attachment.SLOTS:
		var chosen := String((raw as Dictionary).get(slot, ""))
		if chosen != "" and attach != null and attach.slot_of(chosen) == slot:
			out[slot] = chosen
		else:
			out[slot] = String(defaults[slot])
	return out

static func random_class() -> int:
	return randi() % 4

## Class roll for HUMAN players — never ENGINEER. The engineer's RPG-primary variant is a
## bot-fleet anti-vehicle device and reads as a broken weapon to a human; excluding the class
## outright keeps every human loadout a normal click-fire gun. Bots still use random_class().
static func random_class_no_engineer() -> int:
	var pool := [ASSAULT, MEDIC, SUPPORT]
	return pool[randi() % pool.size()]
