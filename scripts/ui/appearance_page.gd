extends RefCounted
## The wrist tablet's Appearance page (DIDSA-CAD `docs/appearance-tool-scope.md` D4): what the Appearance tool's gun paints with.
## Replaces the old Colours and Paint pages.
##
##   * a live preview sphere rendered with the real material (shine and metal show on a curved surface), and the brush in words;
##   * the palette, plus Clear (a swatch like any other: painting it removes that level's own paint);
##   * a full picker: hue ring + saturation / value square (colour_picker_control.gd), a hex field (the popup keyboard), recent
##     colours, and the eyedropper (the next shot takes everything the face under the laser shows);
##   * Opacity, Shine (1 - roughness), Metal and Glow sliders. Each property has a "paint" switch: a paint sets only the
##     switched-on properties, so "opacity only" leaves the colour to whatever is beneath it (section 2: every field optional).
##     Moving a slider switches its property on;
##   * saved appearances: the presets (Matte plastic ... Glowing) and your own (Save brush..., kept in the app's settings).

const Rule := preload("res://scripts/appearance/appearance_rule.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")
const Picker := preload("res://scripts/ui/colour_picker_control.gd")

const PALETTE: Array[Dictionary] = [
	{"name": "Red", "hex": "#E63946"}, {"name": "Orange", "hex": "#F4A340"},
	{"name": "Yellow", "hex": "#F1C40F"}, {"name": "Green", "hex": "#2ECC71"},
	{"name": "Blue", "hex": "#3498DB"}, {"name": "Purple", "hex": "#9B59B6"},
	{"name": "White", "hex": "#F5F5F5"}, {"name": "Black", "hex": "#222222"},
]
## [property label, field, slider min, max, how the slider maps to the field]
const PROPERTIES: Array = [
	["Opacity", "opacity", 0.0, 1.0, "same"],
	["Shine", "roughness", 0.0, 1.0, "invert"], # shine = 1 - roughness
	["Metal", "metallic", 0.0, 1.0, "same"],
	["Glow", "emission_strength", 0.0, 10.0, "same"],
]
const DEFAULTS := {"opacity": 1.0, "roughness": 0.8, "metallic": 0.0, "emission_strength": 0.0}

var tool: Node ## appearance_tool.gd
var tokens: Resource
var open_keyboard: Callable ## (initial text, on_done(text), options) - main.gd's open_keyboard_for
var toast: Callable ## (text, kind)

var summary: Label
var picker: Control
var colour_switch: CheckButton
var sliders := {} ## field -> HSlider
var switches := {} ## field -> CheckButton
var eyedropper_button: Button
var recent_row: HFlowContainer
var saved_row: HFlowContainer
var sphere: MeshInstance3D
var _syncing := false


func _init(p_tool: Node, p_tokens: Resource, p_open_keyboard: Callable, p_toast: Callable) -> void:
	tool = p_tool
	tokens = p_tokens
	open_keyboard = p_open_keyboard
	toast = p_toast


func build() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	page.add_child(top)
	top.add_child(_preview_sphere())
	var top_right := VBoxContainer.new()
	top_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(top_right)
	summary = Label.new()
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top_right.add_child(summary)
	var hint := Label.new()
	hint.text = "Click paints the body. Hold the trigger to choose: face, part, pattern, every copy, sub-assembly or the whole assembly."
	hint.theme_type_variation = &"LabelSmall"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top_right.add_child(hint)
	eyedropper_button = _button("Eyedropper", func() -> void:
		tool.eyedropper = eyedropper_button.button_pressed
		_refresh_summary())
	eyedropper_button.toggle_mode = true
	top_right.add_child(eyedropper_button)

	var palette := HFlowContainer.new()
	palette.add_theme_constant_override("h_separation", 8)
	palette.add_theme_constant_override("v_separation", 8)
	page.add_child(palette)
	for swatch in PALETTE:
		palette.add_child(_swatch_button(swatch["name"], swatch["hex"]))
	var clear := _button("Clear", set_clear)
	clear.custom_minimum_size = Vector2(120, 56)
	clear.add_theme_color_override("font_color", tokens.danger)
	palette.add_child(clear)

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override("separation", 12)
	page.add_child(picker_row)
	picker = Picker.new()
	picker.colour_changed.connect(func(c: Color) -> void: set_colour("#" + c.to_html(false).to_upper(), false))
	picker_row.add_child(picker)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_row.add_child(side)
	colour_switch = _switch("Paint colour", func(on: bool) -> void: _set_field_on("colour", on))
	side.add_child(colour_switch)
	side.add_child(_button("Hex…", _on_hex))
	var recent_title := Label.new()
	recent_title.text = "Recent"
	recent_title.theme_type_variation = &"LabelDim"
	side.add_child(recent_title)
	recent_row = HFlowContainer.new()
	recent_row.add_theme_constant_override("h_separation", 6)
	side.add_child(recent_row)

	for p in PROPERTIES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		page.add_child(row)
		var field: String = p[1]
		var sw := _switch(p[0], func(on: bool) -> void: _set_field_on(field, on))
		sw.custom_minimum_size = Vector2(190, 52)
		row.add_child(sw)
		switches[field] = sw
		var slider := HSlider.new()
		slider.min_value = p[2]
		slider.max_value = p[3]
		slider.step = 0.01
		slider.scrollable = false
		slider.custom_minimum_size = Vector2(0, 52)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(func(v: float) -> void: _on_slider(field, v))
		row.add_child(slider)
		sliders[field] = slider

	var saved_title := Label.new()
	saved_title.text = "Saved appearances"
	saved_title.theme_type_variation = &"LabelDim"
	page.add_child(saved_title)
	saved_row = HFlowContainer.new()
	saved_row.add_theme_constant_override("h_separation", 8)
	saved_row.add_theme_constant_override("v_separation", 8)
	page.add_child(saved_row)
	page.add_child(_button("Save brush…", _on_save))
	sync_from_brush()
	return page


# --- the brush -----------------------------------------------------------------------------------------------------

func set_colour(hex: String, move_picker: bool = true) -> void:
	## The palette, the picker, the hex field and the recent row set the colour (and switch "paint colour" on).
	if not Rule.is_hex(hex):
		return
	var b: Dictionary = tool.brush.duplicate()
	b["colour"] = hex.to_upper()
	tool.brush = b
	if move_picker and picker != null:
		picker.set_colour(Color.html(hex))
	sync_from_brush(false)


func set_clear() -> void:
	tool.brush = {}
	sync_from_brush()


func use_saved(appearance: Dictionary) -> void:
	tool.brush = appearance.duplicate()
	sync_from_brush()


func _set_field_on(field: String, on: bool) -> void:
	if _syncing:
		return
	var b: Dictionary = tool.brush.duplicate()
	if on:
		b[field] = _field_value(field)
	else:
		b.erase(field)
	tool.brush = b
	sync_from_brush(false)


func _field_value(field: String) -> Variant:
	if field == "colour":
		return "#" + picker.colour().to_html(false).to_upper() if picker != null else "#C8C8C8"
	var slider: HSlider = sliders.get(field)
	var v := slider.value if slider != null else float(DEFAULTS.get(field, 0.0))
	for p in PROPERTIES:
		if p[1] == field and p[4] == "invert":
			return snappedf(1.0 - v, 0.01)
	return snappedf(v, 0.01)


func _on_slider(field: String, _v: float) -> void:
	if _syncing:
		return
	var b: Dictionary = tool.brush.duplicate()
	b[field] = _field_value(field) # moving a slider switches its property on
	tool.brush = b
	sync_from_brush(false)


func sync_from_brush(move_controls: bool = true) -> void:
	## Every control shows the tool's brush (after a preset, the eyedropper, Clear or a change elsewhere).
	_syncing = true
	var b: Dictionary = tool.brush
	if colour_switch != null:
		colour_switch.button_pressed = b.has("colour")
	if move_controls and picker != null and b.has("colour"):
		picker.set_colour(Color.html(str(b["colour"])))
	for p in PROPERTIES:
		var field: String = p[1]
		if switches.has(field):
			(switches[field] as CheckButton).button_pressed = b.has(field)
		if move_controls and sliders.has(field):
			var v := float(b.get(field, DEFAULTS[field]))
			(sliders[field] as HSlider).value = 1.0 - v if p[4] == "invert" else v
	if eyedropper_button != null:
		eyedropper_button.button_pressed = bool(tool.eyedropper)
	_syncing = false
	_refresh_summary()
	_refresh_sphere()
	_refresh_recent()
	_refresh_saved()


func _refresh_summary() -> void:
	if summary == null:
		return
	var b: Dictionary = tool.brush
	if bool(tool.eyedropper):
		summary.text = "Eyedropper: shoot a part to take its look."
	elif b.is_empty():
		summary.text = "Brush: Clear (removes that level's own paint)."
	else:
		var parts: PackedStringArray = []
		if b.has("colour"):
			parts.append(str(b["colour"]))
		if b.has("opacity"):
			parts.append("opacity %d%%" % int(round(float(b["opacity"]) * 100.0)))
		if b.has("roughness"):
			parts.append("shine %d%%" % int(round((1.0 - float(b["roughness"])) * 100.0)))
		if b.has("metallic"):
			parts.append("metal %d%%" % int(round(float(b["metallic"]) * 100.0)))
		if b.has("emission_strength") or b.has("emission"):
			parts.append("glow %s" % str(b.get("emission_strength", 1.0)))
		summary.text = "Brush: %s%s" % [", ".join(parts), "  (temporary: mates relaxed)" if tool.is_temporary() else ""]


func _refresh_sphere() -> void:
	if sphere == null:
		return
	var b: Dictionary = tool.brush
	var m := Look.material_for(b if not b.is_empty() else {"colour": "#C8C8C8", "opacity": 0.35})
	sphere.material_override = m


func _refresh_recent() -> void:
	if recent_row == null:
		return
	for c in recent_row.get_children():
		recent_row.remove_child(c)
		c.queue_free()
	for hex in tool.recent_colours():
		var b := _swatch_button("", str(hex))
		b.custom_minimum_size = Vector2(48, 48)
		recent_row.add_child(b)


func _refresh_saved() -> void:
	if saved_row == null:
		return
	for c in saved_row.get_children():
		saved_row.remove_child(c)
		c.queue_free()
	for entry in tool.saved_appearances():
		var appearance: Dictionary = entry["appearance"]
		var b := _button(str(entry["name"]), use_saved.bind(appearance))
		b.size_flags_horizontal = Control.SIZE_FILL
		b.custom_minimum_size = Vector2(170, 52)
		saved_row.add_child(b)


func _on_hex() -> void:
	if not open_keyboard.is_valid():
		return
	open_keyboard.call(str(tool.brush.get("colour", "")), func(text: String) -> void:
		var hex := text.strip_edges()
		hex = hex if hex.begins_with("#") else "#" + hex
		if Rule.is_hex(hex):
			set_colour(hex)
		elif toast.is_valid():
			toast.call("Not a hex colour (want #RRGGBB): %s" % text, "error")
	, {"mode": "full", "title": "Colour, e.g. #3A7BD5 (0-9, A-F)", "confirm_label": "Set"})


func _on_save() -> void:
	if not open_keyboard.is_valid():
		return
	if tool.brush.is_empty():
		if toast.is_valid():
			toast.call("Pick a colour or a look first: Clear can't be saved.", "error")
		return
	open_keyboard.call("", func(text: String) -> void:
		var name_ := text.strip_edges()
		if name_ == "":
			return
		tool.save_brush(name_)
		_refresh_saved()
		if toast.is_valid():
			toast.call("Saved \"%s\"." % name_, "ok")
	, {"mode": "full", "title": "Name for this appearance", "confirm_label": "Save"})


# --- widgets -------------------------------------------------------------------------------------------------------

func _button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(callback)
	return b


func _switch(text: String, on_toggle: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.custom_minimum_size = Vector2(0, 52)
	c.toggled.connect(on_toggle)
	return c


func _swatch_button(label: String, hex: String) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(120, 56)
	var fill := Color.html(hex)
	var ink := Color.BLACK if 0.299 * fill.r + 0.587 * fill.g + 0.114 * fill.b > 0.6 else Color.WHITE
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(state, ink)
	b.add_theme_stylebox_override("normal", tokens.box(fill, fill.darkened(0.25)))
	b.add_theme_stylebox_override("hover", tokens.box(fill.lightened(0.12), Color.WHITE))
	b.add_theme_stylebox_override("pressed", tokens.box(fill, Color.WHITE))
	b.pressed.connect(set_colour.bind(hex))
	return b


func _preview_sphere() -> Control:
	## A small 3D view of a sphere wearing the brush's real material, lit and with a sky to reflect (so shine and metal show).
	var container := SubViewportContainer.new()
	container.custom_minimum_size = Vector2(170, 170)
	container.stretch = true
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.size = Vector2i(170, 170)
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	container.add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.environment = e
	vp.add_child(env)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2.6)
	vp.add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 35, 0)
	vp.add_child(light)
	sphere = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.9
	mesh.height = 1.8
	sphere.mesh = mesh
	vp.add_child(sphere)
	return container
