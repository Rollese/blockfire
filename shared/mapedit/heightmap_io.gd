class_name HeightmapIO
extends RefCounted
## Heightmap file I/O for the M22 map editor. Normalised 0..1 samples <-> image file, row-major
## (z outer / x inner) matching TerrainGrid.samples: index zi*cols+xi == image pixel (xi, zi).
## Denormalisation to metres (height_min + r*height_scale) stays in terrain.gd — not duplicated here.
##
## FORMAT: we save float32 EXR, NOT 16-bit PNG. Probed on Godot 4.7: Image.load() of a true
## bitdepth-16 greyscale PNG returns FORMAT_L8 with 8-bit-truncated values, and save_png() on a
## FORMAT_RH image silently downconverts to RGB8 — PNG cannot carry sub-8-bit-quantum height in this
## engine. EXR FORMAT_RF round-trips losslessly (worst error 3e-8). The old 8-bit PNG path gave 256
## levels = a 9.4 cm quantum at conquest_town's height_scale 24.0 = the visible stair-stepping.
## Legacy 8-bit PNG maps still LOAD (load_norm branches on the actual image format), so no map breaks.
## See docs/superpowers/specs/2026-07-16-map-editor-design.md §5.1.

## Write normalised 0..1 samples as a float32 EXR. Returns an Error code.
static func save_exr_norm(norm: PackedFloat32Array, cols: int, rows: int, path: String) -> int:
	if cols <= 0 or rows <= 0 or norm.size() != cols * rows:
		push_error("[heightmap_io] save: expected %d samples, got %d" % [cols * rows, norm.size()])
		return ERR_INVALID_DATA
	var img := Image.create(cols, rows, false, Image.FORMAT_RF)
	for zi in rows:
		for xi in cols:
			var v := norm[zi * cols + xi]
			img.set_pixel(xi, zi, Color(v, 0.0, 0.0))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	# grayscale=false: the grayscale writer path is lossier and we want the exact float back.
	return img.save_exr(path, false)

## Read any supported heightmap (EXR float or legacy 8-bit PNG) as normalised 0..1 samples.
## Returns an empty array on failure. Reads the red channel — matching terrain.gd::build_grid.
static func load_norm(path: String) -> PackedFloat32Array:
	var img := Image.new()
	if img.load(path) != OK:
		push_error("[heightmap_io] failed to load %s" % path)
		return PackedFloat32Array()
	return image_to_norm(img)

## Image -> normalised samples. Split out so callers holding an Image (e.g. a preloaded resource)
## can reuse it without a second disk read.
static func image_to_norm(img: Image) -> PackedFloat32Array:
	var cols := img.get_width()
	var rows := img.get_height()
	var out := PackedFloat32Array()
	out.resize(cols * rows)
	for zi in rows:
		for xi in cols:
			out[zi * cols + xi] = img.get_pixel(xi, zi).r
	return out
