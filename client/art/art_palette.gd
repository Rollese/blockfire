class_name ArtPalette
extends Object
## Single source of truth for the procedural art kit's materials and tints. Presentation-only
## (AGENTS.md §7). TEAM_COLOR matches world_renderer's marker/beacon blue/red; player models are
## NOT team-tinted (UNIFORM) and FRIENDLY is an intentionally brighter blue for the friend marker.
## Low-poly look: lit, high-roughness matte (no metallic) so blocky forms still catch scene lighting/shadows.

const TEAM_COLOR := [Color(0.2, 0.5, 1.0), Color(1.0, 0.3, 0.2)]  # [team0=blue, team1=red] (markers/beacons)
const NEUTRAL := Color(0.6, 0.6, 0.6)
const GUN_METAL := Color(0.08, 0.08, 0.08)
const STRUCT_CONCRETE := Color(0.62, 0.62, 0.60)
const STRUCT_METAL_THIN := Color(0.45, 0.40, 0.30)
const STRUCT_SAND := Color(0.76, 0.66, 0.45)      # warm sandbag tan (LMG-nest parapet; r>g>b)
# Player models are NOT team-tinted (BattleBit-style): everyone wears the same muted uniform and
# friend/foe is read from the FRIENDLY marker above friendlies' heads, not from body colour.
const UNIFORM := Color(0.30, 0.32, 0.28)          # muted olive-grey — same for all players
const FRIENDLY := Color(0.25, 0.60, 1.0)          # blue friend-marker above teammates

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

## The shared player uniform — identical for every player (no team tint; friend/foe is the marker).
static func uniform_material() -> StandardMaterial3D:
	return _flat(UNIFORM)

static func structure_material(base_color: Color, bucket: int) -> StandardMaterial3D:
	return _flat(damage_tint(base_color, bucket))

## Darken a base color as the damage bucket drops (3 pristine .. 0 heavy). Pure.
static func damage_tint(base: Color, bucket: int) -> Color:
	var factor: float = [0.45, 0.65, 0.82, 1.0][clampi(bucket, 0, 3)]
	return Color(base.r * factor, base.g * factor, base.b * factor, base.a)
