extends SceneTree
## The wrist tablet's Appearance page (scripts/ui/appearance_page.gd) and its colour picker (scripts/ui/colour_picker_control.gd),
## no scene, no network: the palette and the picker set the brush's colour; a property is painted only while its switch is on and
## moving its slider switches it on; Shine is 1 - roughness; Clear empties the brush; a saved appearance (preset or your own)
## replaces it; the recent colours are remembered (newest first, at most 8); the picker's ring and square map to hue and
## saturation / value; and the preview sphere wears the brush's real material.
## Run: "$GODOT" --headless --path . --script res://tests/appearance_page.gd

const Tool := preload("res://scripts/appearance_tool.gd")
const Page := preload("res://scripts/ui/appearance_page.gd")
const Picker := preload("res://scripts/ui/colour_picker_control.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")

var failures := 0


class FakeSettings extends RefCounted:
	var paint_recent: Array = []
	var paint_saved: Array = []
	func set_paint_recent(c: Array) -> void:
		paint_recent = c.duplicate()
	func set_paint_saved(e: Array) -> void:
		paint_saved = e.duplicate(true)


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _initialize() -> void:
	var tool := Tool.new()
	var settings := FakeSettings.new()
	tool.settings = settings
	root.add_child(tool)
	var page := Page.new(tool, UiThemes.live(), Callable(), Callable())
	var control := page.build()
	root.add_child(control)
	await process_frame

	page.set_colour("#3498db")
	_check(tool.brush.get("colour") == "#3498DB" and page.colour_switch.button_pressed, "a palette colour sets the brush's colour and switches Paint colour on")
	_check(tool.brush.size() == 1, "...and nothing else: opacity, shine, metal and glow stay off (they show through from below)")
	(page.sliders["opacity"] as HSlider).value = 0.4
	_check(is_equal_approx(float(tool.brush.get("opacity", -1.0)), 0.4) and (page.switches["opacity"] as CheckButton).button_pressed, "moving the Opacity slider switches it on at that value")
	(page.sliders["roughness"] as HSlider).value = 0.9
	_check(is_equal_approx(float(tool.brush.get("roughness", -1.0)), 0.1), "Shine 0.9 paints roughness 0.1 (shine = 1 - roughness)")
	(page.switches["opacity"] as CheckButton).button_pressed = false
	_check(not tool.brush.has("opacity") and tool.brush.has("colour"), "switching Opacity off leaves it out of the brush")
	page.colour_switch.button_pressed = false
	_check(not tool.brush.has("colour"), "switching Paint colour off: a brush that leaves the colour alone")
	var m := page.sphere.material_override as StandardMaterial3D
	_check(m != null and is_equal_approx(m.roughness, 0.1), "the preview sphere wears the brush's real material")
	page.set_clear()
	_check(tool.brush.is_empty() and page.summary.text.begins_with("Brush: Clear"), "Clear empties the brush (painting it removes a level's own paint)")
	page.use_saved(Tool.PRESETS[3]["appearance"])
	_check(tool.brush == {"metallic": 1.0, "roughness": 0.08} and (page.switches["metallic"] as CheckButton).button_pressed and not page.colour_switch.button_pressed, "a preset (Polished metal) replaces the brush and the switches follow it")
	tool.brush = {"colour": "#F1C40F", "opacity": 0.5}
	tool.save_brush("Amber glass")
	_check(settings.paint_saved.size() == 1 and tool.saved_appearances().size() == Tool.PRESETS.size() + 1 and tool.saved_appearances().back()["name"] == "Amber glass", "Save brush keeps your own appearance after the presets")
	for i in 10:
		tool._remember_colour("#%02X0000" % (i * 20))
	tool._remember_colour("#000000")
	_check(settings.paint_recent.size() == Tool.RECENT_MAX and settings.paint_recent[0] == "#000000" and settings.paint_recent.count("#000000") == 1, "recent colours: newest first, no repeats, at most 8")
	tool.eyedropper = true
	page.sync_from_brush()
	_check(page.eyedropper_button.button_pressed and page.summary.text.begins_with("Eyedropper"), "the eyedropper switch shows on the page")
	tool.eyedropper = false

	# --- the picker
	var centre := Vector2(150, 150)
	_check(is_equal_approx(Picker.hue_at(Vector2(150, 10), centre), 0.0) and is_equal_approx(Picker.hue_at(Vector2(290, 150), centre), 0.25), "the ring: hue 0 at the top, a quarter turn clockwise at the right")
	var square := Rect2(Vector2(100, 100), Vector2(100, 100))
	_check(Picker.sv_at(Vector2(200, 100), square).is_equal_approx(Vector2(1, 1)) and Picker.sv_at(Vector2(100, 200), square).is_equal_approx(Vector2(0, 0)) and Picker.sv_at(Vector2(500, -5), square).is_equal_approx(Vector2(1, 1)), "the square: saturation across, value up, clamped")
	_check(Picker.region_at(Vector2(150, 5), centre, 120.0, 145.0, square) == "ring" and Picker.region_at(Vector2(150, 150), centre, 120.0, 145.0, square) == "square" and Picker.region_at(Vector2(150, 110), centre, 120.0, 145.0, Rect2(Vector2(130, 130), Vector2(40, 40))) == "", "a press is on the ring, the square, or neither")
	var picker := Picker.new()
	picker.set_colour(Color.html("#3498DB"))
	_check(picker.colour().is_equal_approx(Color.html("#3498DB")), "the picker shows a colour it is given")
	_check(picker.is_in_group("laser_draggable"), "the picker is dragged by the laser like a slider (laser_draggable)")
	picker.free()

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
