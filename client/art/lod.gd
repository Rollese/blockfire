class_name Lod
extends Object
## Distance level-of-detail for rendered entities (soldiers). Presentation-only (AGENTS.md §7).
## Configures Godot's built-in per-GeometryInstance3D visibility_range so small body parts cull
## with distance and the whole body demotes to one proxy box far away — the engine does the actual
## culling. All logic here is pure property-config + a pure cost proxy, so it is headless-testable.

# Camera->part distance thresholds, metres. Tunable at playtest.
const MID_END := 35.0     # tier-1 detail parts (helmet/gun/arms/head) cull beyond this
const FAR_BEGIN := 70.0   # tier-0 body parts cull here; the LodProxy box takes over

# Small detail parts (tier 1). Everything else — incl. unknown/imported mesh names — is tier 0 (body).
const DETAIL_PARTS := ["Helmet", "GunMount", "ArmL", "ArmR", "Head"]

## LOD level for a camera distance: 0 = full, 1 = body-only (detail shed), 2 = proxy box.
static func level_for(distance: float) -> int:
	if distance >= FAR_BEGIN:
		return 2
	if distance >= MID_END:
		return 1
	return 0

## Tier for a mesh by name: 1 = small detail (culls at MID_END), 0 = body/silhouette (culls at FAR_BEGIN).
static func tier_of(part_name: String) -> int:
	return 1 if DETAIL_PARTS.has(part_name) else 0
