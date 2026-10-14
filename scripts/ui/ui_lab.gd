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
## Things to click: the home tiles (Design and the window tiles act straight away; View
## and Settings open a screen of tiles; Inspect opens a chip strip); Back; the status chips
## (Mates / Measure / Sections / Shoot hide are mode tools: only one is ever ON, see
## tool_manager.gd); the tool header switch and "?"; Undo/Redo and a long press on Undo for
## History; the gear (jumps to Settings). The home grid holds up to 12 tiles (6 x 2).

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
var _table_open := false
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
	tablet.setup(tokens, registry, manager, {"command_stack": stack, "chips": _stub_chips})
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
	var home := Button.new()
	home.text = "Go Home"
	home.pressed.connect(tablet.go_home)
	bar.add_child(home)
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


func _stub_chips() -> Array:
	return [{"text": "Unsaved", "kind": "warn", "tap": func() -> void: tablet.select_category("files")}, {"text": "Table open", "kind": "ok"}]


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
	var windows := Color(0.43, 0.66, 1.0)
	var noop := func() -> void: pass
	registry.add_category("design", "Design", "design", Color(1.0, 0.71, 0.33), {"subtitle": "sketch · extrude", "action": func() -> void: _table_open = not _table_open, "caption": func() -> String: return "Bring it to me" if _table_open else "Summon table"})
	registry.add_category("assemble", "Assemble", "assembly", Color(0.37, 0.76, 1.0), {"subtitle": "mates · fix · relax"})
	var mates_opts: Dictionary = mode.call("Mates")
	mates_opts["list"] = _fake_mate_rows
	mates_opts["list_empty"] = "No mates yet."
	registry.add_tool("assemble", "mates", "Mates", "mates", _stub_page.bind("Pick two faces, choose a type, Create mate."), mates_opts)
	registry.add_category("view", "View", "view", Color(0.48, 0.88, 0.69), {"subtitle": "scale · hide · display", "hub": true})
	registry.add_tool("view", "navigate", "Navigate", "navigate", _stub_page.bind("Model movement, user movement, part manipulation, travel speed."), {"caption": "hands · speed"})
	registry.add_tool("view", "scale", "Scale", "scale", _stub_page.bind("Scale presets, lock, Fit to view, Home."), {"caption": "presets · fit · home"})
	registry.add_tool("view", "visibility", "Visibility", "visibility", _stub_page.bind("Hide all, Show all, Reverse, Isolate."), {"caption": "hide · show · isolate"})
	var shoot: Dictionary = mode.call("Shoot hide")
	shoot["caption"] = "point and hide"
	registry.add_tool("view", "shoot_hide", "Shoot hide", "shoot_hide", _stub_page.bind("Point at a part and pull the trigger."), shoot)
	registry.add_tool("view", "display", "Display", "eye_shaded", _stub_page.bind("Shaded, shaded + edges, wireframe."), {"caption": "shaded · edges · wire"})
	registry.add_tool("view", "colours", "Colours", "colours", _stub_page.bind("Laser-select a part, then tap a swatch."), {"caption": "paint parts", "hint": "Selected: nothing — laser-select a part first"})
	registry.add_tool("view", "environment", "Environment", "environment", _stub_page.bind("Light, Dark, Mid, Passthrough."), {"caption": "scene · passthrough"})
	registry.add_category("inspect", "Inspect", "measure", Color(0.77, 0.55, 1.0), {"subtitle": "measure · sections"})
	var measure_opts: Dictionary = mode.call("Measure")
	measure_opts["list"] = func() -> Array: return [{"id": "d", "title": "142.382 mm", "subtitle": "Distance", "state": "normal"}, {"id": "dx", "title": "98.2, -61.4, 82.822 mm", "subtitle": "ΔX, ΔY, ΔZ", "state": "normal"}]
	registry.add_tool("inspect", "measure", "Measure", "measure", _stub_page.bind("Pick a vertex, edge or face."), measure_opts)
	registry.add_tool("inspect", "sections", "Sections", "sections", _stub_page.bind("Clip plane: grip to move, Flip."), mode.call("Sections"))
	registry.add_category("files", "Files", "files", Color(1.0, 0.82, 0.4), {"subtitle": "open · save · new"})
	registry.add_tool("files", "models", "Models", "models", _stub_page.bind("Models found in the project folders."), {"list": func() -> Array: return [
		{"id": "a", "title": "bracket_main.didsa", "subtitle": "DIDSA", "actions": [{"label": "Open", "accent": true}, {"label": "Add"}]},
		{"id": "b", "title": "hull_clamp.step", "subtitle": "STEP", "actions": [{"label": "Open", "accent": true}]}]})
	registry.add_category("tree", "Tree", "tree", windows, {"subtitle": "window", "action": noop})
	registry.add_category("calculator", "Calculator", "calculator", windows, {"subtitle": "window", "action": noop})
	registry.add_category("images", "Images", "image", windows, {"subtitle": "window", "action": noop})
	registry.add_category("browser", "Browser", "browser", windows, {"subtitle": "window", "action": noop})
	registry.add_category("settings", "Settings", "settings", Color(0.62, 0.70, 0.80), {"subtitle": "set & forget", "hub": true})
	registry.add_tool("settings", "set_movement", "Movement", "movement", _stub_page.bind("Steadiness."), {"caption": "steadiness"})
	registry.add_tool("settings", "set_display", "Display", "eye_shaded", _stub_page.bind("Shadows, resolution, MSAA."), {"caption": "shadows · resolution · MSAA"})
	registry.add_tool("settings", "set_appearance", "Appearance", "colours", _stub_page.bind("Theme, shader effects."), {"caption": "theme · effects"})
	registry.add_tool("settings", "set_comfort", "Comfort", "comfort", _stub_page.bind("Reduce motion, sound, volume, haptics."), {"caption": "motion · sound · haptics"})
	registry.add_tool("settings", "set_folder", "Project folder", "files", _stub_page.bind("Where models live."), {"caption": "where models live"})
	registry.add_tool("settings", "set_table", "Design table", "table", _stub_page.bind("Returned-part turn, zoom limit."), {"caption": "turn · zoom limits"})


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
