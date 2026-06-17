class_name PreviewDriver
extends Node3D
## Standalone art-kit preview. Run: godot --path . client/art/preview/kit_preview.tscn
## Lays out every kit variant in a grid for the owner's visual sign-off. No server/autoload needed.

const SPACING := 3.0

## Pure catalog of every variant to show: [{kind, label, node}]. Unit-tested.
static func build_catalog() -> Array:
	var items: Array = []
	for team in [0, 1]:
		items.append({"kind": "character", "label": "soldier t%d" % team, "node": CharacterKit.build(team)})
	for w in [Weapon.AR, Weapon.SMG, Weapon.DMR, Weapon.RPG]:
		items.append({"kind": "weapon", "label": "weapon %d" % w, "node": WeaponKit.build(w)})
	for team in [0, 1]:
		items.append({"kind": "vehicle", "label": "transport t%d" % team, "node": VehicleKit.build("transport", team)})
	for piece in ["wall", "sandbag"]:
		for bucket in [3, 2, 1, 0]:
			items.append({"kind": "structure", "label": "%s b%d" % [piece, bucket], "node": StructureKit.build(piece, bucket)})
	for p in ["crate", "barrel", "barrier"]:
		items.append({"kind": "prop", "label": p, "node": PropKit.build(p)})
	return items

func _ready() -> void:
	var items := build_catalog()
	var per_row := 6
	for i in items.size():
		var node: Node3D = items[i]["node"]
		node.position = Vector3((i % per_row) * SPACING, 0.0, (i / per_row) * SPACING)
		add_child(node)
		var label := Label3D.new()
		label.text = String(items[i]["label"])
		label.position = node.position + Vector3(0, 2.6, 0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(label)
