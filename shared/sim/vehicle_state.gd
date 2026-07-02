class_name VehicleState
extends RefCounted
## Replicated view of one vehicle. Vehicle snapshots are maps of vid -> VehicleState.

var pos: Vector3 = Vector3.ZERO
var heading: float = 0.0       # body yaw
var turret_yaw: float = 0.0
var hp: int = 0
var type: int = 0
var seats: Array = []          # seat-index -> occupant pawn id (0 = empty)

# Wire-quantized field cache — same design as EntityState.bake(): the delta encoder used to
# quantize baseline+current per field per client-send, then re-quantize on write (~3x). bake()
# computes each value once per fresh state; encode diffs/writes cached ints. Bit-identical.
var q_baked: bool = false
var q_px: int = 0
var q_py: int = 0
var q_pz: int = 0
var q_heading: int = 0
var q_turret: int = 0

func bake() -> void:
	q_px = Quantize.enc_pos(pos.x)
	q_py = Quantize.enc_pos(pos.y)
	q_pz = Quantize.enc_pos(pos.z)
	q_heading = Quantize.enc_angle(heading)
	q_turret = Quantize.enc_angle(turret_yaw)
	q_baked = true

func clone() -> VehicleState:
	var e := VehicleState.new()
	e.pos = pos
	e.heading = heading
	e.turret_yaw = turret_yaw
	e.hp = hp
	e.type = type
	e.seats = seats.duplicate()
	return e
