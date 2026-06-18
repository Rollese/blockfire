class_name Loadout
extends Object
## Class -> weapon + gadget + default attachments mapping. Gadget identity per spec
## §"Class gadget assignment"; RPG is an Engineer-only weapon-slot choice (can_equip gate).

enum { ASSAULT = 0, MEDIC = 1, ENGINEER = 2, SUPPORT = 3, RECON = 4 }

# Gadget kinds owned by a class (mirror Gadget.Kind values; kept here so loadout has no hard dep
# on the Gadget catalog). GADGET_NONE = class has no active gadget in v1.
const GADGET_NONE := -1
const GADGET_C4 := 0
const GADGET_MINE := 1
const GADGET_HEAL := 3
const GADGET_AMMO := 4

static func weapon_for(cls: int) -> int:
	match cls:
		ENGINEER: return Weapon.SMG
		RECON: return Weapon.DMR
		_: return Weapon.AR   # assault/medic/support

static func gadget_for(cls: int) -> int:
	match cls:
		ENGINEER: return GADGET_C4
		RECON: return GADGET_MINE
		MEDIC: return GADGET_HEAL
		SUPPORT: return GADGET_AMMO
		_: return GADGET_NONE   # assault (frag/smoke are M4 grenades, not a gadget slot)

## The gadgets a class may choose between at the deploy screen. ENGINEER picks one of
## C4 / claymore; every other class has a single gadget (or none).
static func gadget_options(cls: int) -> Array:
	match cls:
		ENGINEER: return [GADGET_C4, GADGET_MINE]
		MEDIC: return [GADGET_HEAL]
		SUPPORT: return [GADGET_AMMO]
		_: return [GADGET_NONE]   # assault

static func is_valid_gadget(cls: int, gadget: int) -> bool:
	return gadget in gadget_options(cls)

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
static func can_equip(cls: int, weapon_id: int) -> bool:
	if weapon_id == Weapon.RPG:
		return cls == ENGINEER
	if weapon_id == Weapon.DMR:
		return cls == ASSAULT
	return true

static func default_attachments() -> Dictionary:
	return {"optic": "iron", "barrel": "standard", "underbarrel": "none_ub"}

static func random_class() -> int:
	return randi() % 5

## Class roll for HUMAN players — never ENGINEER. The engineer's RPG-primary variant is a
## bot-fleet anti-vehicle device and reads as a broken weapon to a human; excluding the class
## outright keeps every human loadout a normal click-fire gun. Bots still use random_class().
static func random_class_no_engineer() -> int:
	var pool := [ASSAULT, MEDIC, SUPPORT, RECON]
	return pool[randi() % pool.size()]
