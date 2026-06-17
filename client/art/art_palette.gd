class_name ArtPalette
extends Object
## Single source of truth for the procedural art kit's materials and tints. Presentation-only
## (AGENTS.md §7). Colors mirror world_renderer.TEAM_COLOR so kit + placeholder match during the
## P2 swap. Low-poly look: lit, high-roughness matte (no metallic) so blocky forms still catch scene lighting/shadows.

const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red]
const NEUTRAL := Color(0.6, 0.6, 0.6)
const GUN_METAL := Color(0.08, 0.08, 0.08)
const STRUCT_CONCRETE := Color(0.62, 0.62, 0.60)
const STRUCT_METAL_THIN := Color(0.45, 0.40, 0.30)

static func _flat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	m.metallic = 0.0
	return m

static func team_material(team: int) -> StandardMaterial3D:
	if team < 0 or team >= TEAM_COLOR.size():
		return _flat(NEUTRAL)
	return _flat(TEAM_COLOR[team])

static func gun_material() -> StandardMaterial3D:
	return _flat(GUN_METAL)

static func structure_material(base_color: Color, bucket: int) -> StandardMaterial3D:
	return _flat(damage_tint(base_color, bucket))

## Darken a base color as the damage bucket drops (3 pristine .. 0 heavy). Pure.
static func damage_tint(base: Color, bucket: int) -> Color:
	var factor: float = [0.45, 0.65, 0.82, 1.0][clampi(bucket, 0, 3)]
	return Color(base.r * factor, base.g * factor, base.b * factor, base.a)
