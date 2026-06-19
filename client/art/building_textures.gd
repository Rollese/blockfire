class_name BuildingTextures
extends Object
## Procedural, grayscale tiling textures for building pieces (concrete / brick / metal / wood). Drawn
## from math (no external assets), cached, and tinted by the piece's albedo_color in BuildingKit. Each
## tile is ~1m square in world space; building_kit sets uv1_scale so it tiles across a piece face.
## Presentation-only (AGENTS.md §7).

const SIZE := 64
static var _cache: Dictionary = {}

## Cached grayscale Texture2D for a material kind. Unknown kind -> concrete.
static func tex(kind: String) -> Texture2D:
	if _cache.has(kind):
		return _cache[kind]
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind)
	match kind:
		"brick": _brick(img, rng)
		"metal": _metal(img, rng)
		"wood": _wood(img, rng)
		_: _concrete(img, rng)
	var t := ImageTexture.create_from_image(img)
	_cache[kind] = t
	return t

static func _v(img: Image, x: int, y: int, v: float) -> void:
	img.set_pixel(x, y, Color(v, v, v))

## Light gray with fine speckle.
static func _concrete(img: Image, rng: RandomNumberGenerator) -> void:
	for y in SIZE:
		for x in SIZE:
			_v(img, x, y, 0.86 + rng.randf_range(-0.05, 0.05))

## Running-bond brick: light bricks, darker mortar lines, alternate-row offset.
static func _brick(img: Image, rng: RandomNumberGenerator) -> void:
	var bh := 10   # brick row height (px)
	var bw := 22   # brick length (px)
	for y in SIZE:
		var row := y / bh
		var off := (bw / 2) if (row % 2 == 1) else 0
		for x in SIZE:
			var mortar := (y % bh) == 0 or ((x + off) % bw) == 0
			if mortar:
				_v(img, x, y, 0.5)
			else:
				_v(img, x, y, 0.92 + rng.randf_range(-0.05, 0.0))

## Vertical metal panels with seam lines + faint vertical streaks.
static func _metal(img: Image, rng: RandomNumberGenerator) -> void:
	var pw := 12   # panel width (px)
	for y in SIZE:
		for x in SIZE:
			var seam := (x % pw) == 0
			var base := 0.78 + rng.randf_range(-0.02, 0.02)
			_v(img, x, y, 0.55 if seam else base)

## Horizontal planks with seam lines + lengthwise grain.
static func _wood(img: Image, rng: RandomNumberGenerator) -> void:
	var ph := 9   # plank height (px)
	for y in SIZE:
		var seam := (y % ph) == 0
		for x in SIZE:
			var grain := 0.04 * sin(float(x) * 0.6 + float(y / ph))
			_v(img, x, y, (0.55 if seam else 0.86 + grain) + rng.randf_range(-0.02, 0.02))
