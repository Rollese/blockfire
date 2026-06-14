class_name Stance
extends Object
## Stance + lean enums and per-stance geometry/movement params. See M2 spec.

enum { STAND = 0, CROUCH = 1, PRONE = 2 }
enum { LEAN_NONE = 0, LEAN_LEFT = 1, LEAN_RIGHT = 2 }

const BODY_RADIUS := 0.35
const HEAD_RADIUS := 0.15
const LEAN_OFFSET := 0.4   # metres the shot origin shifts when leaning

static func speed(stance: int) -> float:
	match stance:
		CROUCH: return 3.0
		PRONE: return 1.2
		_: return 6.0

static func eye_height(stance: int) -> float:
	match stance:
		CROUCH: return 1.1
		PRONE: return 0.45
		_: return 1.6

static func body_height(stance: int) -> float:
	match stance:
		CROUCH: return 1.2
		PRONE: return 0.5
		_: return 1.8

static func head_center(stance: int) -> float:
	match stance:
		CROUCH: return 1.15
		PRONE: return 0.45
		_: return 1.70
