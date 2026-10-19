extends Node3D
## What the tool wheel offers, and the one-line prompt that leads you through a tool.
##
## The ring follows what you are doing. With no tool on it is the root ring of everyday tools. With Mates on,
## the first wedges are the Mates steps (Create, Flip, Clear picks, the mate type); with Measure on, Clear and
## the tablet; with Paint on, the palette. "All tools" in each of those is a sub-wheel with the root
## ring, so any tool is still one gesture away. Every tool is switched on through ToolManager (the tablet's
## own path), so the badge, the tablet chip and the one-active-tool rule stay right.
##
## What the right wrist's hint panel (wrist_hint.gd) says is decided here too: while the wheel is up it is the tool tip for
## the tile the hand points at; with a mode tool on and the wheel down it says what the trigger will do now (pick the
## first face, pick the second, a preview is showing...), because a tool can outlive the moment you chose it and you
## should never have to wonder what the trigger is about to do.
## Nothing here calls the backend directly; it goes through the tool scripts that already do.

const Visibility := preload("res://scripts/design_table/visibility.gd")
const WristHint := preload("res://scripts/ui/wrist_hint.gd")

const MATE_TYPE_LABELS := {"coincident": "Coincident", "concentric": "Concentric", "parallel": "Parallel", "distance": "Distance", "angle": "Angle", "width": "Width", "symmetric": "Symmetric"}
const MATE_TYPE_HINTS := {
	"coincident": "Faces touch, edges meet",
	"concentric": "Round things share an axis",
	"parallel": "Faces / edges run alongside",
	"distance": "A set gap (you type it)",
	"angle": "A set angle (you type it)",
	"width": "Centre between two faces (4 picks)",
	"symmetric": "Mirror two faces about a plane (3 picks)",
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
var _hint: Node3D ## wrist_hint.gd, on the right wrist
var _ring_shown := false ## the wheel is up: the panel shows its tool tip instead of the tool prompt
var _wheel_summary: Dictionary = {}
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
	_hint = WristHint.new()
	_hint.name = "WristHint"
	_hint.setup(_hand, tokens)
	_manager.active_changed.connect(func(_id: String) -> void: refresh_prompt())
	_mates.picks_changed.connect(refresh_prompt)
	if _mates.has_signal("sandbox_changed"):
		_mates.sandbox_changed.connect(func(_on: bool) -> void: refresh_prompt())
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
			return "Mates · %s\n%s\nWheel: Create · Flip · %s · type" % [type_label, _mates.status_text(), "Undo pick" if _mates.is_multi() else "Clear"]
		"measure":
			var line: String = _measure.status_text()
			if not _measure.result.is_empty():
				line = "Dimensions are on the model; volume, area and mass are on the tablet."
			return "Measure\n%s" % line
		"paint":
			return "Appearance · %s\nClick paints the body; hold the trigger to choose what." % _paint_hex()
		"shoot_hide":
			return "Shoot hide\nTrigger hides the part you point at (undo brings it back)."
		"sections":
			return "Section\nGrip the plane to move it. Wheel: Flip."
	if _mates != null and _mates.relaxed:
		return "Mates relaxed\nMoves are temporary. Wheel: Return parts (under the ring) puts everything back."
	return ""


func on_ring_shown(shown: bool) -> void:
	## The wheel's ring went up or down (wheel signal): up, the wrist panel is the tool tip; down, it is the tool prompt again.
	_ring_shown = shown
	refresh_prompt()


func on_wheel_summary(summary: Dictionary) -> void:
	## What the wheel is pointing at (wheel signal).
	_wheel_summary = summary
	if _ring_shown:
		refresh_prompt()


func hint_panel() -> Node3D:
	return _hint


func _tool_accent() -> Color:
	var cat = _registry.category_of(_manager.active_id) if _manager.active_id != "" else null
	return cat.accent if cat != null else tokens.accent


func refresh_prompt() -> void:
	## Puts the right thing on the wrist panel: the wheel's tool tip while the ring is up, else the open tool's prompt.
	if _ring_shown and not _wheel_summary.is_empty():
		_hint.show_text(str(_wheel_summary.get("title", "")), str(_wheel_summary.get("body", "")), _wheel_summary.get("accent", tokens.accent), str(_wheel_summary.get("tone", "normal")))
		return
	var text := prompt_text()
	if text == "":
		_hint.clear()
		return
	var lines := text.split("\n")
	_hint.show_text(lines[0], "\n".join(lines.slice(1)), _tool_accent())


func _paint_hex() -> String:
	return _tablet.pages.paint_colour()


# --- Entries -----------------------------------------------------------------------------------

func entries() -> Array:
	## The ring for what you are doing now: the open tool's steps, with "All tools" for everything else.
	match _manager.active_id:
		"mates":
			return _mates_entries()
		"measure":
			return _measure_entries()
		"paint":
			return _colour_entries()
	return root_entries()


func _relax_entry() -> Dictionary:
	## Relax mates / Return parts: the sandbox (mates_tool.gd set_relaxed). Its label says what choosing it will do.
	if _mates.relaxed:
		return _action("mate_relax", "Return parts", "undo", Color(0.96, 0.69, 0.25), "Everything goes back where it was", _return_parts, true, true)
	return _action("mate_relax", "Relax mates", "relax", Color(0.96, 0.69, 0.25), "Move anything; it all goes back after", _relax_mates)


func _relax_mates() -> void:
	_mates.set_relaxed(true)
	say("Mates relaxed: moves are temporary", 3.0)


func _return_parts() -> void:
	var scenes = _scenes()
	if scenes != null and scenes.scene_unsaved():
		# The shown scene has unsaved changes: the Scenes page asks (Update / Discard / Stay) instead of losing them.
		scenes.request_back()
		_open_scenes_tablet()
		say("Unsaved scene: choose on the tablet", 3.0)
		return
	say("Returning parts", 2.0)
	await _mates.set_relaxed(false)
	refresh_prompt()


func pill_entry() -> Dictionary:
	## The pill under every top-level ring: put the tool away. Greyed (with the reason) when there is nothing in the hand.
	## While mates are relaxed it is Return parts instead, on every ring: leaving the sandbox never needs navigating.
	if _mates != null and _mates.relaxed:
		return {"id": "return_parts", "label": "Return", "title": "Return parts", "icon": "undo", "accent": Color(0.96, 0.69, 0.25), "enabled": true,
			"hint": "Mates are relaxed: every part goes back where it was", "hint_disabled": "", "run": _return_parts}
	var in_hand: bool = _manager.active_id != ""
	var def = _registry.tool_def(_manager.active_id) if in_hand else null
	return {"id": "clear_tool", "label": "Clear", "title": "Clear tool", "icon": "close", "accent": Color(0.62, 0.70, 0.80), "text_colour": tokens.danger, "enabled": in_hand,
		"hint": "Put %s away: hands free" % (str(def.label) if def != null else "the tool"), "hint_disabled": "Nothing in your hand",
		"run": _clear_tool}


func _clear_tool() -> void:
	_manager.deactivate()
	say("Hands free", 2.0)


func ring_title() -> String:
	## The ring's name above it while nothing is pointed at.
	match _manager.active_id:
		"mates":
			return "Mates"
		"measure":
			return "Measure"
		"paint":
			return "Appearance"
	return "Tools"


func root_entries() -> Array:
	var has_selection: bool = _main.current_selected_part() != null
	return [
		_tool_entry("mates", "Mates", "mates", Color(0.37, 0.76, 1.00), "Mate two parts together"),
		_tool_entry("measure", "Measure", "measure", Color(0.77, 0.55, 1.00), "Lengths, radii, volume, area"),
		_action("table", "Summon table", "table", Color(1.00, 0.71, 0.33), "Sketch and extrude", _summon_table, true, _design_table != null and _design_table.is_open()),
		_tool_entry("paint", "Appearance", "paint", Color(0.48, 0.88, 0.69), "Paint colour, see-through, shine, glow"),
		_tool_entry("shoot_hide", "Shoot hide", "shoot_hide", Color(0.48, 0.88, 0.69), "Shoot a part to hide it"),
		_tool_entry("sections", "Section", "sections", Color(0.77, 0.55, 1.00), "Cut the model with a plane"),
		_submenu("visibility", "Visibility", "visibility", Color(0.48, 0.88, 0.69), "Isolate · show all · invert", visibility_entries.bind(has_selection)),
		_action("undo", "Undo", "undo", Color(0.62, 0.70, 0.80), "Take back the last change", _main.command_stack.undo, _main.command_stack.can_undo()),
		_submenu("scenes", "Scenes", "scenes", Color(0.96, 0.69, 0.25), "Show · save · back to default", scenes_entries),
	]


func _scenes():
	return _main.get("scenes_tool") if _main != null else null


func scenes_entries() -> Array:
	## The Scenes sub-wheel (scenes_tool.gd): Back to default, Update, Save as new, then a wedge per scene (the first six).
	var scenes = _scenes()
	if scenes == null:
		return []
	var accent := Color(0.96, 0.69, 0.25)
	var shown_id: String = scenes.shown_id()
	var out := [
		_action("scene_back", "Default", "undo", accent, "Back to default: every part back where it is", _scene_back, _mates != null and _mates.relaxed, false, "Nothing is moved: this is the default"),
		_action("scene_update", "Update", "check", accent, "Keep what is on screen in \"%s\"" % scenes.shown_name(), _scene_update, shown_id != "", false, "Show a scene first"),
		_action("scene_new", "Save new", "scenes", accent, "Save what is on screen as a new scene", _scene_new),
	]
	for scene in scenes.scenes_of().slice(0, 6):
		var id := str(scene.get("id", ""))
		out.append(_action("scene_" + id, str(scene.get("name", "")), "image", accent, "Show this scene", _scene_show.bind(id), true, id == shown_id))
	return out


func _scene_back() -> void:
	var r: String = await _scenes().request_back()
	if r == "ask":
		_open_scenes_tablet()
		say("Unsaved scene: choose on the tablet", 3.0)
	refresh_prompt()


func _scene_update() -> void:
	var r: Dictionary = await _scenes().update_scene()
	say("Scene updated" if r["ok"] else str(r["error"]), 3.0)


func _scene_new() -> void:
	_open_scenes_tablet() # the name is typed on the tablet's keyboard
	if _tablet.pages.get("_scenes_page") != null:
		_tablet.pages._scenes_page._on_save_new()


func _scene_show(scene_id: String) -> void:
	var r: String = await _scenes().request_show(scene_id)
	if r == "ask":
		_open_scenes_tablet()
		say("Unsaved scene: choose on the tablet", 3.0)
	elif r == "shown":
		say("Showing \"%s\"" % _scenes().shown_name(), 3.0)
	refresh_prompt()


func _open_scenes_tablet() -> void:
	if not _tablet.is_open():
		_tablet.open_tablet()
	_tablet.ui.select_tool("scenes")


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
	## The bottom 60 degrees of a top-level ring belong to the "Clear" pill, so a sub-wheel never sits there (the hand
	## would drill into it on the way to the pill): with six wedges Clear picks is the one straight down, Flip and Relax either side.
	var need := _mates_pick_hint()
	# A Width mate has four picks and a Symmetric one three, so "start again" is a heavy undo: that wedge takes back the LAST pick instead
	# (undo a few times to clear).
	var picks_entry: Dictionary
	if _mates.is_multi():
		picks_entry = _action("mate_undo", "Undo pick", "undo", Color(0.96, 0.69, 0.25), "Take back the last face", _mates.back_pick, not _mates.picked_labels().is_empty(), false, "Nothing picked yet")
	else:
		picks_entry = _action("mate_clear", "Clear picks", "clear_picks", Color(0.96, 0.69, 0.25), "Start again", _mates.clear_picks)
	return [
		_action("mate_create", "Create", "check", Color(0.40, 0.90, 0.60), "Make this mate", _create_mate, _mates.can_create(), false, need),
		_submenu("mate_type", "Type", "mates", Color(0.37, 0.76, 1.00), "Coincident, concentric...", _mate_type_entries),
		_action("mate_flip", "Flip", "flip", Color(0.37, 0.76, 1.00), "Turn the preview round", _flip_mate, _mates.can_create(), false, need),
		picks_entry, # (straight down, above the pill: never a sub-wheel there)
		_relax_entry(),
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
	]


func _mates_pick_hint() -> String:
	## Why Create / Flip are greyed: how many picks the current mate type needs.
	if _mates.is_width():
		return "Pick the four faces first"
	if _mates.is_symmetric():
		return "Pick the three faces first"
	return "Pick two faces first"


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
	elif type == "width":
		# The optional offset from the centre (0 = centred exactly); the tablet's Set value button does the same.
		_main.open_keyboard_for(("%.3f" % _mates.width_offset).rstrip("0").rstrip("."), _apply_width_offset, {"title": "Width offset from centre (mm, 0 = centred)"})
	refresh_prompt()


func _apply_width_offset(text: String) -> void:
	var parsed: Dictionary = _mates.parse_value("distance", text) # never negative: the side is the Flip control
	if not parsed["ok"]:
		say(str(parsed["error"]), 4.0)
		return
	_mates.width_offset = float(parsed["value"])
	say("Width centred" if _mates.width_offset == 0.0 else "Width offset %s mm" % text)


func _apply_mate_value(text: String, type: String, unit: String) -> void:
	var parsed: Dictionary = _mates.parse_value(type, text)
	if not parsed["ok"]:
		say(str(parsed["error"]), 4.0)
		return
	_mates.mate_value = float(parsed["value"])
	say("%s %s %s" % [MATE_TYPE_LABELS[type], text, unit])


func _flip_mate() -> void:
	## Turns the preview round: the orientation if the picked geometry has one, else the side / spin / supplement (tablet: Next solution).
	_mates.flip_mate()


func _create_mate() -> void:
	var result: Dictionary = await _mates.create_mate()
	say("Mate created." if result.get("ok", false) else "Couldn't create the mate: %s" % result.get("error", ""), 4.0)


func _measure_entries() -> Array:
	return [
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
		_action("measure_clear", "Clear", "clear_picks", Color(0.96, 0.69, 0.25), "Start a new measurement", _measure.clear_picks),
		_action("measure_tablet", "Tablet", "tablet", Color(0.77, 0.55, 1.00), "Volume, area, mass", open_measure_tablet),
	]


func _colour_entries() -> Array:
	var out := []
	for swatch in _swatches:
		var colour := Color.html(swatch["hex"])
		out.append(_action("colour_" + str(swatch["name"]), swatch["name"], "colours", colour, "Paint with %s" % str(swatch["name"]).to_lower(),
			_set_paint_colour.bind(swatch["hex"]), true, _paint_hex() == str(swatch["hex"]).to_upper()))
	out.append(_action("colour_clear", "Clear", "close", Color(0.62, 0.70, 0.80), "Paint Clear: removes that level's own paint", _set_paint_clear, true, _paint_hex() == "Clear"))
	out.append(_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries))
	return out


func _set_paint_clear() -> void:
	_tablet.pages.set_paint_clear()
	refresh_prompt()


func _set_paint_colour(hex: String) -> void:
	_tablet.pages.set_paint_colour(hex)
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
	return {"id": id, "label": label, "icon": icon, "accent": accent, "hint": hint + " · rest on it or move out", "enabled": true, "children": children}
