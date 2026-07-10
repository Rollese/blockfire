class_name SnapshotColumns
extends Object
## Columnar wire-state extraction for the native snapshot encoder (ADR-0003).
## Lane order is the FFI contract with native/snapshot_encoder/src/core.rs — change both or neither.
## health/squad (and vehicle hp) are stored RAW; the encoder clamps/masks at write time,
## matching Snapshot._put_fields exactly.

const PAWN_STRIDE := 10
const VEH_STRIDE := 7

static func extract_pawns(world: World, weapon_by_id: Dictionary,
		out_ids: PackedInt32Array, out_fields: PackedInt32Array) -> void:
	var n := world.pawns.size()
	out_ids.resize(n)
	out_fields.resize(n * PAWN_STRIDE)
	var i := 0
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		out_ids[i] = id
		var o := i * PAWN_STRIDE
		out_fields[o + 0] = Quantize.enc_pos(p.pos.x)
		out_fields[o + 1] = Quantize.enc_pos(p.pos.y)
		out_fields[o + 2] = Quantize.enc_pos(p.pos.z)
		out_fields[o + 3] = Quantize.enc_angle(p.yaw)
		out_fields[o + 4] = Quantize.enc_angle(p.pitch)
		out_fields[o + 5] = (p.stance & 3) | ((p.lean & 3) << 2) \
			| ((1 if p.team != 0 else 0) << 4) | ((1 if p.alive else 0) << 5) \
			| ((1 if p.is_downed else 0) << 6) | ((1 if p.climbing else 0) << 7)
		out_fields[o + 6] = p.health
		out_fields[o + 7] = p.squad
		out_fields[o + 8] = p.armor_class
		out_fields[o + 9] = int(weapon_by_id.get(id, 0))
		i += 1

static func extract_vehicles(world: World, out_vids: PackedInt32Array, out_vfields: PackedInt32Array,
		out_vseats: PackedInt32Array, out_vseat_off: PackedInt32Array) -> void:
	var n := world.vehicles.size()
	out_vids.resize(n)
	out_vfields.resize(n * VEH_STRIDE)
	out_vseat_off.resize(n + 1)
	var total := 0
	for vid in world.vehicles:
		total += (world.vehicles[vid] as Vehicle).seats.size()
	out_vseats.resize(total)
	var i := 0
	var so := 0
	for vid in world.vehicles:
		var v: Vehicle = world.vehicles[vid]
		out_vids[i] = vid
		var o := i * VEH_STRIDE
		out_vfields[o + 0] = Quantize.enc_pos(v.pos.x)
		out_vfields[o + 1] = Quantize.enc_pos(v.pos.y)
		out_vfields[o + 2] = Quantize.enc_pos(v.pos.z)
		out_vfields[o + 3] = Quantize.enc_angle(v.heading)
		out_vfields[o + 4] = Quantize.enc_angle(v.turret_yaw)
		out_vfields[o + 5] = v.hp
		out_vfields[o + 6] = v.type
		out_vseat_off[i] = so
		for s in v.seats:
			out_vseats[so] = int(s)
			so += 1
		i += 1
	out_vseat_off[n] = so
