class_name EntityState
extends RefCounted
## The replicated view of one entity. Snapshots are maps of id -> EntityState.

var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var stance: int = 0   # Stance.STAND/CROUCH/PRONE
var lean: int = 0     # Stance.LEAN_*
var team: int = 0
var alive: bool = true
var health: int = 100
var is_downed: bool = false
var climbing: bool = false
var squad: int = 0
var armor_class: int = 0   # M5.5-P2 tier (LIGHT/MEDIUM/HEAVY); immutable per life, replicated on ENTER
var weapon: int = 0        # equipped weapon id (Weapon.AR/SMG/DMR/RPG/PISTOL); replicated on ENTER for the held-weapon silhouette

# Wire-quantized field cache (server-send hot path). The delta encoder used to quantize
# every entity's fields ~3× per client-send (twice in _diff_mask for baseline+current, again
# in _put_fields for current); at 128 clustered pawns that dominated the tick. bake() computes
# each quantized value ONCE per fresh state; the encoder then diffs/writes cached ints. Bit-
# identical to on-the-fly quantization. `q_baked` guards single computation (state_map builds a
# fresh EntityState per tick → baked once, shared across every client's send that tick).
var q_baked: bool = false
var q_px: int = 0
var q_py: int = 0
var q_pz: int = 0
var q_yaw: int = 0
var q_pitch: int = 0
var q_state: int = 0

func bake() -> void:
	q_px = Quantize.enc_pos(pos.x)
	q_py = Quantize.enc_pos(pos.y)
	q_pz = Quantize.enc_pos(pos.z)
	q_yaw = Quantize.enc_angle(yaw)
	q_pitch = Quantize.enc_angle(pitch)
	q_state = (stance & 3) | ((lean & 3) << 2) | ((1 if team != 0 else 0) << 4) \
		| ((1 if alive else 0) << 5) | ((1 if is_downed else 0) << 6) \
		| ((1 if climbing else 0) << 7)
	q_baked = true

func clone() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	e.pitch = pitch
	e.stance = stance
	e.lean = lean
	e.team = team
	e.alive = alive
	e.health = health
	e.is_downed = is_downed
	e.climbing = climbing
	e.squad = squad
	e.armor_class = armor_class
	e.weapon = weapon
	return e
