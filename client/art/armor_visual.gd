class_name ArmorVisual
extends Object
## Presentation-only: tints a procedural soldier's vest (torso) + helmet by armor tier (M5.5-P2),
## so a heavier-armored player reads as bulkier/darker. NOT team identity — that stays the blue
## friend triangle (BattleBit-style); tier shades are greys/olive, never the team blue/red.
## Shared static materials (3, reused across all entities) so apply() allocates nothing per call.
## See docs/superpowers/specs/2026-06-24-firemode-armor-fx-design.md.

# tier -> vest albedo (LIGHT brighter/lighter, HEAVY darker/heavier)
const _VEST := {
	Armor.LIGHT:  Color(0.55, 0.52, 0.45),   # light tan
	Armor.MEDIUM: Color(0.38, 0.40, 0.34),   # olive
	Armor.HEAVY:  Color(0.20, 0.22, 0.25),   # dark slate plate
}
# tier -> helmet scale (HEAVY = bulkier helmet)
const _HELMET_SCALE := {Armor.LIGHT: 0.8, Armor.MEDIUM: 1.0, Armor.HEAVY: 1.35}

static var _vest_mats: Dictionary = {}     # tier -> StandardMaterial3D (lazy, shared)

static func _vest_material(tier: int) -> StandardMaterial3D:
	if not _vest_mats.has(tier):
		var m := StandardMaterial3D.new()
		m.albedo_color = _VEST.get(tier, _VEST[Armor.MEDIUM])
		m.roughness = 0.85
		_vest_mats[tier] = m
	return _vest_mats[tier] as StandardMaterial3D

## Apply the tier look to a built soldier node. Idempotent; safe on any node (GLB / LOD-shed parts
## just won't have the named children, and apply() no-ops on them). The renderer calls this only when
## a (pooled) node's tier changes.
static func apply(node: Node3D, tier: int) -> void:
	if node == null:
		return
	var torso := node.find_child("Torso", true, false)
	if torso is MeshInstance3D:
		(torso as MeshInstance3D).material_override = _vest_material(tier)
	var helmet := node.find_child("Helmet", true, false)
	if helmet is MeshInstance3D:
		(helmet as MeshInstance3D).scale = Vector3.ONE * float(_HELMET_SCALE.get(tier, 1.0))
