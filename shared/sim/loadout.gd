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

## Primary-weapon archetypes selectable per class (spec §A matrix).
static func primary_options(cls: int) -> Array:
	match cls:
		ASSAULT: return [Weapon.AR, Weapon.SMG, Weapon.DMR]
		SUPPORT: return [Weapon.AR, Weapon.SMG, Weapon.LMG]
		_: return [Weapon.AR, Weapon.SMG]   # medic, engineer

## True if a class may take this primary: it's in the class's archetype list AND passes can_equip.
static func is_primary_allowed(cls: int, weapon_id: int) -> bool:
	return (weapon_id in primary_options(cls)) and can_equip(cls, weapon_id)

## First primary archetype (AR for every class today).
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

static func can_equip(cls: int, weapon_id: int) -> bool:
	if weapon_id == Weapon.RPG:
		return cls == ENGINEER
	if weapon_id == Weapon.DMR:
		return cls == ASSAULT
	if weapon_id == Weapon.LMG:
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

static func random_class() -> int:
	return randi() % 4

## Class roll for HUMAN players — never ENGINEER. The engineer's RPG-primary variant is a
## bot-fleet anti-vehicle device and reads as a broken weapon to a human; excluding the class
## outright keeps every human loadout a normal click-fire gun. Bots still use random_class().
static func random_class_no_engineer() -> int:
	var pool := [ASSAULT, MEDIC, SUPPORT]
	return pool[randi() % pool.size()]
