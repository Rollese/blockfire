extends Node
## Entry point for all three roles. Selects client / server / bot driver from CLI
## args passed after `--`. See docs/adr/0002-project-structure.md.
##
##   godot --headless --path . -- --server [--port=N]
##   godot --headless --path . -- --bots --bot-count=N [--connect=ip] [--port=N]
##   godot --path . --             (default: client)

func _ready() -> void:
	var args := _parse_args()
	var role := _select_role(args)
	var role_node: Node
	match role:
		"server":
			role_node = preload("res://server/server_main.gd").new()
		"bots":
			role_node = preload("res://bots/bot_driver.gd").new()
		_:
			role_node = preload("res://client/client_main.gd").new()
	role_node.name = "Role"
	if role_node.has_method("configure"):
		role_node.configure(args)
	add_child(role_node)
	print("[boot] role=%s" % role)


func _parse_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var body := arg.substr(2)
		var eq := body.find("=")
		if eq == -1:
			out[body] = true
		else:
			out[body.substr(0, eq)] = body.substr(eq + 1)
	return out


func _select_role(args: Dictionary) -> String:
	if args.has("server"):
		return "server"
	if args.has("bots"):
		return "bots"
	return "client"
