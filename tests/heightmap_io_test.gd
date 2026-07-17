extends TestCase
const HeightmapIO := preload("res://shared/mapedit/heightmap_io.gd")

const TMP := "user://m22_heightmap_io_test"

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)

func teardown() -> void:
	var d := DirAccess.open(TMP)
	if d != null:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			d.remove(TMP.path_join(f))
			f = d.get_next()
		d.list_dir_end()

# A fine ramp: adjacent samples differ by far less than an 8-bit quantum (1/255 = 0.00392).
func _ramp(n: int) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(n * n)
	for i in n * n:
		h[i] = float(i) / float(n * n - 1)
	return h

func test_exr_round_trip_is_lossless() -> void:
	var src := _ramp(16)
	var path := TMP.path_join("rt.exr")
	assert_eq(HeightmapIO.save_exr_norm(src, 16, 16, path), OK, "save succeeds")
	var back := HeightmapIO.load_norm(path)
	assert_eq(back.size(), 256, "sample count round-trips")
	var worst := 0.0
	for i in 256:
		worst = maxf(worst, absf(back[i] - src[i]))
	assert_true(worst < 0.0001, "EXR float round-trip worst error %f < 0.0001" % worst)

func test_exr_beats_the_8bit_quantum() -> void:
	# Two samples 1/1000 apart -> INDISTINGUISHABLE in 8-bit (quantum 1/255), distinct in EXR.
	var src := PackedFloat32Array([0.5, 0.501, 0.5, 0.501])
	var path := TMP.path_join("fine.exr")
	HeightmapIO.save_exr_norm(src, 2, 2, path)
	var back := HeightmapIO.load_norm(path)
	assert_true(absf(back[1] - back[0]) > 0.0005, "a sub-8-bit-quantum step survives the round-trip")

func test_legacy_8bit_png_still_loads() -> void:
	# Back-compat: every existing map is an 8-bit PNG and must keep loading.
	var img := Image.create(4, 4, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	img.set_pixel(0, 0, Color(1, 1, 1))
	var path := TMP.path_join("legacy.png")
	assert_eq(img.save_png(path), OK, "fixture saved")
	var back := HeightmapIO.load_norm(path)
	assert_eq(back.size(), 16, "png sample count")
	assert_almost_eq(back[0], 1.0, 0.01, "white pixel -> 1.0")
	assert_almost_eq(back[5], 0.5, 0.01, "mid-grey pixel -> ~0.5")

func test_load_missing_file_returns_empty() -> void:
	tolerate_runtime_errors()   # the module push_error()s on a bad path by design
	var back := HeightmapIO.load_norm(TMP.path_join("nope.exr"))
	assert_eq(back.size(), 0, "missing file -> empty array, no crash")

func test_row_major_layout_matches_terrain_grid() -> void:
	# index = zi * cols + xi, i.e. image pixel (xi, zi). Guards against a transpose bug.
	var src := PackedFloat32Array([0.0, 0.0, 1.0, 0.0])   # cols=2: (xi=0,zi=1) is the 1.0
	var path := TMP.path_join("layout.exr")
	HeightmapIO.save_exr_norm(src, 2, 2, path)
	var img := Image.new()
	assert_eq(img.load(path), OK, "reload as image")
	assert_almost_eq(img.get_pixel(0, 1).r, 1.0, 0.001, "sample[zi=1*cols+xi=0] wrote pixel (x=0, y=1)")
	assert_almost_eq(img.get_pixel(1, 0).r, 0.0, 0.001, "pixel (x=1, y=0) is untouched")
