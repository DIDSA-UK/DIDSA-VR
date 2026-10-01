extends Control
## UI Lab: the redesigned tablet in a plain desktop window — no headset, no
## backend, no XR. The REAL shell (tablet_ui.gd + side_panel_ui.gd + the theme)
## fed by a stub registry of placeholder tools, so layout and look can be judged
## and tuned in seconds.
##
##   Godot editor -> open res://lab/ui_lab.tscn -> F6.
##
## To tune the look: open a preset in res://ui/themes/ in the Inspector, change a
## colour / radius / font size, save, press F6 again. The tablet, the side panel
## and (from Phase 3) windows and the keyboard are all built from that one resource.
##
## Along the bottom: the three themes (Navy / Simple / Dark) and the shader Effects switch: the
## tablet and side panel re-theme live. Presets are ui/themes/*.tres: edit one in the Inspector, F6.
##
## Things to click: the category grid; the rail (Mates / Measure / Sections / Shoot
## hide are mode tools: only one is ever ON, see tool_manager.gd); the tool header
## switch and "?"; Undo/Redo and a long press on Undo for History; Settings.
## The buttons under the tablet add categories (up to 8 = 4 x 2) and scale the whole
## sheet to the physical size it will have on the wrist.

const TabletRegistry := preload("res://scripts/ui/tablet_registry.gd")
const ToolManager := preload("res://scripts/ui/tool_manager.gd")
const TabletUI := preload("res://scripts/ui/tablet_ui.gd")
const SidePanelUI := preload("res://scripts/ui/side_panel_ui.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"
const TABLET_PX := Vector2(1067, 693) ## the real tablet's viewport (0.40 x 0.26 m at 2667 px/m)
const SIDE_PX := Vector2(452, 693)

var tokens: Resource
var registry
var manager
var stack
var tablet: Control
var side: Control
var _extra_categories := 0
var _mode_log: Label
var _last_signature := ""
var _fake_mates := [["Coincident", "Plate ↔ Bracket", "normal"], ["Concentric", "Pin 4 ↔ Hole 3", "normal"]]


func _ready() -> void:
	# 1:1 pixels, big enough for the tablet and its side panel (the project's own
	# 1280x720 canvas-stretch would crop the side panel and rescale the text).
	var window := get_window()
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	if DisplayServer.get_name() != "headless":
		window.size = Vector2i(1600, 900)
	tokens = UiThemes.live() # the shared theme resource the real tablet, windows and keyboard use too
	UiThemes.apply(UiThemes.current)
	theme = tokens.build_theme()
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.03, 0.05)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	registry = TabletRegistry.new()
	manager = ToolManager.new()
	manager.setup(registry)
	stack = CommandStack.new()
	for label in ["Move part", "Scale to 1:2", "Hide part"]:
		stack.push(label, func() -> void: pass, func() -> void: pass)
	_register_stub_tools()

	var stage := Control.new()
	stage.position = Vector2(24, 24)
	add_child(stage)
	tablet = TabletUI.new()
	tablet.size = TABLET_PX
	tablet.setup(tokens, registry, manager, {"command_stack": stack, "settings_builder": _stub_settings})
	stage.add_child(tablet)
	side = SidePanelUI.new()
	side.position = Vector2(TABLET_PX.x + 20, 0)
	side.setup(tokens, SIDE_PX)
	side.visible = false
	stage.add_child(side)
	tablet.selection_changed.connect(_refresh_side)
	manager.active_changed.connect(func(id: String) -> void: _mode_log.text = "Active mode tool: %s" % (id if id != "" else "none"))

	var bar := HBoxContainer.new()
	bar.position = Vector2(24, TABLET_PX.y + 36)
	bar.add_theme_constant_override("separation", 12)
	add_child(bar)
	var add := Button.new()
	add.text = "Add a category (max 8)"
	add.pressed.connect(_add_category)
	bar.add_child(add)
	var theme_group := ButtonGroup.new()
	for theme_name in UiThemes.ORDER:
		var tb := Button.new()
		tb.text = theme_name
		tb.toggle_mode = true
		tb.button_group = theme_group
		tb.button_pressed = (theme_name == UiThemes.current)
		tb.pressed.connect(func() -> void: UiThemes.apply(theme_name)) # every UI in the lab re-themes itself next frame
		bar.add_child(tb)
	var fx := Button.new()
	fx.text = "Effects: ON" if UiThemes.fx_enabled else "Effects: off"
	fx.toggle_mode = true
	fx.button_pressed = UiThemes.fx_enabled
	fx.toggled.connect(func(on: bool) -> void:
		UiThemes.set_fx(on)
		fx.text = "Effects: ON" if on else "Effects: off"
	)
	bar.add_child(fx)
	_mode_log = Label.new()
	_mode_log.theme_type_variation = &"LabelDim"
	_mode_log.text = "Active mode tool: none"
	bar.add_child(_mode_log)
	_refresh_side()


var _seen_revision := -1

func _process(delta: float) -> void:
	if _seen_revision != UiThemes.revision:
		_seen_revision = UiThemes.revision
		theme = tokens.build_theme() # the lab's own bar re-themes too (the tablet and side panel do it themselves)
	tablet.tick(delta)
	_refresh_side_rows()


func _add_category() -> void:
	if registry.categories().size() >= registry.MAX_CATEGORIES:
		return
	_extra_categories += 1
	var id := "extra%d" % _extra_categories
	registry.add_category(id, "Extra %d" % _extra_categories, ["scale", "history", "navigate", "environment"][_extra_categories % 4], Color.from_hsv(0.1 * _extra_categories, 0.45, 0.95))
	registry.add_tool(id, id + "_t", "Tool", "check", _stub_page.bind("Placeholder for a future tool."))


func _refresh_side() -> void:
	var src: Dictionary = tablet.list_source()
	side.visible = not src.is_empty()
	_last_signature = ""
	_refresh_side_rows()


func _refresh_side_rows() -> void:
	var src: Dictionary = tablet.list_source()
	if src.is_empty():
		return
	side.set_list(src["title"], src["provider"].call(), src.get("empty", ""))


# --- Stub content ------------------------------------------------------------------

func _register_stub_tools() -> void:
	var mode := func(label: String) -> Dictionary:
		return {"kind": "mode", "hint": "%s is ON — the laser now does %s things." % [label, label.to_lower()], "help": "Stub help for %s. Real text lives in tablet_pages.gd." % label}
	registry.add_category("view", "View", "view", Color(0.35, 0.78, 0.95))
	registry.add_tool("view", "navigate", "Navigate", "navigate", _stub_page.bind("Model movement, user movement, part manipulation, travel speed."), {"hint": "Navigate"})
	registry.add_tool("view", "scale", "Scale", "scale", _stub_page.bind("Scale presets, lock, Fit to view, Home."))
	registry.add_tool("view", "visibility", "Visibility", "visibility", _stub_page.bind("Hide all, Show all, Reverse, Isolate."))
	registry.add_tool("view", "shoot_hide", "Shoot hide", "shoot_hide", _stub_page.bind("Point at a part and pull the trigger."), mode.call("Shoot hide"))
	registry.add_tool("view", "environment", "Environment", "environment", _stub_page.bind("Light, Dark, Mid, Passthrough."))
	registry.add_category("assembly", "Assembly", "assembly", Color(0.95, 0.72, 0.35))
	var mates_opts: Dictionary = mode.call("Mates")
	mates_opts["list"] = _fake_mate_rows
	mates_opts["list_empty"] = "No mates yet."
	registry.add_tool("assembly", "mates", "Mates", "mates", _stub_page.bind("Pick two faces, choose a type, Create mate."), mates_opts)
	registry.add_tool("assembly", "colours", "Colours", "colours", _stub_page.bind("Laser-select a part, then tap a swatch."), {"hint": "Selected: nothing — laser-select a part first"})
	registry.add_tool("assembly", "sections", "Sections", "sections", _stub_page.bind("Clip plane: grip to move, Flip."), mode.call("Sections"))
	var measure_opts: Dictionary = mode.call("Measure")
	measure_opts["list"] = func() -> Array: return [{"id": "d", "title": "142.382 mm", "subtitle": "Distance", "state": "normal"}, {"id": "dx", "title": "98.2, -61.4, 82.822 mm", "subtitle": "ΔX, ΔY, ΔZ", "state": "normal"}]
	registry.add_tool("assembly", "measure", "Measure", "measure", _stub_page.bind("Pick a vertex, edge or face."), measure_opts)
	registry.add_category("windows", "Windows", "windows", Color(0.72, 0.60, 0.95))
	registry.add_tool("windows", "windows", "Windows", "windows", _stub_page.bind("Assembly Tree, Calculator, Image Viewer, Browser."))
	registry.add_category("files", "Files", "files", Color(0.50, 0.85, 0.60))
	registry.add_tool("files", "models", "Models", "models", _stub_page.bind("Models found in the project folders."), {"list": func() -> Array: return [
		{"id": "a", "title": "bracket_main.didsa", "subtitle": "DIDSA", "actions": [{"label": "Open", "accent": true}, {"label": "Add"}]},
		{"id": "b", "title": "hull_clamp.step", "subtitle": "STEP", "actions": [{"label": "Open", "accent": true}]}]})


func _fake_mate_rows() -> Array:
	var rows := []
	for m in _fake_mates:
		rows.append({"id": m[0], "title": m[0], "subtitle": m[1], "state": m[2], "actions": [{"label": "Delete", "danger": true, "confirm": true, "callback": func() -> void: pass}]})
	return rows


func _stub_page(text: String) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", tokens.gap + 2)
	var hint := Label.new()
	hint.text = text
	hint.theme_type_variation = &"LabelDim"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(hint)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", tokens.gap)
	page.add_child(row)
	var group := ButtonGroup.new()
	for i in ["One", "Two", "Three"]:
		var b := Button.new()
		b.text = i
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = (i == "Two")
		row.add_child(b)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(0, 52)
	slider.value = 40
	page.add_child(slider)
	var action := Button.new()
	action.text = "Primary action"
	action.theme_type_variation = &"ButtonAccent"
	action.custom_minimum_size = Vector2(0, 56)
	page.add_child(action)
	return page


func _stub_settings() -> Control:
	return _stub_page("Steadiness, display quality, project folder.")
