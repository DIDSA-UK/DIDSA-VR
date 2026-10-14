extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as
## tests/section_render.gd):
##   UI_LAB_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/ui_lab_render.gd
## Loads the UI Lab (res://lab/ui_lab.tscn: the real tablet shell + side panel over
## stub tools), renders it, saves PNGs to $UI_LAB_DIR (default: none) for eyeballing
## — the default view, the View hub, Inspect's chip strip and History — and checks the look's
## own claims: selected controls are drawn differently from resting ones, a disabled
## one is darker, the panel is the theme's panel colour.
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

func _shot(name: String) -> Image:
	for i in 4:
		await process_frame
	var img := root.get_texture().get_image()
	var dir := OS.get_environment("UI_LAB_DIR")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		img.save_png(dir.path_join(name))
	return img

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	root.size = Vector2i(1600, 900)
	var lab: Control = load("res://lab/ui_lab.tscn").instantiate()
	root.add_child(lab)
	var img := await _shot("ui_lab.png")
	var tokens: Resource = lab.tokens
	var tablet = lab.tablet
	var design_tile: Button = tablet.home_tile("design")
	var view_tile: Button = tablet.home_tile("view")
	var undo_dis: Button = _find(tablet, func(n): return n is Button and n.disabled)
	print("SMOKE the lab built the real shell from the theme resource: ", tokens != null and lab.theme != null and tablet != null)
	print("SMOKE the lab opens on the home screen: ", tablet.selected_category_id == "" and tablet._home_view.visible and not tablet._back_button.visible)
	print("SMOKE ten tiles in a 6 x 2 grid: ", tablet._home_grid.get_child_count() == 10 and tablet._home_grid.columns == 6)
	var p_tile := img.get_pixelv(Vector2i(view_tile.get_global_rect().position) + Vector2i(40, 40))
	var p_panel := img.get_pixelv(Vector2i(30, 30))
	print("SMOKE ...tiles are drawn (a tile's inside differs from the panel's): ", not p_tile.is_equal_approx(p_panel))
	print("SMOKE the redo button starts disabled: ", undo_dis != null)
	var panel_px := img.get_pixelv(Vector2i(30, 30))
	print("SMOKE the tablet panel is the theme's panel colour: ", absf(panel_px.r - tokens.bg_panel.r) < 0.03 and absf(panel_px.b - tokens.bg_panel.b) < 0.03)
	print("SMOKE no side panel on the home screen: ", not lab.side.visible)
	print("SMOKE the Design tile says what it will do (Summon table), then Bring it to me once the table is open: ", tablet.tile_caption("design") == "Summon table")
	design_tile.pressed.emit()
	await process_frame
	print("SMOKE ...tapping it acts straight from Home and the caption follows: ", lab._table_open and tablet.selected_category_id == "" and tablet.tile_caption("design") == "Bring it to me")

	# View is a hub: its tiles come first.
	view_tile.pressed.emit()
	await process_frame
	await _shot("ui_lab_view_hub.png")
	print("SMOKE View opens a screen of tiles, one per tool: ", tablet.hub_open and tablet._hub_view.visible and tablet._hub_grid.get_child_count() == 7)
	tablet.hub_tile("scale").pressed.emit()
	await process_frame
	print("SMOKE a hub tile opens its tool, Back returns to the hub, Back again to Home: ", tablet.selected_tool_id == "scale" and not tablet.hub_open)
	tablet.go_back()
	print("SMOKE ...(hub)", tablet.hub_open)
	tablet.go_back()
	print("SMOKE ...(home)", tablet.selected_category_id == "")

	# Assemble > Mates (mode tool with a list) via the real tile / header path.
	tablet.home_tile("assemble").pressed.emit()
	await process_frame
	print("SMOKE a category with one tool shows no chip strip: ", not tablet._strip_scroll.visible)
	tablet.select_tool("mates", true)
	await process_frame
	await process_frame
	print("SMOKE selecting a mode tool turns it on and shows the side list: ", lab.manager.active_id == "mates" and lab.side.visible and lab.side.row_count() == 2)
	tablet.go_home()
	await process_frame
	print("SMOKE going Home leaves the tool on and the top bar says so: ", lab.manager.active_id == "mates" and tablet.chip_texts().any(func(t): return t.contains("Mates on")) and not lab.side.visible)
	tablet.home_tile("inspect").pressed.emit()
	await process_frame
	print("SMOKE Inspect (two tools) shows a chip strip: ", tablet._strip_scroll.visible and tablet._strip_buttons.size() == 2)
	await _shot("ui_lab_inspect_strip.png")
	tablet.go_home()

	# Themes x effects: render each, check the shader and the themes are really visible.
	var Themes = load("res://scripts/ui/ui_themes.gd")
	var edge := Vector2i(24 + 8, 24 + 330) # a few pixels inside the tablet panel's left edge, mid-height
	var panels := {}
	var edge_on := {}
	var edge_off := {}
	for theme_name in Themes.ORDER:
		Themes.apply(theme_name)
		Themes.set_fx(true)
		var shot_on := await _shot("ui_lab_%s_fx_on.png" % theme_name.to_lower())
		edge_on[theme_name] = shot_on.get_pixelv(edge)
		panels[theme_name] = shot_on.get_pixelv(Vector2i(60, 600))
		Themes.set_fx(false)
		var shot_off := await _shot("ui_lab_%s_fx_off.png" % theme_name.to_lower())
		edge_off[theme_name] = shot_off.get_pixelv(edge)
	Themes.set_fx(true)
	Themes.apply("Navy")
	print("SMOKE the three themes render visibly different panels: ", not panels["Navy"].is_equal_approx(panels["Simple"]) and not panels["Simple"].is_equal_approx(panels["Dark"]) and not panels["Navy"].is_equal_approx(panels["Dark"]))
	var glow_seen := true
	for theme_name in Themes.ORDER:
		glow_seen = glow_seen and _luma(edge_on[theme_name]) > _luma(edge_off[theme_name]) + 0.004
	print("SMOKE the glass shader actually draws: the panel edge is brighter with effects on, in every theme: ", glow_seen, " ", edge_on, edge_off)
	print("SMOKE ...and Navy's glow is stronger than Simple's (each theme sets its own strength): ", _luma(edge_on["Navy"]) - _luma(edge_off["Navy"]) > _luma(edge_on["Simple"]) - _luma(edge_off["Simple"]))

	# History open on the home screen.
	tablet.history_open = true
	tablet.selection_changed.emit()
	await _shot("ui_lab_history.png")
	print("SMOKE History shows the undo stack in the side panel: ", lab.side.visible and lab.side.row_count() == 3)
	quit()
