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
const API_PREFIX := "/document"

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

const INDENT_PX := 24.0
const DELETE_CONFIRM_MS := 4000 ## how long a first press on Delete waits for its second

var _delete_armed := "" ## the occurrence whose Delete has been pressed once
var _delete_armed_until_ms := 0
var _delete_mates := 0 ## how many Mates deleting it would take with it (read when it was armed)


func setup_tree(left: XRController3D, right: XRController3D, camera: XRCamera3D, main: Node) -> void:
	_main = main
	if main != null and main.get("room_manager") != null:
		main.room_manager.rooms_changed.connect(_rebuild_rows) # a row's Room button reads Close while its room is open
	panel_title = "Assembly Tree"
	panel_size = Vector2(0.28, 0.34)
	viewport_size = Vector2i(480, 600)
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
	if is_open():
		_refresh_root()


func _on_opened() -> void:
	if _stale:
		_refresh_root()


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
	_tree = [{
		"id": "",
		"name": _part_names.get(_root_part_id, "Assembly"),
		"named": true,
		"resolved_part_id": _root_part_id,
		"children": occurrence_rows,
		"expanded": true,
	}]
	_stale = false
	_set_status("" if not occurrence_rows.is_empty() else "This assembly has no placed occurrences.")
	_rebuild_rows()
	await _apply_part_names(_tree)


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
				row["name"] = part_name
				row["named"] = true
				changed = true
		if row["children"] != null:
			await _apply_part_names(row["children"])
			if token != _refresh_token:
				return
	if changed:
		_rebuild_rows()


static func _occurrences_to_rows(occurrences: Array) -> Array:
	## Pure (no network): OccurrenceResponse-shaped dicts -> this window's own
	## row shape. Split out so tests/assembly_tree_window.gd can exercise it
	## directly against a synthetic response, same precedent as appearance_tool.gd's
	## _hex_to_color()/mates_tool.gd's build_create_payload().
	var rows: Array = []
	for occ in occurrences:
		var resolved: String = str(occ.get("resolved_part_id", ""))
		rows.append({
			"id": str(occ.get("id", "")),
			"name": _row_label(occ),
			"named": occ.get("name_override") != null and str(occ.get("name_override")) != "", # false = still the "Occurrence <id>" placeholder; _apply_part_names() replaces it with the Part's own name
			"resolved_part_id": resolved,
			"children": null, # not fetched yet - see _expand_row()
			"expanded": false,
		})
	return rows


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
	row["children"] = _occurrences_to_rows(result["json"]) if result["ok"] else []
	row["expanded"] = true
	if not result["ok"]:
		_set_status("Couldn't load children: %s" % result["error"])
	_rebuild_rows()
	await _apply_part_names(row["children"])


func _on_row_selected(occurrence_id: String, is_expandable: bool) -> void:
	if _main == null:
		return
	var found: bool = _main.select_part_by_occurrence_id(occurrence_id)
	if not found:
		if is_expandable:
			_set_status("That's a sub-assembly - expand it and select one of its own parts.")
		else:
			_set_status("Not shown in the current view (hidden, or has no body of its own).")
	else:
		_set_status("")


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

	return box


func _rebuild_rows() -> void:
	if _rows_box == null:
		return
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	_add_rows(_tree, 0, "")
	if _tree.is_empty():
		var none := Label.new()
		none.text = "Nothing to show."
		_rows_box.add_child(none)


func _add_rows(rows: Array, depth: int, parent_part_id: String) -> void:
	for row in rows:
		row["parent_part_id"] = parent_part_id # the Part that holds this occurrence: how a room finds the world's copy
		var is_expandable: bool = row["resolved_part_id"] != ""
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(depth * INDENT_PX, 0)
		line.add_child(spacer)
		if is_expandable:
			var arrow := Button.new()
			arrow.text = "v" if row["expanded"] else ">"
			arrow.custom_minimum_size = Vector2(36, 0)
			arrow.pressed.connect(_expand_row.bind(row))
			line.add_child(arrow)
		else:
			var pad := Control.new()
			pad.custom_minimum_size = Vector2(36, 0)
			line.add_child(pad)
		var name_button := Button.new()
		name_button.text = row["name"]
		name_button.clip_text = true
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.pressed.connect(_on_row_selected.bind(row["id"], is_expandable))
		line.add_child(name_button)
		_add_row_actions(line, row, is_expandable)
		_rows_box.add_child(line)
		if is_expandable and row["expanded"] and row["children"] != null:
			_add_rows(row["children"], depth + 1, row["resolved_part_id"])


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


func _add_row_actions(line: HBoxContainer, row: Dictionary, _is_expandable: bool) -> void:
	## A subclass adds its own buttons to a row here (the design table's tree: "Table" and "Bring"). This one: Room, which opens the row's Part in an
	## Assembly Room (or closes its room).
	var manager = _main.get("room_manager") if _main != null else null
	var action := room_action(row, manager)
	if action.is_empty():
		return
	var button := Button.new()
	button.text = action["text"]
	button.custom_minimum_size = Vector2(0, 0)
	button.add_theme_font_size_override("font_size", tokens.font_small)
	button.pressed.connect(func() -> void:
		manager.toggle_room(action["part_id"], action["label"], action["parent_part_id"], action["occurrence_id"]))
	line.add_child(button)
	var occ := str(row["id"])
	var armed := _delete_armed == occ and Time.get_ticks_msec() < _delete_armed_until_ms
	var delete_button := Button.new()
	delete_button.text = delete_label(armed, _delete_mates)
	delete_button.custom_minimum_size = Vector2(0, 0)
	delete_button.add_theme_font_size_override("font_size", tokens.font_small)
	delete_button.pressed.connect(_on_delete_pressed.bind(row))
	line.add_child(delete_button)


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
		await _main.room_manager.delete_occurrence(owner, occ, str(row.get("name", "that part")))
		_stale = true
		_rebuild_rows()
		return
	_delete_armed = occ
	_delete_armed_until_ms = now + DELETE_CONFIRM_MS
	_delete_mates = 0
	_rebuild_rows()
	var e = _main.room_manager.edit_api()
	if e != null:
		_delete_mates = await e.mates_naming(owner, occ)
		_rebuild_rows()


func _list_occurrences(part_id: String) -> Dictionary:
	return await _get_json("/parts/%s/occurrences" % part_id)


func _get_json(path: String) -> Dictionary:
	## Same fresh-HTTPRequest-per-call pattern as appearance_tool.gd/mates_tool.gd's
	## own _api_request - see either for the docstring this mirrors.
	if backend_url.is_empty() or api_key.is_empty(): # the server was switched away while a fetch was still going
		return {"ok": false, "json": null, "error": "no backend configured"}
	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key)
	var err := req.request(backend_url + API_PREFIX + path, headers, HTTPClient.METHOD_GET)
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
