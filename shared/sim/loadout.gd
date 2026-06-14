class_name Loadout
extends Object
## Minimal class -> weapon mapping for M2. Gadgets/abilities are deferred.

enum { ASSAULT = 0, MEDIC = 1, ENGINEER = 2, SUPPORT = 3, RECON = 4 }

static func weapon_for(cls: int) -> int:
	match cls:
		ENGINEER: return Weapon.SMG
		RECON: return Weapon.DMR
		_: return Weapon.AR   # assault/medic/support

static func random_class() -> int:
	return randi() % 5
