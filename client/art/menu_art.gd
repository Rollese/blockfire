class_name MenuArt
extends Object
## Load menu textures. Uses Godot's importer when available; falls back to Image.load_from_file
## so art still appears on a fresh checkout before `godot --import` has been run.

static func load_texture(res_path: String) -> Texture2D:
	var tex := load(res_path) as Texture2D
	if tex != null:
		return tex
	var abs := ProjectSettings.globalize_path(res_path)
	if abs == "" or not FileAccess.file_exists(abs):
		push_warning("[MenuArt] missing file: %s" % res_path)
		return null
	var img := Image.load_from_file(abs)
	if img == null or img.is_empty():
		push_warning("[MenuArt] failed to decode: %s" % res_path)
		return null
	return ImageTexture.create_from_image(img)
