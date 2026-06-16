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

## Server-authoritative loadout validation: only Engineer may equip the RPG; all other weapons
## are unrestricted. Loadout-time only (spec §"RPG").
static func can_equip(cls: int, weapon_id: int) -> bool:
	if weapon_id == Weapon.RPG:
		return cls == ENGINEER
	return true

static func default_attachments() -> Dictionary:
	return {"optic": "iron", "barrel": "standard", "underbarrel": "none_ub"}

static func random_class() -> int:
	return randi() % 5
