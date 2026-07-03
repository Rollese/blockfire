extends TestCase

func test_load_menu_textures() -> void:
	var logo := MenuArt.load_texture("res://client/art/menu/blockfire_logo.png")
	assert_true(logo != null, "logo texture loads")
	assert_gt(logo.get_width(), 0)
	var bg := MenuArt.load_texture("res://client/art/menu/menu_background.png")
	assert_true(bg != null, "background texture loads")
	assert_gt(bg.get_width(), 0)
