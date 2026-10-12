extends Node3D
## What the tool wheel offers, and the one-line prompt that leads you through a tool.
##
## The ring follows what you are doing. With no tool on it is the root ring of everyday tools. With Mates on,
## the first wedges are the Mates steps (Create, Flip, Clear picks, the mate type); with Measure on, Clear and
## the tablet; with the Colour gun on, the palette. "All tools" in each of those is a sub-wheel with the root
## ring, so any tool is still one gesture away. Every tool is switched on through ToolManager (the tablet's
## own path), so the badge, the tablet chip and the one-active-tool rule stay right.
##
## The prompt is a small billboard label low in front of you, shown while a mode tool is on: it says what the
## trigger will do now (pick the first face, pick the second, a preview is showing...), because a tool can
## outlive the moment you chose it and you should never have to wonder what the trigger is about to do.
## Nothing here calls the backend directly; it goes through the tool scripts that already do.

const Visibility := preload("res://scripts/design_table/visibility.gd")
const PROMPT_FONT_SIZE := 40
const PROMPT_PIXEL_SIZE := 0.0007

const MATE_TYPE_LABELS := {"coincident": "Coincident", "concentric": "Concentric", "parallel": "Parallel", "distance": "Distance", "angle": "Angle"}
const MATE_TYPE_HINTS := {
	"coincident": "Faces touch, edges meet",
	"concentric": "Round things share an axis",
	"parallel": "Faces / edges run alongside",
	"distance": "A set gap (you type it)",
	"angle": "A set angle (you type it)",
}

var tokens: Resource
var _main
var _tablet
var _manager
var _registry
var _mates
var _measure
var _hand
var _design_table
var _swatches: Array = []
var _prompt: Label3D
var _wheel_open := false ## the ring is up: the prompt steps out of its way
var _toast_text := ""
var _toast_until_ms := 0


func setup(ctx: Dictionary, p_tokens: Resource) -> void:
	tokens = p_tokens
	_main = ctx["main"]
	_tablet = ctx["tablet"]
	_manager = _tablet.manager
	_registry = _tablet.registry
	_mates = ctx["mates_tool"]
	_measure = ctx["measure_tool"]
	_hand = ctx["hand"]
	_design_table = ctx.get("design_table")
	_swatches = ctx.get("swatches", [])
	_prompt = Label3D.new()
	_prompt.font_size = PROMPT_FONT_SIZE
	_prompt.pixel_size = PROMPT_PIXEL_SIZE
	_prompt.shaded = false
	_prompt.no_depth_test = true
	_prompt.outline_size = 10
	_prompt.render_priority = 20
	_prompt.outline_render_priority = 19
	_prompt.modulate = tokens.text
	_prompt.outline_modulate = Color(tokens.bg_panel.r, tokens.bg_panel.g, tokens.bg_panel.b, 0.9)
	if tokens.get("font") != null:
		_prompt.font = tokens.get("font")
	_prompt.position = Vector3(0.0, -0.26, -0.85)
	(ctx["camera"] as Node3D).add_child(_prompt)
	_prompt.visible = false
	_manager.active_changed.connect(func(_id: String) -> void: refresh_prompt())
	_mates.picks_changed.connect(refresh_prompt)
	_measure.picks_changed.connect(refresh_prompt)
	_measure.result_changed.connect(refresh_prompt)


# --- The prompt --------------------------------------------------------------------------------

func say(text: String, seconds: float = 3.0) -> void:
	## A short message (a mate created, a measurement failed) shown in the prompt for a few seconds.
	_toast_text = text
	_toast_until_ms = Time.get_ticks_msec() + int(seconds * 1000.0)
	refresh_prompt()


func _process(_delta: float) -> void:
	if _toast_until_ms > 0 and Time.get_ticks_msec() > _toast_until_ms:
		_toast_until_ms = 0
		_toast_text = ""
		refresh_prompt()


func prompt_text() -> String:
	## What the prompt says right now ("" = hidden).
	if _toast_text != "":
		return _toast_text
	match _manager.active_id:
		"mates":
			var type_label: String = MATE_TYPE_LABELS.get(_mates.mate_type, _mates.mate_type)
			return "Mates · %s\n%s\nWheel: Create · Flip · Clear · type" % [type_label, _mates.status_text()]
		"measure":
			var line: String = _measure.status_text()
			if not _measure.result.is_empty():
				line = "Dimensions are on the model; volume, area and mass are on the tablet."
			return "Measure\n%s" % line
		"colour_gun":
			return "Colour gun · %s\nTrigger paints the part you point at." % _gun_hex()
		"shoot_hide":
			return "Shoot hide\nTrigger hides the part you point at (undo brings it back)."
		"sections":
			return "Section\nGrip the plane to move it. Wheel: Flip."
	return ""


func set_wheel_open(on: bool) -> void:
	_wheel_open = on
	refresh_prompt()


func refresh_prompt() -> void:
	var text := prompt_text()
	_prompt.text = text
	_prompt.visible = text != "" and not _wheel_open


func _gun_hex() -> String:
	return _tablet.pages.gun_colour()


# --- Entries -----------------------------------------------------------------------------------

func entries() -> Array:
	## The ring for what you are doing now: the open tool's steps, with "All tools" for everything else.
	match _manager.active_id:
		"mates":
			return _mates_entries()
		"measure":
			return _measure_entries()
		"colour_gun":
			return _colour_entries()
	return root_entries()


func ring_title() -> String:
	## The ring's name above it while nothing is pointed at.
	match _manager.active_id:
		"mates":
			return "Mates"
		"measure":
			return "Measure"
		"colour_gun":
			return "Colour gun"
	return "Tools"


func root_entries() -> Array:
	var has_selection: bool = _main.current_selected_part() != null
	return [
		_tool_entry("mates", "Mates", "mates", Color(0.37, 0.76, 1.00), "Mate two parts together"),
		_tool_entry("measure", "Measure", "measure", Color(0.77, 0.55, 1.00), "Lengths, radii, volume, area"),
		_action("table", "Summon table", "table", Color(1.00, 0.71, 0.33), "Sketch and extrude", _summon_table, true, _design_table != null and _design_table.is_open()),
		_tool_entry("colour_gun", "Colour gun", "colour_gun", Color(0.48, 0.88, 0.69), "Shoot a part to paint it"),
		_tool_entry("shoot_hide", "Shoot hide", "shoot_hide", Color(0.48, 0.88, 0.69), "Shoot a part to hide it"),
		_tool_entry("sections", "Section", "sections", Color(0.77, 0.55, 1.00), "Cut the model with a plane"),
		_submenu("visibility", "Visibility", "visibility", Color(0.48, 0.88, 0.69), "Isolate · show all · invert", visibility_entries.bind(has_selection)),
		_action("undo", "Undo", "undo", Color(0.62, 0.70, 0.80), "Take back the last change", _main.command_stack.undo, _main.command_stack.can_undo()),
	]


func visibility_entries(has_selection: bool = true) -> Array:
	var out := [
		_action("show_all", "Show all", "eye", Color(0.48, 0.88, 0.69), "Bring every part back", _show_all),
		_action("invert", "Invert", "invert", Color(0.48, 0.88, 0.69), "Hidden becomes shown and the reverse", _main.reverse_visibility),
		_action("isolate", "Isolate part", "eye_half", Color(0.48, 0.88, 0.69), "Hide everything but the selected part", _main.isolate_selected, has_selection, false, "Select a part first (trigger on a part)"),
	]
	if _design_table != null and _design_table.is_open() and _design_table.build != null:
		out.append(_submenu("categories", "Categories", "layers", Color(0.48, 0.88, 0.69), "Isolate sketches, bodies, planes...", category_entries))
	return out


func category_entries() -> Array:
	var out := []
	var labels := {Visibility.SKETCHES: "Sketches", Visibility.BODIES: "Bodies", Visibility.SURFACES: "Surfaces", Visibility.CURVES: "Curves", Visibility.PLANES: "Planes"}
	for category in Visibility.FEATURE_CATEGORIES:
		var state: Dictionary = _design_table.build.category_state(category)
		out.append(_action("cat_" + category, labels[category], "layers", Color(0.48, 0.88, 0.69),
			"Show only these (%d)" % int(state.get("total", 0)), isolate_category.bind(category), int(state.get("total", 0)) > 0, false, "None in this part"))
	return out


func isolate_category(category: String) -> void:
	## Hides every feature category except this one on the table (Show all brings them back).
	var build = _design_table.build
	var hidden: Array = []
	for other in Visibility.FEATURE_CATEGORIES:
		if other != category:
			hidden.append_array(Visibility.ids_of(build.features, other, build.rollback_excluded()))
	_main.set_hidden_feature_ids(hidden)
	await _design_table.editor.refresh_view()
	say("Showing only %s" % category)


func _show_all() -> void:
	_main.show_all_parts()
	if _design_table != null and _design_table.is_open() and _design_table.build != null:
		_design_table.build.set_all_visible(true)


func _summon_table() -> void:
	if _design_table == null:
		return
	if _design_table.is_open():
		_design_table.recall()
	else:
		_design_table.open()


func _mates_entries() -> Array:
	return [
		_action("mate_create", "Create", "check", Color(0.40, 0.90, 0.60), "Make this mate", _create_mate, _mates.can_create(), false, "Pick two faces first"),
		_action("mate_flip", "Flip", "flip", Color(0.37, 0.76, 1.00), "Turn the preview round", _flip_mate, _mates.can_create(), false, "Pick two faces first"),
		_action("mate_clear", "Clear picks", "clear_picks", Color(0.96, 0.69, 0.25), "Start again", _mates.clear_picks),
		_submenu("mate_type", "Type", "mates", Color(0.37, 0.76, 1.00), "Coincident, concentric...", _mate_type_entries),
		_action("mate_exit", "Done", "close", Color(0.62, 0.70, 0.80), "Switch the tool off", _manager.deactivate),
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
	]


func _mate_type_entries() -> Array:
	var out := []
	for type in _mates.MATE_TYPES:
		out.append(_action("type_" + type, MATE_TYPE_LABELS[type], "mates", Color(0.37, 0.76, 1.00), MATE_TYPE_HINTS[type], _set_mate_type.bind(type), true, _mates.mate_type == type))
	return out


func _set_mate_type(type: String) -> void:
	_mates.mate_type = type
	if type == "distance" or type == "angle":
		var unit := "mm" if type == "distance" else "degrees"
		_main.open_keyboard_for(("%.3f" % _mates.mate_value).rstrip("0").rstrip("."), _apply_mate_value.bind(type, unit), {"title": "%s (%s)" % [MATE_TYPE_LABELS[type], unit]})
	refresh_prompt()


func _apply_mate_value(text: String, type: String, unit: String) -> void:
	_mates.mate_value = text.to_float()
	say("%s %s %s" % [MATE_TYPE_LABELS[type], text, unit])


func _flip_mate() -> void:
	_mates.mate_flipped = not _mates.mate_flipped


func _create_mate() -> void:
	var result: Dictionary = await _mates.create_mate()
	say("Mate created." if result.get("ok", false) else "Couldn't create the mate: %s" % result.get("error", ""), 4.0)


func _measure_entries() -> Array:
	return [
		_action("measure_clear", "Clear", "clear_picks", Color(0.96, 0.69, 0.25), "Start a new measurement", _measure.clear_picks),
		_action("measure_tablet", "Tablet", "tablet", Color(0.77, 0.55, 1.00), "Volume, area, mass", open_measure_tablet),
		_action("measure_exit", "Done", "close", Color(0.62, 0.70, 0.80), "Switch the tool off", _manager.deactivate),
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
	]


func _colour_entries() -> Array:
	var out := []
	for swatch in _swatches:
		var colour := Color.html(swatch["hex"])
		out.append(_action("colour_" + str(swatch["name"]), swatch["name"], "colours", colour, "Fire %s" % str(swatch["name"]).to_lower(),
			_set_gun_colour.bind(swatch["hex"]), true, _gun_hex() == swatch["hex"]))
	out.append(_action("colour_exit", "Done", "close", Color(0.62, 0.70, 0.80), "Switch the gun off", _manager.deactivate))
	out.append(_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries))
	return out


func _set_gun_colour(hex: String) -> void:
	_tablet.pages.set_gun_colour(hex)
	refresh_prompt()


func open_measure_tablet() -> void:
	## Measure's volume / area / mass live on the tablet's side panel: bring the tablet up on the Measure tool.
	if not _tablet.is_open():
		_tablet.open_tablet()
	_tablet.ui.select_tool("measure")


# --- Entry builders ----------------------------------------------------------------------------

func _tool_entry(tool_id: String, label: String, icon: String, accent: Color, hint: String) -> Dictionary:
	## A mode tool: choosing it switches it on (or off if it already is). Measure also opens the tablet.
	var on: bool = _manager.is_active(tool_id)
	return {"id": tool_id, "label": label, "icon": icon, "accent": accent, "hint": ("Switch off · " if on else "") + hint, "active": on,
		"enabled": _registry.tool_def(tool_id) != null, "hint_disabled": "Not available",
		"run": _toggle_tool.bind(tool_id)}


func _toggle_tool(tool_id: String) -> void:
	var now_on: bool = _manager.toggle(tool_id)
	if now_on and tool_id == "measure":
		open_measure_tablet()
	refresh_prompt()


func _action(id: String, label: String, icon: String, accent: Color, hint: String, run: Callable, enabled: bool = true, active: bool = false, hint_disabled: String = "Not available right now") -> Dictionary:
	return {"id": id, "label": label, "icon": icon, "accent": accent, "hint": hint, "enabled": enabled, "active": active, "hint_disabled": hint_disabled, "run": run}


func _submenu(id: String, label: String, icon: String, accent: Color, hint: String, children: Callable) -> Dictionary:
	return {"id": id, "label": label, "icon": icon, "accent": accent, "hint": hint + " · move out", "enabled": true, "children": children}
