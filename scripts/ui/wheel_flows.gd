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

const MATE_TYPE_LABELS := {"coincident": "Coincident", "concentric": "Concentric", "peg_in_hole": "Peg in hole", "parallel": "Parallel", "distance": "Distance", "angle": "Angle", "width": "Width", "symmetric": "Symmetric", "gear": "Gear", "rack_pinion": "Rack and pinion", "screw": "Screw", "limit_distance": "Limit distance", "limit_angle": "Limit angle"}
const MATE_TYPE_HINTS := {
	"coincident": "Faces touch, edges meet",
	"concentric": "Round things share an axis",
	"peg_in_hole": "A pin seated in a hole (a rim on each part)",
	"parallel": "Faces / edges run alongside",
	"distance": "A set gap (you type it)",
	"angle": "A set angle (you type it)",
	"width": "Centre between two faces (4 picks)",
	"symmetric": "Mirror two faces about a plane (3 picks)",
	"gear": "Turning one turns the other (2 round things)",
	"rack_pinion": "A gear turns a rack along its edge",
	"screw": "A nut climbs a screw as it turns (you type the lead)",
	"limit_distance": "A gap that stops at a min / max (you type them)",
	"limit_angle": "A hinge that stops at a min / max angle",
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
	var drive = _main.get("drive_tool")
	if drive != null:
		drive.status_changed.connect(refresh_prompt)
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
			return "Hide tool\nTrigger hides the part you point at (undo brings it back)."
		"sections":
			return "Section\nGrip the plane to move it. Wheel: Flip."
		"drive":
			var drive = _main.get("drive_tool")
			return "Drive\n%s" % (drive.status_text() if drive != null else "")
	if _mates != null and _mates.relaxed:
		return "Mates relaxed\nMoves are temporary. Wheel: Return parts (under the ring) puts everything back."
	if _mates != null and _mates.relaxed_fixed:
		return "Fix mates relaxed\nGrab a fixed part and its assembly comes with it. Return puts everything back."
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
		"drive":
			return _drive_entries()
		"sections":
			return _section_entries()
		"paint":
			return _colour_entries()
	return root_entries()


func _relax_entry() -> Dictionary:
	## Relax mates / Return parts: the sandbox (mates_tool.gd set_relaxed). Its label says what choosing it will do.
	if _mates.relaxed:
		return _action("mate_relax", "Return parts", "undo", Color(0.96, 0.69, 0.25), "Everything goes back where it was", _return_parts, true, true)
	return _action("mate_relax", "Relax mates", "relax", Color(0.96, 0.69, 0.25), "Move anything; it all goes back after", _relax_mates)


func _relax_fix_entry() -> Dictionary:
	## V-6, Relax fix: only the fixed flag is relaxed, so a grounded assembly can be carried with every mate kept. While it is on the wedge reads Return.
	var accent := Color(0.96, 0.69, 0.25)
	if _mates.relaxed_fixed:
		return _action("mate_relax_fix", "Return", "undo", accent, "Everything goes back where it was", _return_parts, true, true)
	return _action("mate_relax_fix", "Relax fix", "pin", accent, "Carry a fixed assembly with its mates kept; it all goes back after", _relax_fix, not _mates.relaxed, false, "Mates are already relaxed")


func _relax_fix() -> void:
	_mates.set_relaxed_fixed(true)
	say("Fix mates relaxed: grab a fixed part and its assembly comes with it", 3.0)


func _open_tree() -> void:
	## The Tree wedge: the Assembly Tree, where Fix / Float lives (V-5).
	var window = _main.get("_assembly_tree_window")
	if window != null:
		window.open()


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
	await _mates.return_parts()
	refresh_prompt()


func pill_entry() -> Dictionary:
	## The pill under every top-level ring: put the tool away. Greyed (with the reason) when there is nothing in the hand.
	## While mates are relaxed it is Return parts instead, on every ring: leaving the sandbox never needs navigating.
	if _mates != null and (_mates.relaxed or _mates.relaxed_fixed):
		return {"id": "return_parts", "label": "Return", "title": "Return parts", "icon": "undo", "accent": Color(0.96, 0.69, 0.25), "enabled": true,
			"hint": "Mates are relaxed: every part goes back where it was" if _mates.relaxed else "Fix mates are relaxed: every part goes back where it was", "hint_disabled": "", "run": _return_parts}
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
		"drive":
			return "Drive"
		"paint":
			return "Appearance"
	return "Tools"


func root_entries() -> Array:
	## Tools (they switch on and bring their own ring) and actions, then the two menus. Where a name goes is set by how wide its tile is at the height of the name
	## (the tiles at three and nine o'clock are the narrow ones): the long names are on the wide tiles.
	var has_selection: bool = _main.current_selected_part() != null
	return [
		_tool_entry("mates", "Mates", "mates", Color(0.37, 0.76, 1.00), "Mate two parts together"),
		_tool_entry("measure", "Measure", "measure", Color(0.77, 0.55, 1.00), "Lengths, radii, volume, area"),
		_action("table", "Summon table", "table", Color(1.00, 0.71, 0.33), "Sketch and extrude", _summon_table, true, _design_table != null and _design_table.is_open()),
		_tool_entry("sections", "Section", "sections", Color(0.77, 0.55, 1.00), "Cut the model with a plane"),
		_tool_entry("drive", "Drive", "movement", Color(0.37, 0.76, 1.00), "Turn a part so its gears run"),
		_tool_entry("paint", "Appearance", "paint", Color(0.48, 0.88, 0.69), "Control the appearance of the models"),
		_submenu("visibility", "Show / Hide", "visibility", Color(0.48, 0.88, 0.69), "Show / hide parts", visibility_entries.bind(has_selection)),
		_action("undo", "Undo", "undo", Color(0.62, 0.70, 0.80), "Take back the last change", _main.command_stack.undo, _main.command_stack.can_undo()),
		_submenu("scenes", "Scenes", "scenes", Color(0.96, 0.69, 0.25), "Temporarily change part positions and visibility", scenes_entries),
		_action("home", "Home", "home", Color(0.62, 0.70, 0.80), "Back to the landing: demos, tips, logo", _main.go_home),
	]


func _scenes():
	return _main.get("scenes_tool") if _main != null else null


func scenes_entries() -> Array:
	## The Scenes sub-wheel (scenes_tool.gd), clockwise from the top: Start scene (green: relaxes the mates, a sandbox where moves are temporary), the saved scenes
	## (a wedge each, the first six: choosing one shows it, which starts a scene too), Abandon (red: every part back at its mate position; asks first if the scene
	## has unsaved changes), then Update and Save new. Start and Abandon are the way in and the way out, at opposite ends of the ring and filled in their colours.
	var scenes = _scenes()
	if scenes == null:
		return []
	var accent := Color(0.96, 0.69, 0.25)
	var green := Color(0.40, 0.90, 0.55)
	var red := Color(0.95, 0.42, 0.42)
	var shown_id: String = scenes.shown_id()
	var in_scene: bool = _mates != null and _mates.relaxed
	var start := _action("scene_start", "Start scene", "play", green, "Relax the mates so you can move and hide parts; Abandon puts everything back", _relax_mates, not in_scene, false, "Already in a scene: Abandon it first")
	start["tint"] = green
	var out := [start]
	for scene in scenes.scenes_of().slice(0, 6):
		var id := str(scene.get("id", ""))
		out.append(_action("scene_" + id, str(scene.get("name", "")), "image", accent, "Show this scene", _scene_show.bind(id), true, id == shown_id))
	var abandon := _action("scene_abandon", "Abandon", "stop", red, "Abandon the scene: every part back at its mate position", _scene_back, in_scene, false, "No scene started")
	abandon["tint"] = red
	out.append(abandon)
	out.append(_action("scene_update", "Update", "check", accent, "Keep what is on screen in \"%s\"" % scenes.shown_name(), _scene_update, shown_id != "", false, "Show a scene first"))
	out.append(_action("scene_new", "Save new", "scenes", accent, "Save what is on screen as a new scene", _scene_new))
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
		_action("isolate", "Isolate part", "eye_half", Color(0.48, 0.88, 0.69), "Hide everything but the selected part", _main.isolate_selected, has_selection, false, "Select a part first (trigger on a part)"),
		_action("invert", "Invert", "invert", Color(0.48, 0.88, 0.69), "Hidden becomes shown and the reverse", _main.reverse_visibility),
		_tool_entry("shoot_hide", "Hide tool", "shoot_hide", Color(0.48, 0.88, 0.69), "Point at a part and pull the trigger to hide it"),
		_action("show_all", "Show all", "eye", Color(0.48, 0.88, 0.69), "Bring every part back", _show_all),
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
	## The bottom 60 degrees of a top-level ring belong to the "Clear" pill, so a sub-wheel never sits there (the hand would drill into it on the way to the
	## pill). Wedge i is centred at i * 360 / count degrees from the top, so only an EVEN count has a wedge straight down: eight wedges (V-5), clockwise from the top:
	## Create (0) - Type (45) - Flip (90) - Relax fix (135) - Clear picks (180, straight down) - Relax / Return parts (225) - Tree (270) - All tools (315).
	var need := _mates_pick_hint()
	# A Width mate has four picks and a Symmetric one three, so "start again" is a heavy undo: that wedge takes back the LAST pick instead
	# (undo a few times to clear).
	var picks_entry: Dictionary
	if _mates.is_multi():
		picks_entry = _action("mate_undo", "Undo pick", "undo", Color(0.96, 0.69, 0.25), "Take back the last face", _mates.back_pick, not _mates.picked_labels().is_empty(), false, "Nothing picked yet")
	else:
		picks_entry = _action("mate_clear", "Clear picks", "clear_picks", Color(0.96, 0.69, 0.25), "Start again", _mates.clear_picks)
	var flip_label := "Flip"
	var flip_hint := "Turn the preview round"
	if _mates.is_coupler():
		# A coupler has no ghost to turn round: the same wedge chooses which way the second part turns (Reverse; Left-hand for a screw).
		flip_label = _mates.secondary_flip_label(_mates.mate_type)
		flip_hint = "Which way the second part turns"
	return [
		_action("mate_create", "Create", "check", Color(0.40, 0.90, 0.60), "Make this mate", _create_mate, _mates.can_create(), false, need),
		_submenu("mate_type", "Type", "mates", Color(0.37, 0.76, 1.00), "Coincident, concentric...", _mate_type_entries),
		_action("mate_flip", flip_label, "flip", Color(0.37, 0.76, 1.00), flip_hint, _flip_mate, _mates.can_create(), false, need),
		_relax_fix_entry(),
		picks_entry, # (straight down, above the pill: never a sub-wheel there)
		_relax_entry(),
		_action("mate_tree", "Tree", "tree", Color(0.62, 0.70, 0.80), "Open the Assembly Tree: Fix / Float is there", _open_tree),
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
	]


func _mates_pick_hint() -> String:
	## Why Create / Flip are greyed: how many picks the current mate type needs.
	if _mates.is_width():
		return "Pick the four faces first"
	if _mates.is_symmetric():
		return "Pick the three faces first"
	return "Pick two faces first"


## The Type ring is kept small (twelve crowded the labels and left no room for a distinct icon each): the basic types, then two sub-rings. M4 added
## Peg in hole after Concentric (eight wedges now: not judged on the headset).
const MATE_RING_BASIC := ["coincident", "concentric", "peg_in_hole", "parallel", "distance", "angle"]
const MATE_RING_CENTRE := ["width", "symmetric"]
const MATE_RING_MOTION := ["gear", "rack_pinion", "screw", "limit_distance", "limit_angle"]


func _mate_type_entries() -> Array:
	var out := _mate_type_actions(MATE_RING_BASIC)
	out.append(_submenu("type_centre", "Centre", "mate_width", Color(0.37, 0.76, 1.00), "Width and Symmetric", _mate_centre_entries))
	out.append(_submenu("type_motion", "Motion", "mate_gear", Color(0.37, 0.76, 1.00), "Gear, rack, screw, limits", _mate_motion_entries))
	return out


func _mate_centre_entries() -> Array:
	return _mate_type_actions(MATE_RING_CENTRE)


func _mate_motion_entries() -> Array:
	return _mate_type_actions(MATE_RING_MOTION)


func _mate_type_actions(types: Array) -> Array:
	var out := []
	for type in types:
		out.append(_action("type_" + type, MATE_TYPE_LABELS[type], "mate_" + type, Color(0.37, 0.76, 1.00), MATE_TYPE_HINTS[type], _set_mate_type.bind(type), true, _mates.mate_type == type))
	return out


func _set_mate_type(type: String) -> void:
	_mates.mate_type = type
	if type == "distance" and not _mates.value_typed:
		# M4.1: nothing typed for these picks: the ghost holds the distance the parts are apart now (measured), so the keyboard starts on it
		# once known and an empty entry keeps it
		var shown: String = ("%.3f" % float(_mates.measured_value)).rstrip("0").rstrip(".") if _mates.measured_value != null else ""
		_main.open_keyboard_for(shown, _apply_mate_value.bind(type, "mm"), {"title": "Distance (mm; empty keeps the measured distance)"})
	elif type == "distance" or type == "angle":
		var unit := "mm" if type == "distance" else "degrees"
		_main.open_keyboard_for(("%.3f" % _mates.mate_value).rstrip("0").rstrip("."), _apply_mate_value.bind(type, unit), {"title": "%s (%s)" % [MATE_TYPE_LABELS[type], unit]})
	elif type == "screw":
		_main.open_keyboard_for("", _apply_mate_value.bind(type, "mm per turn"), {"title": _mates.value_prompt(type)})
	elif type in _mates.LIMIT_TYPES:
		_ask_limit_range(type)
	elif type == "width":
		# The optional offset from the centre (0 = centred exactly); the tablet's Set value button does the same.
		_main.open_keyboard_for(("%.3f" % _mates.width_offset).rstrip("0").rstrip("."), _apply_width_offset, {"title": "Width offset from centre (mm, 0 = centred)"})
	refresh_prompt()


func _ask_limit_range(type: String) -> void:
	## Minimum, then maximum (empty = none) on the keyboard; the same range the tablet's Set value asks.
	var unit := "degrees" if type == "limit_angle" else "mm"
	_main.open_keyboard_for("", func(min_text: String) -> void:
		var parsed_min: Dictionary = _mates.parse_limit_bound(type, min_text)
		if not parsed_min["ok"]:
			say(str(parsed_min["error"]), 4.0)
			return
		_main.open_keyboard_for("", func(max_text: String) -> void:
			var parsed_max: Dictionary = _mates.parse_limit_bound(type, max_text)
			if not parsed_max["ok"]:
				say(str(parsed_max["error"]), 4.0)
				return
			var problem: String = _mates.limit_range_error(parsed_min["value"], parsed_max["value"])
			if problem != "":
				say(problem, 4.0)
				return
			_mates.limit_min = parsed_min["value"]
			_mates.limit_max = parsed_max["value"]
			say("%s %s" % [MATE_TYPE_LABELS[type], _mates.limit_range_text(type, _mates.limit_min, _mates.limit_max)])
		, {"title": "Maximum (%s, empty = none)" % unit})
	, {"title": "Minimum (%s, empty = none)" % unit})


func _apply_width_offset(text: String) -> void:
	var parsed: Dictionary = _mates.parse_value("distance", text) # never negative: the side is the Flip control
	if not parsed["ok"]:
		say(str(parsed["error"]), 4.0)
		return
	_mates.width_offset = float(parsed["value"])
	say("Width centred" if _mates.width_offset == 0.0 else "Width offset %s mm" % text)


func _apply_mate_value(text: String, type: String, unit: String) -> void:
	if type == "distance" and text.strip_edges() == "" and not _mates.value_typed:
		say("Distance: the measured one, where the parts are now" if _mates.measured_value != null else "Distance: type a value")
		return # M4.1: empty keeps the measured distance (nothing typed)
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


func _section_entries() -> Array:
	## The prompt says "Wheel: Flip", so the ring has it: Flip is on while the other side of the plane is the one that stays.
	var section = _main.get("_section_tool")
	var flipped: bool = section != null and bool(section.flipped)
	return [
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
		_action("section_flip", "Flip", "flip", Color(0.77, 0.55, 1.00), "Keep the other side of the plane", _flip_section, section != null, flipped, "Not available"),
	]


func _flip_section() -> void:
	var section = _main.get("_section_tool")
	if section != null:
		section.set_flipped(not bool(section.flipped))


func _drive_entries() -> Array:
	var drive = _main.get("drive_tool")
	var running: bool = drive != null and drive.running
	return [
		_submenu("all_tools", "All tools", "tools", Color(0.62, 0.70, 0.80), "Switch to another tool", root_entries),
		_action("drive_stop", "Stop", "close", Color(0.96, 0.69, 0.25), "Stop the drive (B does the same)", drive.stop if drive != null else Callable(), running, false, "Nothing is running"),
		_action("drive_tablet", "Tablet", "tablet", Color(0.37, 0.76, 1.00), "The Drive page", open_drive_tablet),
	]


func open_drive_tablet() -> void:
	if not _tablet.is_open():
		_tablet.open_tablet()
	_tablet.ui.select_tool("drive")


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
