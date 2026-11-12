extends "res://scripts/diegetic_panel.gd"
## Milestone 3: the interactive assembly tree named in the vision brief's
## Assembly-tools list but never built until now. Browses the loaded
## assembly's Occurrence hierarchy - GET /document/parts/{id}/occurrences,
## recursed lazily on expand, the same real endpoint appearance_tool.gd's own
## "whole group" feature already proved (see that script's docstring for
## why there's no single nested-tree endpoint to call instead) - and lets
## you select a part by name/structure instead of only by already looking
## at it and laser-pointing at its geometry.
##
## v1 scope: browse and tap-to-select. "Pull a tree node into world space"
## (the vision brief's literal wording) is real further scope of its own -
## duplicating geometry, or breaking a mate server-side, either one a
## design question worth its own pass - and isn't attempted here; see
## docs/status.md.
##
## Only LEAF placed Occurrences (the ones with their own rendered geometry)
## can actually be selected in the 3D view - an intermediate row (a sub-
## assembly with its own children) has no mesh of its own in
## assembly-mesh.glb at all (see mesh_identity.gd's own docstring: one node
## per placed *leaf* instance), so tapping one shows a status message
## instead of silently doing nothing.

const BackendSession := preload("res://scripts/backend_session.gd") ## the API key and this app's own X-Document-Session on every call
const Model := preload("res://scripts/tree/occurrence_tree_model.gd") ## rows, instance names, state icons, the bar's actions (pure, tests/occurrence_tree_model.gd)
const API_PREFIX := "/document"
const ROW_HEIGHT := 56.0
const REFRESH_DELAY_S := 0.4 ## live refresh: a burst of changes (a mate, then its solve) is one refresh

var backend_url := ""
var api_key := ""
var _main: Node
var _root_part_id := ""
var _tree: Array = [] ## top-level rows: [{id, name, resolved_part_id, children: Array|null, expanded: bool}, ...]
var _stale := true
var _busy := false
var _refresh_token := 0 ## bumped by every _refresh_root(), so a slower earlier fetch can't overwrite a newer one (mark_stale() + _on_opened() can both fire)
var _part_names: Dictionary = {} ## resolved_part_id -> the Part's own name (GET /parts/{id}), so rows read "Assy Test Peg" instead of "Occurrence d3c102e0"

var _status_label: Label
var _rows_box: VBoxContainer
var _selected: Array = [] ## V-7: the path of the selected row (the occurrence ids from the root; [] = the root row) ...
var _has_selected := false ## ... valid only while this is true
var _constraint: Dictionary = {} ## Part id -> {occurrence id: {status, dof}} from GET /parts/{id}/constraint-status
var _row_controls: Dictionary = {} ## path key -> the row's Control, for scrolling a selection into view
var _bar: Control ## the bottom action bar (never scrolls away)
var _bar_buttons: HBoxContainer
var _bar_hint: Label
var _refresh_timer: SceneTreeTimer = null
var _levels_token := 0
var _rename_keyboard_row: Dictionary = {}

const INDENT_PX := 24.0
const DELETE_CONFIRM_MS := 4000 ## how long a first press on Delete waits for its second

var _delete_armed := "" ## the occurrence whose Delete has been pressed once
var _delete_armed_until_ms := 0
var _delete_used := 0 ## how many times the owner Part of a nested row is placed (read when Delete was armed): more than one warns that every placement changes
var _delete_mates := 0 ## how many Mates deleting it would take with it (read when it was armed)


func setup_tree(left: XRController3D, right: XRController3D, camera: XRCamera3D, main: Node) -> void:
	_main = main
	if main != null and main.get("room_manager") != null:
		main.room_manager.rooms_changed.connect(_on_rooms_changed) # a row's Room button reads Close while its room is open
	if main != null and main.get("_mates_tool") != null:
		main._mates_tool.mates_changed.connect(request_refresh) # V-7: live, without losing what is open
		main._mates_tool.document_changed.connect(request_refresh)
	for hand_name in ["LeftController", "RightController"]:
		var hand = left if hand_name == "LeftController" else right
		if hand != null and hand.has_signal("selection_changed"):
			hand.selection_changed.connect(_on_world_selection)
	panel_title = "Assembly Tree"
	panel_size = Vector2(0.28, 0.42)
	viewport_size = Vector2i(480, 740)
	open_distance = 0.55
	open_lateral_offset = -0.22
	super.setup(left, right, camera)


func configure_backend(url: String, key: String) -> void:
	backend_url = url
	api_key = key


func mark_stale() -> void:
	## Called by main.gd whenever the loaded assembly changes (a new file
	## opened, a component added) - see that script's own _show_model().
	## Doesn't refetch immediately: only pays the network cost if/when the
	## tree is actually being looked at, per this window's own docstring
	## above on why it's a lazy client to GET .../occurrences rather than
	## an eager assembly-mesh JSON fetch.
	_stale = true
	_tree = []
	_has_selected = false
	_selected = []
	_constraint.clear()
	if is_open():
		_refresh_root()


func _on_opened() -> void:
	if _stale:
		_refresh_root()
	elif _stale_levels:
		_refresh_levels()
	_rebuild_bar()


func _refresh_root() -> void:
	_refresh_token += 1
	var token := _refresh_token
	_root_part_id = _main.current_root_part_id() if _main else ""
	if _root_part_id == "":
		_set_status("No assembly loaded yet.")
		return
	_set_status("Loading...")
	var result := await _list_occurrences(_root_part_id)
	if token != _refresh_token:
		return # a newer refresh started while this one was in flight
	if not result["ok"]:
		_set_status("Couldn't load the assembly tree: %s" % result["error"])
		return
	var occurrence_rows := _occurrences_to_rows(result["json"])
	# The root Part itself is the tree's top row (its placed Occurrences are its
	# children), so a part opened on its own, or an assembly's own root
	# content, is visible too — not only what was added onto it.
	var old_children: Array = (_tree[0]["children"] as Array) if not _tree.is_empty() and _tree[0].get("children") != null else []
	_tree = [{
		"id": "",
		"name": _part_names.get(_root_part_id, "Assembly"),
		"base_name": _part_names.get(_root_part_id, "Assembly"),
		"override": false,
		"named": true,
		"resolved_part_id": _root_part_id,
		"children": Model.merge_children(old_children, occurrence_rows), # (B4: a refresh keeps what was open)
		"expanded": true,
		"fixed": false, "backend_hidden": false, "suppressed": false, "missing": false,
		"path": [],
		"status": "",
	}]
	_stale = false
	_set_status("" if not occurrence_rows.is_empty() else "This assembly has no placed occurrences.")
	_rebuild_rows()
	await _apply_part_names(_tree)
	# mark_stale() empties _tree and starts a newer refresh while this one is awaiting: stop, the newer one fills it.
	if token != _refresh_token or _tree.is_empty():
		return
	await _load_status(_root_part_id)
	if token != _refresh_token or _tree.is_empty():
		return
	_apply_status(_tree[0]["children"], _root_part_id)
	_rebuild_rows()


func _apply_part_names(rows: Array) -> void:
	## Fills in real Part names (one cached GET /parts/{id} per distinct Part):
	## an Occurrence with no name_override would otherwise only ever read as
	## "Occurrence <uuid prefix>", which says nothing about which part it is.
	var token := _refresh_token
	var changed := false
	for row in rows:
		var part_id: String = row["resolved_part_id"]
		if part_id != "" and (not row.get("named", false) or row["id"] == ""):
			if not _part_names.has(part_id):
				var fetched := await _get_json("/parts/%s" % part_id)
				if token != _refresh_token:
					return
				if fetched["ok"] and fetched["json"] is Dictionary:
					_part_names[part_id] = str(fetched["json"].get("name", ""))
				else:
					_part_names[part_id] = ""
			var part_name: String = _part_names[part_id]
			if part_name != "":
				if row["id"] == "" or not bool(row.get("override", false)):
					row["base_name"] = part_name
					row["name"] = part_name
				row["named"] = true
				changed = true
		if row["children"] != null:
			await _apply_part_names(row["children"])
			if token != _refresh_token:
				return
	Model.apply_instance_names(rows) # ("Bolt <1>", "Bolt <2>": a Part placed twice under one parent)
	if changed:
		_rebuild_rows()


static func _occurrences_to_rows(occurrences: Array, parent_path: Array = []) -> Array:
	## Pure (no network): OccurrenceResponse-shaped dicts -> this window's own row shape (scripts/tree/occurrence_tree_model.gd). Kept under this name for
	## tests/assembly_tree_window.gd and the design table's tree, which subclasses this window.
	return Model.rows_from_occurrences(occurrences, parent_path)


static func _row_label(occ: Dictionary) -> String:
	var override_name = occ.get("name_override")
	if override_name != null and str(override_name) != "":
		return str(override_name)
	var occ_id: String = str(occ.get("id", ""))
	return "Occurrence %s" % occ_id.substr(0, 8)


func _expand_row(row: Dictionary) -> void:
	if row["resolved_part_id"] == "" or _busy:
		return
	if row["children"] != null: # already fetched: just toggle
		row["expanded"] = not row["expanded"]
		_rebuild_rows()
		return
	_busy = true
	var result := await _list_occurrences(row["resolved_part_id"])
	_busy = false
	row["children"] = _occurrences_to_rows(result["json"], row.get("path", [])) if result["ok"] else []
	row["expanded"] = true
	if not result["ok"]:
		_set_status("Couldn't load children: %s" % result["error"])
	_rebuild_rows()
	await _apply_part_names(row["children"])
	await _load_status(row["resolved_part_id"])
	_apply_status(row["children"], row["resolved_part_id"])
	_rebuild_rows()


func _load_status(part_id: String) -> void:
	## One GET /parts/{id}/constraint-status per level: the state icon's lock / open lock / warning. A failure leaves the rows on the `fixed` flag.
	if part_id == "":
		return
	var result := await _get_json("/parts/%s/constraint-status" % part_id)
	if result["ok"] and result["json"] is Dictionary:
		_constraint[part_id] = result["json"]


func _apply_status(rows: Array, part_id: String) -> void:
	var by_occ: Dictionary = _constraint.get(part_id, {})
	for row in rows:
		var entry = by_occ.get(str(row["id"]))
		row["status"] = str(entry.get("status", "")) if entry is Dictionary else ""
		row["dof"] = int(entry.get("dof", -1)) if entry is Dictionary else -1


func _on_row_selected(row: Dictionary) -> void:
	## Tree -> world: the row's part (or its whole sub-assembly, or the whole assembly for the root row) is selected in the world and pulses; pressing the
	## selected row again clears it. A row with nothing on screen says so.
	if _main == null:
		return
	var path: Array = row.get("path", [])
	var result: Dictionary = _main.select_tree_row(path, str(row.get("name", "")))
	match str(result.get("kind", "none")):
		"none":
			_set_status("Nothing of %s is on screen (hidden, suppressed, or it has no body of its own)." % str(row.get("name", "that")))
			_selected = path
			_has_selected = true
		"cleared":
			_has_selected = false
			_selected = []
			_set_status("")
		"group":
			_selected = path
			_has_selected = true
			_set_status("Selected %s (%d parts)." % [str(row.get("name", "")), int(result.get("count", 0))])
		_:
			_selected = path
			_has_selected = true
			_set_status("")
	_rebuild_rows()


func _on_world_selection(node: Node3D, level: Dictionary) -> void:
	## World -> tree: the laser (or a tree press) selected something. Expands the rows above it, marks its row and scrolls it into view.
	if node == null:
		if _has_selected:
			_has_selected = false
			_selected = []
			call_deferred("_rebuild_rows")
		return
	var path: Array = (level["prefix"] as Array) if level.has("prefix") else (node.get_meta("group_path", []) as Array)
	if path.is_empty() and not level.has("prefix"):
		var occ := str(node.get_meta("occurrence_id", ""))
		if occ == "":
			return # (a root's own body: no row of its own)
		path = [occ]
	if _has_selected and _selected == path:
		return # (the tree's own press: already shown)
	_selected = path
	_has_selected = true
	if is_open():
		_reveal(path)


func _reveal(path: Array) -> void:
	## Expands every fetched-or-fetchable row above `path` (a level at a time), then redraws with the row marked and in view.
	if _tree.is_empty():
		return
	for ancestor in Model.ancestors_paths(path):
		var row := Model.find_row(_tree, ancestor)
		if row.is_empty():
			break
		if row["children"] == null:
			await _expand_row(row)
		elif not bool(row["expanded"]):
			row["expanded"] = true
	_rebuild_rows()
	await get_tree().process_frame
	var ctrl = _row_controls.get(Model.path_key(path))
	if ctrl != null and is_instance_valid(ctrl) and scroll_target != null:
		scroll_target.ensure_control_visible(ctrl)


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)

	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(func() -> void:
		_stale = true
		_refresh_root()
	)
	box.add_child(refresh)

	var rows_scroll := ScrollContainer.new()
	rows_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(rows_scroll)
	scroll_target = rows_scroll # right thumbstick scrolls the rows while the laser is on the window
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_scroll.add_child(_rows_box)

	if _uses_action_bar():
		_bar = VBoxContainer.new()
		_bar.add_theme_constant_override("separation", 4)
		_bar_hint = Label.new()
		_bar_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_bar_hint.theme_type_variation = &"LabelDim"
		_bar.add_child(_bar_hint)
		_bar_buttons = HBoxContainer.new()
		_bar_buttons.add_theme_constant_override("separation", 4)
		_bar.add_child(_bar_buttons)
		box.add_child(_bar) # (a fixed bar at the bottom: it never scrolls away and the rows don't jump)

	return box


func _uses_action_bar() -> bool:
	## The world tree has the bottom action bar; the design table's PARTS tab keeps its own inline Table / Bring buttons until phase T2 moves it onto the bar.
	return true


func _rebuild_rows() -> void:
	if _rows_box == null:
		return
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	_row_controls.clear()
	_add_rows(_tree, 0, "")
	if _tree.is_empty():
		var none := Label.new()
		none.text = "Nothing to show."
		_rows_box.add_child(none)
	_rebuild_bar()


func _add_rows(rows: Array, depth: int, parent_part_id: String) -> void:
	for row in rows:
		row["parent_part_id"] = parent_part_id # the Part that holds this occurrence: how a room finds the world's copy
		var is_expandable: bool = row["resolved_part_id"] != ""
		var path: Array = row.get("path", [])
		var selected := _has_selected and _selected == path
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		line.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(depth * INDENT_PX, 0)
		line.add_child(spacer)
		if is_expandable:
			var arrow := Button.new()
			arrow.icon = UiIcons.texture("back", 24)
			arrow.rotation_degrees = 0.0
			arrow.text = "v" if row["expanded"] else ">" # (a text expander still: the drawn icon only marks the state, below)
			arrow.icon = null
			arrow.custom_minimum_size = Vector2(44, ROW_HEIGHT)
			arrow.pressed.connect(_expand_row.bind(row))
			line.add_child(arrow)
		else:
			var pad := Control.new()
			pad.custom_minimum_size = Vector2(44, 0)
			line.add_child(pad)
		var name_button := Button.new()
		name_button.toggle_mode = true
		name_button.set_pressed_no_signal(selected)
		name_button.theme_type_variation = &"ButtonRail"
		name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var icon_name := Model.state_icon(row)
		if icon_name != "":
			name_button.icon = UiIcons.texture(icon_name, 28)
		name_button.text = _row_text(row)
		name_button.clip_text = true
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		if bool(row.get("missing", false)):
			name_button.add_theme_color_override("font_color", tokens.warn) # amber: the file is missing
		if bool(row.get("suppressed", false)) or _row_view_hidden(row):
			name_button.modulate = Color(1, 1, 1, 0.5) # dimmed: suppressed, or hidden in the view (view-only, never saved)
		name_button.pressed.connect(_on_row_selected.bind(row))
		line.add_child(name_button)
		_row_controls[Model.path_key(path)] = line
		_add_row_actions(line, row, is_expandable)
		_rows_box.add_child(line)
		if is_expandable and row["expanded"] and row["children"] != null:
			_add_rows(row["children"], depth + 1, row["resolved_part_id"])


func _row_text(row: Dictionary) -> String:
	var hint := Model.state_hint(row, int(row.get("dof", -1)))
	var text := str(row["name"])
	if bool(row.get("missing", false)):
		text = "missing file: %s" % text
	elif _row_view_hidden(row):
		text += "  · hidden"
	if hint != "" and not bool(row.get("missing", false)):
		text += "  · %s" % hint
	return text


func _row_view_hidden(row: Dictionary) -> bool:
	return _main != null and _main.has_method("tree_row_hidden") and not bool(row.get("missing", false)) and _main.tree_row_hidden(row.get("path", []))


static func room_action(row: Dictionary, manager) -> Dictionary:
	## What a row's Room button does, or {} when it has none: not on the root row (that is the world itself) nor on a row with nothing behind it.
	## {text, part_id, label, parent_part_id, occurrence_id}; the text says Close room while that Part's room is open or being opened.
	var part_id := str(row.get("resolved_part_id", ""))
	if str(row.get("id", "")) == "" or part_id == "" or manager == null:
		return {}
	return {
		"text": "Cancel" if manager.has_method("is_placing_for") and manager.is_placing_for(part_id) else ("Close room" if manager.is_open_for(part_id) else "Room"),
		"part_id": part_id,
		"label": str(row.get("name", "")),
		"parent_part_id": str(row.get("parent_part_id", "")),
		"occurrence_id": str(row["id"]),
	}


func _add_row_actions(_line: HBoxContainer, _row: Dictionary, _is_expandable: bool) -> void:
	## A subclass adds its own inline buttons to a row here (the design table's tree: "Table" and "Bring"). The world tree has none: its actions are in the
	## bottom bar (_rebuild_bar), which acts on the selected row.
	pass


# --- the bottom action bar ---------------------------------------------------------------------------------------------

func _selected_row() -> Dictionary:
	return Model.find_row(_tree, _selected) if _has_selected and not _tree.is_empty() else {}


func _rebuild_bar() -> void:
	if _bar_buttons == null:
		return
	for child in _bar_buttons.get_children():
		_bar_buttons.remove_child(child)
		child.queue_free()
	var row := _selected_row()
	if row.is_empty():
		_bar_hint.text = "Select a row to Fix, Hide, Isolate, Rename or Delete it."
		return
	var manager = _main.get("room_manager") if _main != null else null
	var room := room_action(row, manager)
	var nodes: Array = _main.tree_row_nodes(row.get("path", [])) if _main != null and _main.has_method("tree_row_nodes") else []
	var ctx := {"has_nodes": not nodes.is_empty(), "hidden": _main != null and _main.has_method("tree_row_hidden") and _main.tree_row_hidden(row.get("path", [])),
		"room_text": str(room.get("text", ""))}
	var greyed: PackedStringArray = []
	for action in Model.actions_for(row, ctx):
		var b := Button.new()
		b.text = _bar_label(action, row)
		b.custom_minimum_size = Vector2(0, ROW_HEIGHT * 0.9)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", tokens.font_small)
		b.disabled = not bool(action["enabled"])
		if str(action["id"]) == "delete":
			b.theme_type_variation = &"ButtonDanger"
		if b.disabled:
			greyed.append("%s: %s" % [action["label"], action["why"]])
		b.pressed.connect(_on_bar_action.bind(str(action["id"]), row, room))
		_bar_buttons.add_child(b)
	_bar_hint.text = "%s%s" % [str(row["name"]), ("  ·  " + "; ".join(greyed)) if not greyed.is_empty() else ""]


func _bar_label(action: Dictionary, row: Dictionary) -> String:
	if str(action["id"]) != "delete":
		return str(action["label"])
	var occ := str(row.get("id", ""))
	var armed := _delete_armed == occ and Time.get_ticks_msec() < _delete_armed_until_ms
	return delete_label(armed, _delete_mates)


func _on_bar_action(action_id: String, row: Dictionary, room: Dictionary) -> void:
	var owner := str(row.get("parent_part_id", ""))
	var occ := str(row.get("id", ""))
	var label := str(row.get("name", "the part"))
	var path: Array = row.get("path", [])
	match action_id:
		"fix":
			var mates = _main.get("_mates_tool")
			if mates != null and await mates.toggle_fixed_occurrence(owner, occ, label):
				row["fixed"] = mates.group_fixed(owner, occ)
				_rebuild_rows()
				request_refresh()
		"hide":
			_main.set_tree_row_visible(path, _main.tree_row_hidden(path), label)
			_rebuild_rows()
		"isolate":
			_main.isolate_tree_row(path, label)
			_rebuild_rows()
		"rename":
			_rename(row)
		"room":
			if not room.is_empty() and _main.get("room_manager") != null:
				_main.room_manager.toggle_room(room["part_id"], room["label"], room["parent_part_id"], room["occurrence_id"])
		"delete":
			_on_delete_pressed(row)


func _rename(row: Dictionary) -> void:
	var owner := str(row.get("parent_part_id", ""))
	var occ := str(row.get("id", ""))
	if owner == "" or occ == "" or _main == null:
		return
	var previous := str(row.get("base_name", "")) if bool(row.get("override", false)) else ""
	_main.open_keyboard_for(str(row.get("name", "")), func(text: String) -> void:
		await _apply_rename(row, owner, occ, text.strip_edges(), previous),
		{"mode": "full", "title": "Rename %s" % str(row.get("name", "")), "confirm_label": "Rename"})


func _apply_rename(row: Dictionary, owner: String, occ: String, text: String, previous: String) -> void:
	if text == "" or text == str(row.get("name", "")):
		return
	if not await _set_name_override(owner, occ, text):
		return
	row["base_name"] = text
	row["name"] = text
	row["override"] = true
	row["named"] = true
	var stack = _main.get("command_stack")
	if stack != null:
		stack.push("rename %s" % text,
			func() -> void:
				if await _set_name_override(owner, occ, previous):
					request_refresh(),
			func() -> void:
				if await _set_name_override(owner, occ, text):
					request_refresh(),
			true)
	Model.apply_instance_names(_siblings_of(row))
	_rebuild_rows()


func _set_name_override(owner: String, occ: String, text: String) -> bool:
	var result := await _request_json(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [owner, occ], {"name_override": text})
	if not result["ok"]:
		_set_status("Couldn't rename: %s" % result["error"])
	return result["ok"]


func _siblings_of(row: Dictionary) -> Array:
	var path: Array = row.get("path", [])
	if path.size() <= 1:
		return _tree[0]["children"] if not _tree.is_empty() and _tree[0].get("children") != null else []
	var parent := Model.find_row(_tree, path.slice(0, path.size() - 1))
	return parent.get("children", []) if not parent.is_empty() and parent.get("children") != null else []


# --- keeping the tree current without losing your place (B4) -------------------------------------------------------------

var _stale_levels := false


func request_refresh() -> void:
	## A mate, a fix, a move, a delete or a room edit changed the assembly: re-read the open levels in place (what is expanded and what is selected stay),
	## once, shortly after the last change.
	if _tree.is_empty() or not is_inside_tree():
		return
	if not is_open():
		_stale_levels = true
		return
	if _refresh_timer != null:
		return
	_refresh_timer = get_tree().create_timer(REFRESH_DELAY_S)
	_refresh_timer.timeout.connect(func() -> void:
		_refresh_timer = null
		_refresh_levels())


func _on_rooms_changed() -> void:
	_rebuild_rows()
	request_refresh()


func _refresh_levels() -> void:
	if _tree.is_empty() or _root_part_id == "":
		return
	_stale_levels = false
	_levels_token += 1
	var token := _levels_token
	await _refresh_row_level(_tree[0], token)
	if token != _levels_token:
		return
	_rebuild_rows()


func _refresh_row_level(row: Dictionary, token: int) -> void:
	## Re-reads the children of `row` (and of every expanded child below it), merging them into what is there.
	if row.get("children") == null or str(row["resolved_part_id"]) == "":
		return
	var part_id := str(row["resolved_part_id"])
	var result := await _list_occurrences(part_id)
	if token != _levels_token or not result["ok"]:
		return
	row["children"] = Model.merge_children(row["children"], _occurrences_to_rows(result["json"], row.get("path", [])))
	await _load_status(part_id)
	if token != _levels_token:
		return
	await _apply_part_names(row["children"])
	_apply_status(row["children"], part_id)
	for child in row["children"]:
		if bool(child.get("expanded", false)):
			await _refresh_row_level(child, token)
			if token != _levels_token:
				return


static func delete_label(armed: bool, mates: int) -> String:
	## Delete asks twice: the first press turns the button into "Sure?" (naming the Mates that would go with the part), the second does it.
	if not armed:
		return "Delete"
	return "Sure?" if mates == 0 else "Sure? (%d mate%s)" % [mates, "" if mates == 1 else "s"]


func _on_delete_pressed(row: Dictionary) -> void:
	var occ := str(row.get("id", ""))
	var owner := str(row.get("parent_part_id", ""))
	if occ == "" or owner == "" or _main == null or _main.get("room_manager") == null:
		return
	var now := Time.get_ticks_msec()
	if _delete_armed == occ and now < _delete_armed_until_ms:
		_delete_armed = ""
		_delete_mates = 0
		_delete_used = 0
		await _main.room_manager.delete_occurrence(owner, occ, str(row.get("name", "that part")))
		_has_selected = false
		_selected = []
		request_refresh()
		_rebuild_rows()
		return
	_delete_armed = occ
	_delete_armed_until_ms = now + DELETE_CONFIRM_MS
	_delete_mates = 0
	_delete_used = 0
	_rebuild_rows()
	var e = _main.room_manager.edit_api()
	if e != null:
		_delete_mates = await e.mates_naming(owner, occ)
		if Model.kind_of(row) == Model.KIND_NESTED:
			_delete_used = await e.instance_count(_root_part_id, owner) # B3: a nested delete edits the sub-assembly's Part, so every placement of it
		_rebuild_rows()
		var warning := Model.delete_warning(row, _delete_used)
		if warning != "" and _bar_hint != null:
			_bar_hint.text = "%s  ·  Delete %s" % [str(row.get("name", "")), warning]


func _list_occurrences(part_id: String) -> Dictionary:
	return await _get_json("/parts/%s/occurrences" % part_id)


func _get_json(path: String) -> Dictionary:
	return await _request_json(HTTPClient.METHOD_GET, path, null)


var request_hook := Callable() ## tests only: (method, path, body) -> {ok, json, error}, answered instead of the backend


func _request_json(method: int, path: String, body) -> Dictionary:
	if request_hook.is_valid():
		return await request_hook.call(method, path, body)
	## Same fresh-HTTPRequest-per-call pattern as appearance_tool.gd/mates_tool.gd's
	## own _api_request - see either for the docstring this mirrors.
	if backend_url.is_empty() or api_key.is_empty(): # the server was switched away while a fetch was still going
		return {"ok": false, "json": null, "error": "no backend configured"}
	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key, body != null)
	var err := req.request(backend_url + API_PREFIX + path, headers, method, JSON.stringify(body) if body != null else "")
	if err != OK:
		req.queue_free()
		return {"ok": false, "json": null, "error": "request failed to start (error %d)" % err}
	var result: Array = await req.request_completed
	req.queue_free()
	var result_code: int = result[0]
	var response_code: int = result[1]
	var raw: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "json": null, "error": "network error (result %d)" % result_code}
	var parsed = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	var ok: bool = response_code >= 200 and response_code < 300
	return {"ok": ok, "json": (parsed if ok else null), "error": ("" if ok else str(parsed))}
