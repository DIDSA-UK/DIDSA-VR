extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as
## tests/section_render.gd):
##   UI_LAB_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/ui_lab_render.gd
## Loads the UI Lab scene (res://lab/ui_lab.tscn), renders it, saves a PNG to
## $UI_LAB_DIR (default user://) for eyeballing, and checks the look's own claims:
## a toggled-on button is visibly different from a resting one, the panel is
## the theme's panel colour, a disabled button is dimmer than an enabled one.
## Like look_render.gd the sandbox renders through GL compatibility, not the
## project's "mobile" renderer, so this is a layout/colour smoke test, not a
## calibration of the headset look.

func _find(n: Node, pred: Callable) -> Node:
	if pred.call(n):
		return n
	for c in n.get_children():
		var f := _find(c, pred)
		if f:
			return f
	return null

func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

func _initialize() -> void:
	root.size = Vector2i(1600, 900)
	var lab: Control = load("res://lab/ui_lab.tscn").instantiate()
	root.add_child(lab)
	for i in 6:
		await process_frame
	var img := root.get_texture().get_image()
	var dir := OS.get_environment("UI_LAB_DIR")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		img.save_png(dir.path_join("ui_lab.png"))
	var tokens: Resource = lab.tokens
	var on_btn: Button = _find(lab, func(n): return n is Button and n.text == "Concentric")
	var off_btn: Button = _find(lab, func(n): return n is Button and n.text == "Parallel")
	var dis_btn: Button = _find(lab, func(n): return n is Button and n.text == "Disabled")
	var create: Button = _find(lab, func(n): return n is Button and n.text == "Create mate")
	print("SMOKE the lab built from the theme resource (tokens + a Theme): ", tokens != null and lab.theme != null)
	print("SMOKE a toggled-on button reads as pressed: ", on_btn.button_pressed and not off_btn.button_pressed)
	var p_on := img.get_pixelv(Vector2i(on_btn.get_global_rect().position) + Vector2i(14, 14))
	var p_off := img.get_pixelv(Vector2i(off_btn.get_global_rect().position) + Vector2i(14, 14))
	print("SMOKE ...and is drawn in a different fill from a resting one: ", not p_on.is_equal_approx(p_off))
	var p_dis := img.get_pixelv(Vector2i(dis_btn.get_global_rect().position) + Vector2i(14, 14))
	print("SMOKE a disabled button is darker than an enabled one: ", _luma(p_dis) < _luma(p_off))
	var p_acc := img.get_pixelv(Vector2i(create.get_global_rect().position) + Vector2i(14, 14))
	print("SMOKE the accent button is the brightest control: ", _luma(p_acc) > _luma(p_off) and _luma(p_acc) > _luma(p_on))
	var panel_px := img.get_pixelv(Vector2i(60, 60))
	print("SMOKE the panel is drawn in the theme's panel colour: ", panel_px.is_equal_approx(tokens.bg_panel) or absf(panel_px.r - tokens.bg_panel.r) < 0.03)
	quit()
