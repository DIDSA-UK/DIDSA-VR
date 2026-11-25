extends "res://scripts/diegetic_panel.gd"
## C6: the one occurrence tree component (docs/feature-tree-review-2026-11-11.md R1). Everything an occurrence tree does lives here: the rows (GET
## /parts/{id}/assembly-tree, or one level at a time from an older backend), the pooled row build (B6), the bottom action bar, Find (B7), the remembered open
## rows (B7), the room context (B8), refresh in place (B4) and selection both ways (V-7). A window gives it a SCOPE (occurrence_tree_scope.gd): what its root
## is, which world nodes a row stands for, and which actions the bar adds. occurrence_tree_model.gd stays the pure rules.
##
##   scripts/assembly_tree_window.gd             the World window (the tablet's Assembly Tree)
##   scripts/design_table/table_tree_window.gd   the design table's tree: its PARTS tab is this component with the Table scope (its BUILD tab is its own)
##
## It is a panel base class rather than a control put inside one: each tree is a window of its own (floating, docked at the table, beside a room's console in
## C7), and the windows' members stay where the tests and main.gd reach them.
##
## Only LEAF placed Occurrences (the ones with their own rendered geometry) have a body of their own: a sub-assembly row selects all of its parts as a group,
## and the root row the whole assembly (main.select_tree_row).

const RoomConsole := preload("res://scripts/room/room_console.gd")
const BackendSession := preload("res://scripts/backend_session.gd") ## the API key and this app's own X-Document-Session on every call
const Model := preload("res://scripts/tree/occurrence_tree_model.gd") ## rows, instance names, state icons, the bar's actions (pure, tests/occurrence_tree_model.gd)
const API_PREFIX := "/document"
const ROW_HEIGHT := 56.0
const REFRESH_DELAY_S := 0.4 ## live refresh: a burst of changes (a mate, then its solve) is one refresh
const Scope := preload("res://scripts/tree/occurrence_tree_scope.gd")

var scope: RefCounted = Scope.world() ## C6: what this tree is a tree of (occurrence_tree_scope.gd); a window sets it before setup_tree

var backend_url := ""
var api_key := ""
var _main: Node
var _root_part_id := ""
var _tree: Array = [] ## top-level rows: [{id, name, resolved_part_id, children: Array|null, expanded: bool}, ...]
var _stale := true
var _busy := false
var _mutation_seq := 0 ## bumped by every Fix / Float made here: a tree answer to a request sent before one describes the old document and is dropped (a fresh read follows)
var _refresh_token := 0 ## bumped by every _refresh_root(), so a slower earlier fetch can't overwrite a newer one (mark_stale() + _on_opened() can both fire)
var _part_names: Dictionary = {} ## resolved_part_id -> the Part's own name (GET /parts/{id}), so rows read "Assy Test Peg" instead of "Occurrence d3c102e0"

var _status_label: Label
var _rows_box: VBoxContainer
var _selected: Array = [] ## V-7: the path of the selected row (the occurrence ids from the root; [] = the root row) ...
var _has_selected := false ## ... valid only while this is true
const SET_COLOURS := [Color(0.35, 0.65, 1.0), Color(1.0, 0.55, 0.35), Color(0.45, 0.8, 0.5), Color(0.75, 0.5, 0.9), Color(0.95, 0.85, 0.3), Color(0.3, 0.8, 0.85)]
var _constraint: Dictionary = {} ## Part id -> {occurrence id: {status, dof}} from GET /parts/{id}/constraint-status
var _row_controls: Dictionary = {} ## path key -> the row's Control, for the rows now drawn (B6: only the visible ones exist)
var _bar: Control ## the bottom action bar (never scrolls away)
var _bar_buttons: HFlowContainer ## (wraps: the Table scope adds Table and Bring to the six)
var _bar_hint: Label
var _bar_row: Dictionary = {} ## the row the bar describes (B8: its hint is composed in _set_bar_hint)
var _bar_uses := "" ## "Placed N times..." for a row whose room is open
var _bar_greyed := ""
var _uses_cache: Dictionary = {} ## {key (row, Part, assembly), count, fresh}: the last "Placed N times" count; `fresh` ends with the next tree answer
var _uses_gen := 0 ## bumped by every document change (mark_stale, a tree answer): a count read before it is dropped
var _uses_read_gen := 0 ## the generation the last count was asked under
var _uses_reading := "" ## the key of the count being read now ("" = none): the same count is not asked for twice at once
var _refresh_timer: SceneTreeTimer = null
var _levels_token := 0
var _rename_keyboard_row: Dictionary = {}
var _resp: Dictionary = {} ## A5: the last GET /parts/{id}/assembly-tree answer (the structure, then the same with ?status=true merged in); {} when the per-level fallback is in use
var _endpoint_missing := false ## the backend answered 404 to the tree call (an older backend): read one level at a time instead
var _open_groups: Dictionary = {} ## group row key -> true (a "Bolt M4 x4" row that is open)
var _grouping_local := true ## the "fold repeats" switch when there is no main (tests); with a main it lives in app_settings.gd
var _fold_button: Button
var _find_button: Button
var _query := "" ## B7 (spec section 11): the words typed into Find ("" = no filter); only the view is narrowed, the open rows are never changed by it
var _query_key := "" ## the document key the query was typed under (a different one clears it)
var _status_unavailable := false ## the ?status=true call failed: the constraint states are not coming (the hint says so, not "still loading")
var _unknown_tokens: Array = [] ## the filter's unknown ":tokens" of the last draw, for the hint
var _query_box: Control
var _query_label: Label
var _query_hint: Label
var _doc_serial := 0 ## bumped when another document replaces this one (document_replaced(), or a different file key at mark_stale()): a reveal still fetching a level stops
var _mark_key := "" ## the document key at the last mark_stale()
var _doc_key := "" ## B7 (spec section 12): the document key the tree shown belongs to; "" = none whose open rows can be stored (a file-less session, or a tree still loading)
var _load_key := "" ## the document key when the load now in flight was requested
var _restore_due := false ## the first tree answer after a new document restores its remembered open rows (once)
var _open_touched := false ## the person opened or closed rows since the document's load began: a restore never overwrites that
var _toolbar: Control

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
		watch_mates(main._mates_tool)
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
	if _uses_tree_endpoint():
		# Find (B7: the popup keyboard, spec section 11) and the grouping switch (spec section 4) live in the window header, between the title and the close button.
		_find_button = add_header_button("", _open_find, false) # (an icon: the title still fits beside it)
		_find_button.icon = UiIcons.texture("search", 40)
		_find_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_find_button.expand_icon = false
		_find_button.tooltip_text = "Find in the tree"
		_header.move_child(_find_button, _header.get_child_count() - 2)
		# The grouping switch is saved with the other user settings.
		_fold_button = add_header_button("Fold x4", func() -> void: _set_grouping(not _grouping()), false)
		_fold_button.toggle_mode = true
		_fold_button.set_pressed_no_signal(_grouping())
		_header.move_child(_fold_button, _header.get_child_count() - 2)


func configure_backend(url: String, key: String) -> void:
	backend_url = url
	api_key = key
	_endpoint_missing = false
	_sync_fold_button()


func mark_stale() -> void:
	## Called by main.gd whenever the loaded assembly changes (a new file
	## opened, a component added) - see that script's own _show_model().
	## Doesn't refetch immediately: only pays the network cost if/when the
	## tree is actually being looked at, per this window's own docstring
	## above on why it's a lazy client to GET .../occurrences rather than
	## an eager assembly-mesh JSON fetch.
	_stale = true
	_uses_cache = {}
	_uses_gen += 1
	var doc_key := _document_key()
	if doc_key != _mark_key:
		_mark_key = doc_key
		_doc_serial += 1 # (another file: whatever was going on for the old one ends)
	_refresh_token += 1 # (an answer still in flight describes the document that is going: it is dropped, open or not)
	_status_unavailable = false
	if _query != "" and _document_key() != _query_key:
		_query = "" # (a different file: the old words would hide it)
	_doc_key = ""
	_restore_due = true # (the first answer for this document restores what it had open)
	_open_touched = false
	_restored_any = false
	_tree = []
	_has_selected = false
	_selected = []
	_resp = {}
	_endpoint_missing = false # (a new document: ask the tree call again)
	_sync_fold_button()
	_open_groups.clear()
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
	_load_key = _document_key()
	_status_unavailable = false
	_root_part_id = scope.root_part_id(_main)
	if _root_part_id == "":
		_set_status("No assembly loaded yet.")
		return
	_set_status("Loading...")
	if _uses_tree_endpoint():
		if await _load_endpoint(token):
			return
		if token != _refresh_token:
			return
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
					row["placeholder"] = false
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
	return "Component" # (the placeholder before a Part's name arrives is "Component N" with N the place among its siblings: occurrence_tree_model.gd)


var _expand_dropped := false ## the last _expand_row threw its answer away because the tree was read again meanwhile (a reveal asks once more)


func _expand_row(row: Dictionary) -> void:
	_expand_dropped = false
	if row["resolved_part_id"] == "" or _busy:
		return
	if row["children"] != null: # already fetched: just toggle
		row["expanded"] = not row["expanded"]
		_rebuild_rows()
		return
	_busy = true
	var serial := _doc_serial
	var token := _refresh_token
	var result := await _list_occurrences(row["resolved_part_id"])
	_busy = false
	if serial != _doc_serial:
		return # (another document replaced this one while the level was read: it is that document's rows now)
	if token != _refresh_token:
		_expand_dropped = true
		return # (the document was read again while this level was in flight, a mark_stale() or a refresh: the answer may predate it; children stay null and the next press asks again)
	var live := Model.find_row(_tree, row.get("path", [])) if not _tree.is_empty() else {}
	if live.is_empty() or str(live.get("resolved_part_id", "")) != str(row["resolved_part_id"]):
		return # (the row went while its level was read: a document switch, or a refresh that no longer has it)
	row = live # (a refresh that came meanwhile built the row again: the level belongs to the one shown)
	if not result["ok"]:
		_set_status("Couldn't load children: %s" % result["error"]) # (the row stays closed with its children not fetched: pressing it again asks again, and a reveal counts no change)
		return
	row["children"] = _occurrences_to_rows(result["json"], row.get("path", []))
	row["expanded"] = true
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
		row["rigid_set"] = str(entry["rigid_set"]) if entry is Dictionary and entry.get("rigid_set") is String else "" # M5: an older backend omits it
	for row in rows:
		row["set_note"] = Model.set_note(rows, row)
		row["set_slot"] = Model.set_colour_index(rows, str(row["rigid_set"]))


func _on_row_selected(row: Dictionary) -> void:
	## Tree -> world: the row's part (or its whole sub-assembly, or the whole assembly for the root row) is selected in the world and pulses; pressing the
	## selected row again clears it. A row with nothing on screen says so.
	if _main == null:
		return
	var path: Array = row.get("path", [])
	var result: Dictionary = scope.select_row(_main, path, str(row.get("name", "")))
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
	if _filtering():
		call_deferred("_rebuild_rows") # (a filter does not change the open rows: clearing it reveals the selection)
	elif is_open():
		_reveal(path)


func _reveal(path: Array, force: bool = false) -> void:
	## Expands every fetched-or-fetchable row above `path` (a level at a time), then redraws with the row marked and in view. A selection that needs nothing opened changes
	## nothing and stores nothing; `force` (the To selection button) counts as the person's choice even then.
	if _tree.is_empty():
		return
	var changed := force
	var serial := _doc_serial # (a document switch while a level is fetched ends this reveal: it must not touch the new document; a Refresh of the same one does not)
	if _endpoint_active():
		for key in Model.reveal_keys(_resp, path, _grouping()):
			if str(key).contains("#group:") and not _open_groups.has(key):
				_open_groups[key] = true # (the group a row sits in opens too; the ancestors open below. mark_stale() clears _open_groups, so a switch during the awaits drops these)
				changed = true
	for ancestor in Model.ancestors_paths(path):
		var row := Model.find_row(_tree, ancestor)
		if row.is_empty():
			break
		if row["children"] == null:
			await _expand_row(row)
			if serial != _doc_serial or _tree.is_empty():
				return
			row = Model.find_row(_tree, ancestor) # (a Refresh meanwhile built the rows again)
			if not row.is_empty() and row["children"] == null and _expand_dropped:
				await _expand_row(row) # (that Refresh made the answer stale and it was dropped: ask once more on the row now shown)
				if serial != _doc_serial or _tree.is_empty():
					return
				row = Model.find_row(_tree, ancestor)
			if row.is_empty():
				break
			if row["children"] != null: # (counted only when the expand really fetched: a busy window or a gone row opened nothing)
				changed = true
		elif not bool(row["expanded"]):
			row["expanded"] = true
			changed = true
	if changed:
		_open_touched = true
	_rebuild_rows()
	if changed:
		_store_open_keys()
	await get_tree().process_frame # (the list's height settles: the spacers stand in for the rows that are not drawn)
	_scroll_to_row(path)


func _scroll_to_row(path: Array) -> void:
	## Brings the row at `path` into view (the least scrolling that shows it, with a row of context) and draws it. Rows are a fixed height, so no control is needed to know where it is.
	if _rows_scroll == null:
		return
	var key := Model.path_key(path)
	var index := -1
	for i in _descs.size():
		var d: Dictionary = _descs[i]
		if str(d["kind"]) == "row" and Model.path_key((d["row"] as Dictionary).get("path", [])) == key:
			index = i
			break
	if index < 0:
		return
	var step := ROW_HEIGHT + ROW_SEPARATION
	var top := index * step
	var view := _view_height()
	var now := float(_rows_scroll.scroll_vertical)
	if top < now:
		_rows_scroll.scroll_vertical = int(maxf(0.0, top - step))
	elif top + ROW_HEIGHT > now + view:
		_rows_scroll.scroll_vertical = int(top + ROW_HEIGHT - view + step)
	_layout_pool()


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)

	_query_box = VBoxContainer.new() # B7: the words being searched for, under the title, with a clear button (shown only while there are some)
	_query_box.visible = false
	var query_line := HBoxContainer.new()
	query_line.add_theme_constant_override("separation", 6)
	_query_label = Label.new()
	_query_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query_label.clip_text = true
	query_line.add_child(_query_label)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(clear_query)
	query_line.add_child(clear)
	_query_box.add_child(query_line)
	_query_hint = Label.new()
	_query_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_query_hint.theme_type_variation = &"LabelDim"
	_query_box.add_child(_query_hint)
	box.add_child(_query_box)
	box.move_child(_query_box, 0)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 4)
	_toolbar = toolbar
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh.pressed.connect(func() -> void:
		_stale = true
		_refresh_root()
	)
	toolbar.add_child(refresh)
	var collapse := Button.new()
	collapse.text = "Collapse"
	collapse.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collapse.pressed.connect(collapse_all)
	toolbar.add_child(collapse)
	var to_selection := Button.new()
	to_selection.text = "To selection"
	to_selection.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	to_selection.pressed.connect(expand_to_selection)
	toolbar.add_child(to_selection)
	box.add_child(toolbar)

	var rows_scroll := ScrollContainer.new()
	rows_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(rows_scroll)
	_rows_scroll = rows_scroll
	scroll_target = rows_scroll # right thumbstick scrolls the rows while the laser is on the window
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_scroll.add_child(_rows_box)
	_top_spacer = Control.new() # B6: stand in for the rows above and below the drawn ones, so the scroll bar is the whole list's (rows are a fixed height)
	_top_spacer.visible = false
	_rows_box.add_child(_top_spacer)
	_bottom_spacer = Control.new()
	_bottom_spacer.visible = false
	_rows_box.add_child(_bottom_spacer)
	_none_label = Label.new()
	_none_label.text = "Nothing to show."
	_none_label.visible = false
	_rows_box.add_child(_none_label)
	rows_scroll.get_v_scroll_bar().value_changed.connect(_on_scrolled)
	rows_scroll.resized.connect(_on_list_resized)

	_bar = VBoxContainer.new() # (every tree has the bar since C6: the PARTS tab's inline Table / Bring moved into it)
	_bar.add_theme_constant_override("separation", 4)
	_bar_hint = Label.new()
	_bar_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bar_hint.theme_type_variation = &"LabelDim"
	_bar.add_child(_bar_hint)
	_bar_buttons = HFlowContainer.new()
	_bar_buttons.add_theme_constant_override("h_separation", 4)
	_bar_buttons.add_theme_constant_override("v_separation", 4)
	_bar.add_child(_bar_buttons)
	box.add_child(_bar) # (a fixed bar at the bottom: it never scrolls away and the rows don't jump)

	return box


var _theme_rev := 0 ## bumped by every apply_theme: a row control bound under an older one is bound again when it is on screen


func apply_theme() -> void:
	## B8.1: a theme change redraws the rows in place too (the room rail's colour and the state tints are the theme's, set when a row is bound). C6 (10.8 VR
	## leftover 2): only the rows on screen are bound again now; the pool's margin rows are bound again when a scroll brings them on (_rebind_stale_on_screen).
	super.apply_theme()
	_theme_rev += 1
	_rebind_stale_on_screen()


func _on_screen_range() -> Vector2i:
	## The indices into _descs of the rows the list shows now (first, last inclusive), from the scroll position: rows are a fixed height.
	var step := ROW_HEIGHT + ROW_SEPARATION
	var scroll := float(_rows_scroll.scroll_vertical) if _rows_scroll != null else 0.0
	return Vector2i(int(floor(scroll / step)), int(ceil((scroll + _view_height()) / step)) - 1)


func _rebind_stale_on_screen() -> int:
	## Binds again every pooled row control that is on screen and was bound under an older theme. Returns how many.
	if _rows_box == null:
		return 0
	var shown := _on_screen_range()
	var n := 0
	for i in _pool.size():
		var index := _first + i
		if index < shown.x or index > shown.y or index >= _descs.size():
			continue
		var line: HBoxContainer = _pool[i]
		if int(line.get_meta("theme_rev", -1)) != _theme_rev:
			_bind_line(line, index)
			n += 1
	return n


func _rebuild_rows() -> void:
	## B6: lists what the open rows are (_descs, cheap: no controls), then draws only the rows on screen (_layout_pool).
	if _rows_box == null:
		return
	_descs.clear()
	if _endpoint_active():
		_add_spec_rows()
	else:
		_add_rows(_tree, 0, "")
		_mark_fallback_room_rows()
	_none_label.visible = _tree.is_empty()
	_sync_query_row()
	_layout_pool(true)
	_rebuild_bar()


func row_count() -> int:
	## How many rows the open levels list (drawn or not).
	return _descs.size()


func pool_size() -> int:
	## How many row controls exist (the visible rows plus a margin, however long the list is).
	return _pool.size() + _spare.size()


func visible_lines() -> Array:
	## The row controls now showing, top to bottom.
	return _pool.duplicate()


func _add_rows(rows: Array, depth: int, parent_part_id: String) -> void:
	## The per-level fallback's rendering (an older backend without the tree call, and the design table's PARTS tab): a row opens when it has a Part.
	for row in rows:
		row["parent_part_id"] = parent_part_id # the Part that holds this occurrence: how a room finds the world's copy
		var is_expandable: bool = row["resolved_part_id"] != ""
		_add_row_line(row, depth, is_expandable)
		if is_expandable and row["expanded"] and row["children"] != null:
			_add_rows(row["children"], depth + 1, row["resolved_part_id"])


func _mark_fallback_room_rows() -> void:
	## B8.1: the per-level fallback has no tree answer, so the room context comes from the rows listed: a row that is a placement of an open room's Part, and every row
	## listed below it, is inside; a row with an inside row below it is the way to it; the rest is dimmed. C6 (10.8 VR leftover 1): below a CLOSED row (its children
	## fetched or not) the rows it has read and the world's own nodes say whether the room is there (_fallback_room_below); when neither can say, the row stays
	## dimmed and the bar says why (_row_detail).
	var room_parts := _room_part_ids()
	_room_index = {}
	if room_parts.is_empty():
		return # (none open, or a scope without room context: _room_part_ids)
	_room_index = scope.room_below_index(_main, _root_part_id, room_parts) # (once per rebuild: one walk over the world, not one per row)
	var everything := room_parts.has(_root_part_id) and _root_part_id != ""
	var inside_depth := -1
	for d in _descs:
		if str(d["kind"]) != "row":
			continue
		var depth := int(d["depth"])
		if inside_depth >= 0 and depth <= inside_depth:
			inside_depth = -1
		if inside_depth < 0 and room_parts.has(str((d["row"] as Dictionary).get("resolved_part_id", ""))):
			inside_depth = depth
			d["room_in"] = true
		else:
			d["room_in"] = everything or inside_depth >= 0
		d["room_way"] = false
	var seen: Dictionary = {} # (walking up the list: depth -> an inside row lies below the row now reached, within its own subtree)
	for i in range(_descs.size() - 1, -1, -1):
		var d: Dictionary = _descs[i]
		if str(d["kind"]) != "row":
			continue
		var depth := int(d["depth"])
		var lit: bool = bool(d["room_in"])
		var way: bool = not lit and bool(seen.get(depth, false))
		var row: Dictionary = d["row"]
		if not lit and not way and not _lists_below(row):
			way = _fallback_room_below(row, room_parts) == 1
		d["room_way"] = way
		d["room_dim"] = not lit and not way # (a row whose children are not fetched is dimmed too: the fallback cannot tell a leaf from an assembly until it is opened)
		for k in seen.keys():
			if int(k) >= depth:
				seen.erase(k) # (this row's own subtree is done)
		if lit or way:
			for k in range(depth):
				seen[k] = true


var _room_index: Dictionary = {} ## Scope.room_below_index for the rooms open at the last rebuild (the fallback only)


static func _lists_below(row: Dictionary) -> bool:
	## The fallback lists this row's children under it (it is open and they were read): what is below it is in the list.
	return bool(row.get("expanded", false)) and row.get("children") != null


func _fallback_room_below(row: Dictionary, room_parts: Array) -> int:
	## Whether a placement of an open room's Part lies below a row the list does not open: 1 yes, 0 no, -1 can't tell. The levels already read under it come first
	## (a closed row keeps what it read), then the world's own nodes (Scope.room_below_index, built once per rebuild: every leaf knows the Parts its path resolves to).
	var read := _read_room_below(row, room_parts)
	if read == 1:
		return 1
	if _room_index.get("parts", null) != room_parts:
		_room_index = scope.room_below_index(_main, _root_part_id, room_parts)
	var world: int = Scope.room_below_in(_room_index, row.get("path", []))
	return world if world != -1 else read


static func _read_room_below(row: Dictionary, room_parts: Array) -> int:
	## From the fetched rows only: 1 = a row below is a placement of a room's Part; 0 = every level below was read and none is; -1 = a level below was never read.
	var children = row.get("children")
	if children == null:
		return 0 if str(row.get("resolved_part_id", "")) == "" else -1 # (a missing file has nothing below it)
	var unread := false
	for child in children:
		if room_parts.has(str(child.get("resolved_part_id", ""))):
			return 1
		var below := _read_room_below(child, room_parts)
		if below == 1:
			return 1
		unread = unread or below == -1
	return -1 if unread else 0


func _room_unknown_below(row: Dictionary) -> bool:
	## The bar's "can't tell" (C6, 10.8 VR leftover 1): a fallback row outside the open rooms, not open, whose levels below were not read and that the world's nodes
	## cannot answer for either. The tree call's answer always knows (Model.room_way_keys).
	if _endpoint_active() or _tree.is_empty() or (row.get("path", []) as Array).is_empty() or _lists_below(row):
		return false
	var room_parts := _room_part_ids()
	if room_parts.is_empty():
		return false
	for d in _descs:
		if str(d["kind"]) == "row" and (d["row"] as Dictionary).get("path", []) == row.get("path", []):
			return bool(d.get("room_dim", false)) and _fallback_room_below(row, room_parts) == -1
	return false


func _add_row_line(row: Dictionary, depth: int, is_expandable: bool, bubble = null, show_arrow: bool = true) -> void:
	_descs.append({"kind": "row", "row": row, "depth": depth, "expandable": is_expandable and show_arrow, "bubble": bubble})


# --- the row pool (B6): fixed-height rows, only the visible ones (plus a margin) exist as controls, reused as the list scrolls ------------------------------------

const ROW_SEPARATION := 4
const RAIL_WIDTH := 5.0
const POOL_MARGIN := 3 ## rows kept above and below the visible ones
const DEFAULT_VIEW_H := 900.0 ## the list's height before it has been laid out
const LINE_BASE := 5 ## spacer, arrow, name, bubble, folder label: a line has nothing else (C6: the PARTS tab's inline Table / Bring moved into the bar)

var _descs: Array = [] ## what the open rows are, in order: {kind: "row" | "group" | "folder", ...}
var _pool: Array = [] ## the row controls in use, in display order; _pool[i] shows _descs[_first + i]
var _spare: Array = [] ## controls the list no longer needs (hidden, kept for when it grows again)
var _first := 0
var _top_spacer: Control
var _bottom_spacer: Control
var _rows_scroll: ScrollContainer ## the rows' own scroll box (scroll_target can point elsewhere: the design table's Build tab)
var _none_label: Label


func _make_line() -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", ROW_SEPARATION)
	line.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	var indent := Control.new()
	var rail := ColorRect.new() # B8: the thin bar a row inside an open room wears at the line's left edge
	rail.color = tokens.accent
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rail.visible = false
	rail.anchor_bottom = 1.0
	rail.offset_right = RAIL_WIDTH
	indent.add_child(rail)
	line.set_meta("rail", rail)
	line.add_child(indent) # 0: the indent
	var arrow := Button.new()
	arrow.custom_minimum_size = Vector2(44, ROW_HEIGHT)
	arrow.button_down.connect(_note_press.bind(line))
	arrow.pressed.connect(_on_line_arrow.bind(line))
	line.add_child(arrow) # 1
	var name_button := Button.new()
	name_button.theme_type_variation = &"ButtonRail"
	name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_button.clip_text = true
	name_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS # (a name too long even alone ends in "...", not mid-letter)
	name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	name_button.button_down.connect(_note_press.bind(line))
	name_button.pressed.connect(_on_line_name.bind(line))
	name_button.resized.connect(_on_line_resized.bind(line))
	line.add_child(name_button) # 2
	var bubble := Label.new()
	bubble.custom_minimum_size = Vector2(40, 0)
	bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bubble.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(bubble) # 3
	var folder := Label.new()
	folder.theme_type_variation = &"LabelDim"
	folder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(folder) # 4
	line.set_meta("bubble", bubble)
	line.set_meta("folder", folder)
	return line


func _view_height() -> float:
	var h := _rows_scroll.size.y if _rows_scroll != null else 0.0
	return h if h > 1.0 else DEFAULT_VIEW_H


func _layout_pool(force: bool = false) -> void:
	_layout_pool_rows(force)
	_rebind_stale_on_screen() # (C6: a row bound under an older theme that a scroll, a resize or a rebuild brings on screen is bound again)


func _layout_pool_rows(force: bool = false) -> void:
	## Draws the rows that are on screen: the pool is as long as the visible rows plus a margin, and each control is re-bound to the row now at its place.
	## A scroll of k rows re-binds k controls (the ones that left one end are moved to the other); `force` (a rebuild, a resize) re-binds them all.
	if _rows_box == null or _top_spacer == null:
		return
	var n := _descs.size()
	var step := ROW_HEIGHT + ROW_SEPARATION
	var need := mini(n, int(ceil(_view_height() / step)) + 1 + 2 * POOL_MARGIN)
	var scroll := _rows_scroll.scroll_vertical if _rows_scroll != null else 0
	var first := clampi(int(floor(scroll / step)) - POOL_MARGIN, 0, maxi(0, n - need))
	if need != _pool.size():
		force = true
	if not force and first == _first:
		return
	if force or absi(first - _first) >= need:
		while _pool.size() < need:
			var line: HBoxContainer
			if _spare.is_empty():
				line = _make_line()
				_rows_box.add_child(line)
			else:
				line = _spare.pop_back()
				line.visible = true
			_rows_box.move_child(line, _bottom_spacer.get_index())
			_pool.append(line)
		while _pool.size() > need:
			var gone: HBoxContainer = _pool.pop_back()
			_forget_line(gone)
			gone.set_meta("down_id", "") # (a press that went down on it is over: it holds no row)
			gone.visible = false
			_rows_box.move_child(gone, _rows_box.get_child_count() - 1)
			_spare.append(gone)
		for i in need:
			_bind_line(_pool[i], first + i)
	elif first > _first:
		for j in first - _first:
			var line: HBoxContainer = _pool.pop_front()
			_pool.append(line)
			_rows_box.move_child(line, _pool.size())
			_bind_line(line, first + need - (first - _first) + j)
	else:
		for j in _first - first:
			var line: HBoxContainer = _pool.pop_back()
			_pool.push_front(line)
			_rows_box.move_child(line, 1)
			_bind_line(line, _first - 1 - j)
	_first = first
	_top_spacer.visible = first > 0
	_top_spacer.custom_minimum_size.y = maxf(0.0, first * step - ROW_SEPARATION)
	var rest := n - first - need
	_bottom_spacer.visible = rest > 0
	_bottom_spacer.custom_minimum_size.y = maxf(0.0, rest * step - ROW_SEPARATION)


func _on_scrolled(_value: float) -> void:
	_layout_pool()


func _on_list_resized() -> void:
	_layout_pool()


func _forget_line(line: Control) -> void:
	var old := str(line.get_meta("key", ""))
	if old != "" and _row_controls.get(old) == line:
		_row_controls.erase(old)
	line.set_meta("key", "")
	line.set_meta("desc", {}) # (unbound)


func _bind_line(line: HBoxContainer, index: int) -> void:
	## Everything a row shows is set here, every time: a re-used control keeps nothing of the row it showed before (text, icon, tint, dimming, selection, bubble, hint).
	_forget_line(line)
	var d: Dictionary = _descs[index]
	line.set_meta("desc", d)
	line.set_meta("theme_rev", _theme_rev) # (C6: bound under the current theme; apply_theme re-binds only the rows on screen and the rest as they come on)
	var arrow: Button = line.get_child(1)
	var nb: Button = line.get_child(2)
	var folder: Label = line.get_meta("folder")
	var bubble_label: Label = line.get_meta("bubble")
	var is_folder := str(d["kind"]) == "folder"
	line.move_child(folder if is_folder else bubble_label, 3) # (a folder's count and health come after its label, as other rows wear their bubble after the name)
	line.move_child(bubble_label if is_folder else folder, 4)
	nb.remove_theme_color_override("font_color")
	nb.modulate = Color.WHITE
	line.modulate = Color(1, 1, 1, 0.5) if bool(d.get("room_dim", false)) else Color.WHITE # (B8: outside the open room)
	var rail: ColorRect = line.get_meta("rail")
	var way := bool(d.get("room_way", false)) # (B8.1: the way to a room below this row: a fainter rail)
	rail.visible = bool(d.get("room_in", false)) or way # (inside it)
	rail.color = Color(tokens.accent, 0.4 if way else 1.0) # (the current theme's accent, set on every bind: a theme change reaches the controls already built)
	nb.icon = null
	nb.tooltip_text = ""
	match str(d["kind"]):
		"folder":
			var srow: Dictionary = d["srow"]
			(line.get_child(0) as Control).custom_minimum_size.x = int(srow["depth"]) * INDENT_PX + 48
			arrow.visible = false
			nb.visible = false
			folder.visible = true
			folder.text = "%s (%d)" % [str(srow["label"]), int(srow["count"])]
			_bind_bubble(line, srow["bubble"])
		"group":
			var srow: Dictionary = d["srow"]
			(line.get_child(0) as Control).custom_minimum_size.x = int(srow["depth"]) * INDENT_PX
			_show_arrow(arrow, true, bool(srow["open"]), bool(d.get("inert", false)))
			folder.visible = false
			nb.visible = true
			nb.toggle_mode = false
			nb.set_pressed_no_signal(false)
			var icon_name := Model.state_icon_for(str(srow["state"]))
			if icon_name != "":
				nb.icon = UiIcons.texture(icon_name, 28)
			nb.text = str(srow["label"])
			var hint := Model.state_hint_short(str(srow["state"]))
			if hint != "":
				nb.text += "  · %s" % hint
			_tint_state(nb, {"state": srow["state"]})
			if bool(srow["suppressed"]) or bool(srow["hidden"]) or bool(d.get("dim", false)):
				nb.modulate = Color(1, 1, 1, 0.5)
			_bind_bubble(line, srow["bubble"])
		_:
			var row: Dictionary = d["row"]
			var path: Array = row.get("path", [])
			(line.get_child(0) as Control).custom_minimum_size.x = int(d["depth"]) * INDENT_PX
			_show_arrow(arrow, bool(d["expandable"]), bool(d.get("open", row["expanded"])), bool(d.get("inert", false)))
			folder.visible = false
			nb.visible = true
			nb.toggle_mode = true
			nb.set_pressed_no_signal(_has_selected and _selected == path)
			var icon_name := Model.state_icon(row)
			if icon_name != "":
				nb.icon = UiIcons.texture(icon_name, 28)
			nb.text = str(row["name"]) # (the extras are added by _fit_row_text, now if the button has been laid out, and again when it is resized)
			_tint_state(nb, row)
			if int(row.get("set_slot", -1)) >= 0 and Model.state_level(str(row.get("state", ""))) == "":
				nb.add_theme_color_override("font_color", SET_COLOURS[int(row["set_slot"]) % SET_COLOURS.size()]) # M5: one colour per rigid set (the bracket in the flat app)
			if bool(row.get("suppressed", false)) or _row_view_hidden(row) or bool(d.get("dim", false)):
				nb.modulate = Color(1, 1, 1, 0.5) # dimmed: suppressed, or hidden in the view (view-only, never saved); under a filter, a row listed only because a match is below it
			_bind_bubble(line, d["bubble"])
			var key := Model.path_key(path)
			line.set_meta("key", key)
			_row_controls[key] = line
			_fit_row_text(nb, row)


func _show_arrow(arrow: Button, expandable: bool, open: bool, inert: bool = false) -> void:
	## A row that cannot open keeps the arrow's width, invisible and inert (the names stay in line). While a filter is on every chevron is inert: shown dim, as the filter has them.
	arrow.visible = true
	arrow.text = ("v" if open else ">") if expandable else "" # (a text expander: the state icon is on the name)
	arrow.modulate = (Color(1, 1, 1, 0.4) if inert else Color.WHITE) if expandable else Color(1, 1, 1, 0)
	arrow.mouse_filter = Control.MOUSE_FILTER_STOP if expandable and not inert else Control.MOUSE_FILTER_IGNORE
	arrow.focus_mode = Control.FOCUS_ALL if expandable and not inert else Control.FOCUS_NONE


func _bind_bubble(line: HBoxContainer, bubble) -> void:
	## The one problem count a row wears (spec section 6): red for errors, amber for "near", dim for unsaved.
	var label: Label = line.get_meta("bubble")
	label.remove_theme_color_override("font_color")
	label.theme_type_variation = &""
	if not (bubble is Dictionary):
		label.visible = false
		return
	label.visible = true
	label.text = str(int(bubble["count"]))
	match str(bubble["level"]):
		"error":
			label.add_theme_color_override("font_color", tokens.danger)
		"warning":
			label.add_theme_color_override("font_color", tokens.warn)
		_:
			label.theme_type_variation = &"LabelDim"


static func _desc_id(d: Dictionary) -> String:
	## Which row a control shows, whatever it was re-bound since: an occurrence row's path, a group's or folder's key.
	if d.is_empty():
		return ""
	match str(d["kind"]):
		"row":
			return "r:" + Model.path_key((d["row"] as Dictionary).get("path", []))
		"group":
			return "g:" + str(d["srow"]["key"])
	return "f:" + str(d["srow"]["key"])


func _note_press(line: HBoxContainer) -> void:
	## A press is acted on when it is released; remember which row the control showed when it went down.
	line.set_meta("down_id", _desc_id(line.get_meta("desc", {})))


func _press_is_stale(line: HBoxContainer) -> bool:
	## True when the control shows another row than the one the press went down on (a scroll or a refresh moved the rows under the laser): the release must not act on the
	## new row, and a toggle button Godot has already flipped goes back to its row's real state. A re-bind to the same row (a status answer, a rename, a part name) is not
	## stale. The record ends here, on release; a press with no record (keyboard, programmatic) is taken as it is.
	var down := str(line.get_meta("down_id", ""))
	line.set_meta("down_id", "")
	var d: Dictionary = line.get_meta("desc", {})
	if down == "" or down == _desc_id(d):
		return false
	var nb: Button = line.get_child(2)
	if nb.toggle_mode:
		nb.set_pressed_no_signal(not d.is_empty() and str(d["kind"]) == "row" and _has_selected and _selected == (d["row"] as Dictionary).get("path", []))
	return true


func _on_line_arrow(line: HBoxContainer) -> void:
	var d: Dictionary = line.get_meta("desc", {})
	if d.is_empty() or _press_is_stale(line) or _filtering():
		return # (the chevrons are inert while a filter is on, spec section 11)
	_open_touched = true
	if str(d["kind"]) == "row":
		await _expand_row(d["row"])
	elif str(d["kind"]) == "group":
		_toggle_group(str(d["srow"]["key"]))
	_store_open_keys()


func _on_line_name(line: HBoxContainer) -> void:
	var d: Dictionary = line.get_meta("desc", {})
	if d.is_empty() or _press_is_stale(line):
		return
	if str(d["kind"]) == "row":
		_on_row_selected(d["row"])
	elif str(d["kind"]) == "group" and not _filtering():
		_open_touched = true
		_toggle_group(str(d["srow"]["key"])) # (a group's name opens it too: it is not a selection)
		_store_open_keys()


func _on_line_resized(line: HBoxContainer) -> void:
	var d: Dictionary = line.get_meta("desc", {})
	if not d.is_empty() and str(d["kind"]) == "row":
		_fit_row_text(line.get_child(2), d["row"])


func _toggle_group(key: String) -> void:
	if _open_groups.has(key):
		_open_groups.erase(key)
	else:
		_open_groups[key] = true
	_rebuild_rows()


func _tint_state(button: Button, row: Dictionary) -> void:
	## Red for an error state, amber for "near", from the spec's state slot; the per-level fallback only knows a missing file (amber, as before).
	if row.has("state"):
		match Model.state_level(str(row["state"])):
			"error":
				button.add_theme_color_override("font_color", tokens.danger)
			"warning":
				button.add_theme_color_override("font_color", tokens.warn)
	elif bool(row.get("missing", false)):
		button.add_theme_color_override("font_color", tokens.warn)


# --- B7: Find (spec section 11), Collapse, To selection, and the remembered open rows (spec section 12) ----------------------------------------------------------

var _match_count := 0
var _restored_any := false ## the document's remembered rows were applied to this tree (so a Save As carries them to the new file's entry)


func _filtering() -> bool:
	return _query != "" and _endpoint_active()


func current_query() -> String:
	return _query


func _open_find() -> void:
	if _main == null:
		return
	_main.open_keyboard_for(_query, func(text: String) -> void: set_query(text),
		{"mode": "full", "title": "Find in the tree (e.g. bolt :errors  :missing  :hidden  :unsaved)", "confirm_label": "Find"})


func set_query(text: String) -> void:
	## Narrows the tree to the rows that match (and what is above them): words match names, ":errors" and the other tokens match states (Model.filtered_rows). The open rows are
	## not changed. An empty text clears it.
	var words := " ".join(PackedStringArray(Model.query_words(text, true))) # (the model's own whitespace, the typed case kept: what the query row shows and the keyboard reopens with)
	if words == "":
		clear_query()
		return
	_query = words
	_query_key = _document_key()
	if _rows_scroll != null:
		_rows_scroll.scroll_vertical = 0
	_rebuild_rows()


func clear_query() -> void:
	## Back to the open rows as they were; the selected row, if any, is revealed (spec section 11).
	if _query == "":
		return
	_query = ""
	_unknown_tokens = []
	_rebuild_rows()
	if _has_selected and not _selected.is_empty() and not _tree.is_empty():
		await _reveal(_selected)


func _sync_query_row() -> void:
	if _query_box == null:
		return
	_query_box.visible = _query != ""
	if _query == "":
		return
	_query_label.text = "Find: %s" % _query
	var hints: PackedStringArray = []
	if not _filtering():
		hints.append("The filter applies once the tree has loaded.")
	else:
		hints.append("%d match%s." % [_match_count, "" if _match_count == 1 else "es"] if _match_count > 0 else "No matches.")
		for token in _unknown_tokens:
			hints.append("Unknown filter %s." % str(token))
		var words: Array = Model.query_words(_query)
		if (words.has(":errors") or words.has(":warnings")) and not bool(_resp.get("status_included", false)):
			hints.append("Constraint states are unavailable." if _status_unavailable or bool(_resp.get("status_failed", false)) else "Constraint states are still loading.")
		hints.append("Part and assembly names only: features are not searched.")
	_query_hint.text = " ".join(hints)


func collapse_all() -> void:
	## Every row closed (the root stays open); stored.
	if _tree.is_empty():
		return
	_open_touched = true
	_collapse_rows(_tree[0]["children"] as Array)
	_open_groups.clear()
	_rebuild_rows()
	_store_open_keys()


func _collapse_rows(rows: Array) -> void:
	for row in rows:
		row["expanded"] = false
		if row.get("children") != null:
			_collapse_rows(row["children"])


func expand_to_selection() -> void:
	## Opens what is above the selected row (spec section 8's reveal keys) and scrolls to it; stored.
	if _tree.is_empty():
		return
	_open_touched = true # (even when there is nothing to add: the person has chosen their rows)
	if not _has_selected or _selected.is_empty():
		_set_status("Nothing selected: pick a part first.")
		return
	await _reveal(_selected, true)


func _document_key() -> String:
	## The one place the remembered rows' key is decided: the document's file path, or "" when it has none (then nothing is stored or restored).
	if _main == null or not _main.has_method("tree_document_key"):
		return ""
	return str(_main.tree_document_key())


func _restore_open_rows(resp: Dictionary, rows: Array) -> void:
	## The first tree answer of a document: its remembered open rows (Model.restore_open_keys: the ones that still exist). Not applied when the person has already opened or
	## closed rows, or when the document is not the one the request was for. Does not move the selection or the camera.
	var key := _document_key()
	_doc_key = key
	_restored_any = false
	if key == "" or key != _load_key or _open_touched or not scope.remembers_rows:
		return # (C6: a scope that does not remember rows, the table's PARTS tab, neither restores nor stores: the World tree owns the document's entry)
	var stored = _main.tree_open_keys_for(key)
	if not (stored is Array):
		return
	var index := Model.index_rows(rows)
	for k in Model.restore_open_keys(resp, stored):
		if str(k).contains("#group:"):
			_open_groups[k] = true
		elif index.has(k):
			index[k]["expanded"] = true
		else:
			continue
		_restored_any = true


func _store_open_keys() -> void:
	## Writes the open rows of the document shown, only after the person changed them (never from a refresh or a load), in the spec's order and within its limit.
	if not scope.remembers_rows or _doc_key == "" or _doc_key != _document_key() or _tree.is_empty() or _resp.is_empty() or _main == null or not _main.has_method("set_tree_open_keys"):
		return
	_main.set_tree_open_keys(_doc_key, Model.restore_open_keys(_resp, _spec_open_keys()))


func note_document_changed(old_key: String) -> void:
	## The document got a new file key without being replaced (Save As): its remembered rows follow it. With the tree loaded and changed by the person, what is open now is
	## stored under the new file; otherwise (the tree stale, never opened, or untouched) the old file's entry is copied as it is.
	var key := _document_key()
	if key == "" or key == old_key:
		return
	_mark_key = key # (the same document under a new name: nothing in flight for it ends)
	if _query_key == old_key:
		_query_key = key # (the words typed are still for this document: the next mark_stale() must not clear them)
	if _load_key == old_key:
		_load_key = key # (a load in flight for the old file restores under the new one)
	if not _tree.is_empty() and not _resp.is_empty() and not _stale and _doc_key == old_key:
		_doc_key = key
		if _open_touched and scope.remembers_rows:
			_store_open_keys()
			return
	if scope.remembers_rows and _main != null and _main.has_method("copy_tree_open_keys"):
		_main.copy_tree_open_keys(old_key, key)


func document_replaced() -> void:
	## A different document is being loaded (not a re-read of the same one): the words typed for the old one are cleared, whatever the two files are called.
	_doc_serial += 1
	_query = ""
	_query_key = ""
	_sync_query_row()


# --- the tree call's rendering (A5): the spec's visible rows (Model.visible_rows), listed with the same kinds as above ---------------------------------------------

func _room_part_ids() -> Array:
	## The Parts whose rooms are open now (B8: the world tree dims every row outside them); none for a scope without room context (the table's PARTS tab).
	if not scope.room_context:
		return []
	var manager = _main.get("room_manager") if _main != null else null
	return manager.open_part_ids() if manager != null and manager.has_method("open_part_ids") else []


func _add_spec_rows() -> void:
	var filtering := _filtering()
	var room_parts := _room_part_ids()
	var inside: Dictionary = Model.room_keys(_resp, room_parts, _spec_open_set(), _grouping(), filtering) if not room_parts.is_empty() else {}
	var ways: Dictionary = Model.room_way_keys(_resp, room_parts, _grouping()) if not room_parts.is_empty() else {}
	var spec_rows: Array
	if filtering:
		var found := Model.filtered_rows(_resp, _query, _spec_open_keys(), _grouping(), _unsaved_part_ids())
		spec_rows = found["rows"]
		_unknown_tokens = found["unknown"]
		_match_count = spec_rows.filter(func(r): return bool(r["match"])).size()
	else:
		spec_rows = Model.visible_rows(_resp, _spec_open_keys(), _grouping(), _unsaved_part_ids())
		_unknown_tokens = []
	var index := Model.index_rows(_tree[0]["children"] as Array)
	var first_desc := _descs.size()
	for srow in spec_rows:
		var depth := int(srow["depth"])
		var dim: bool = filtering and not bool(srow["match"]) and str(srow["kind"]) != "root" # (listed only because a match is below it)
		match str(srow["kind"]):
			"root":
				_tree[0]["state"] = srow["state"]
				_add_row_line(_tree[0], 0, false, null)
			"group":
				_descs.append({"kind": "group", "srow": srow, "inert": filtering, "dim": dim})
			"mates_folder", "patterns_folder":
				_descs.append({"kind": "folder", "srow": srow}) # (their count and health; what is inside them is a later phase's, so the row is a label)
			"feature":
				pass # (features of a part are the design table's and a later phase's: not fetched here)
			_:
				var row: Dictionary = index.get(str(srow["key"]), {})
				if row.is_empty():
					continue
				row["state"] = srow["state"] # (drawn from the latest unsaved set, not the one the row was built with)
				var has_children := not (row["children"] as Array).is_empty()
				_add_row_line(row, depth, bool(srow["expandable"]) and has_children, srow["bubble"])
				if filtering:
					var d: Dictionary = _descs.back()
					d["open"] = srow["open"]
					d["inert"] = true
					d["dim"] = dim
	if not room_parts.is_empty():
		_mark_room_rows(first_desc, inside, ways)


func _mark_room_rows(first_desc: int, inside: Dictionary, ways: Dictionary) -> void:
	## B8: while a room is open every row outside it is dimmed ("room_dim") and the rows inside wear the rail ("room_in"). B8.1: a row or group outside it that has a
	## placement of the room's Part below it ("room_way": an ancestor, a closed group) is not dimmed and wears a fainter rail, so the way to the room shows.
	var everything := inside.has("")
	for i in range(first_desc, _descs.size()):
		var d: Dictionary = _descs[i]
		var key := ""
		match str(d["kind"]):
			"row":
				key = Model.path_key((d["row"] as Dictionary).get("path", []))
			"group":
				key = str(d["srow"]["key"])
			_:
				pass # (the Mates and Patterns folders belong to the assembly, not to a room)
		var in_room: bool = everything or (str(d["kind"]) != "folder" and key != "" and inside.has(key))
		var way: bool = not in_room and str(d["kind"]) != "folder" and ways.has(key) # ("" is the root row)
		d["room_in"] = in_room
		d["room_way"] = way
		d["room_dim"] = not in_room and not way


func _spec_open_set() -> Dictionary:
	var open := {} # (not `set`: that would shadow Object.set())
	for k in _spec_open_keys():
		open[k] = true
	return open


func _spec_open_keys() -> Array:
	## The open row keys the spec lists rows for: every expanded occurrence row (its key is its path), and every open group.
	var keys: Array = []
	_collect_open(_tree[0]["children"] as Array, keys)
	for k in _open_groups:
		keys.append(k)
	return keys


func _collect_open(rows: Array, keys: Array) -> void:
	for row in rows:
		if bool(row.get("expanded", false)):
			keys.append(Model.path_key(row["path"]))
		if row.get("children") != null:
			_collect_open(row["children"], keys)


func _unsaved_part_ids() -> Array:
	## Spec "unsaved" is client state. This client only knows the whole document is unsaved, so that marks the root Part (the root row), not every row.
	return [_root_part_id] if _main != null and bool(_main.get("document_dirty")) and _root_part_id != "" else []


func _grouping() -> bool:
	return _main.tree_grouping() if _main != null and _main.has_method("tree_grouping") else _grouping_local


func _set_grouping(on: bool) -> void:
	if _main != null and _main.has_method("set_tree_grouping"):
		_main.set_tree_grouping(on)
	_grouping_local = on
	if _fold_button != null:
		_fold_button.set_pressed_no_signal(on)
	_rebuild_rows()


func _uses_tree_endpoint() -> bool:
	## Every tree reads the whole hierarchy in one call (the PARTS tab too, since C6); an older backend without it is read one level at a time.
	return not _endpoint_missing


func _endpoint_active() -> bool:
	return not _resp.is_empty() and not _tree.is_empty()


func _load_endpoint(token: int) -> bool:
	## GET /parts/{id}/assembly-tree: the structure first (fast at any size), drawn at once, then the same call with ?status=true merged in (spec section 2).
	## True = handled (loaded, or an error shown); false = the backend has no such call (404): the caller falls back to one request per level.
	var base := "/parts/%s/assembly-tree" % _root_part_id
	var seq := _mutation_seq
	var result := await _get_json(base)
	if token != _refresh_token:
		return true
	if seq != _mutation_seq:
		# (a Fix / Float was done while this was in flight: this answer may predate it. Read again; never show it.)
		if _tree.is_empty():
			_refresh_root.call_deferred() # (nothing is shown yet, so request_refresh would do nothing: start the load again)
		else:
			request_refresh()
		return true
	if not result["ok"]:
		if _route_missing(result):
			_endpoint_missing = true # an older backend: no such route (not "Part not found", which is an answer from a backend that has the call)
			_resp = {}
			_restore_due = false # (open rows are remembered from the tree call's keys only)
			_query = ""
			_sync_fold_button()
			return false
		_structure_failed()
		_set_status("Couldn't load the assembly tree: %s" % _reason(result))
		return true
	if not (result["json"] is Dictionary):
		_structure_failed()
		_set_status("Couldn't load the assembly tree: unexpected answer.")
		return true
	_adopt_response(result["json"])
	_stale = false
	_set_status(_tree_note(false))
	_rebuild_rows()
	seq = _mutation_seq
	var was_unavailable := _status_unavailable
	_status_unavailable = false # (one failed status call must not stick: this load asks again; a failed structure call above leaves the last answer's flag alone)
	var with_status := await _get_json(base + "?status=true")
	if token != _refresh_token or _tree.is_empty():
		return true
	if seq != _mutation_seq:
		_status_unavailable = was_unavailable # (this answer is dropped and no status call is pending: if the refresh below fails too, the hint stays as it was)
		request_refresh()
		return true
	if with_status["ok"] and with_status["json"] is Dictionary:
		_adopt_response(with_status["json"])
		_set_status(_tree_note(true))
		_rebuild_rows()
	else:
		_status_unavailable = true
		Model.clear_pending(_resp) # (no fresh status is coming: fall back to the flag-based state rather than "updating" for good)
		_rebuild_rows()
		_set_status((_tree_note(false) + " Constraint states unavailable: %s" % _reason(with_status)).strip_edges())
	return true


func _structure_failed() -> void:
	## The structure call failed and the answer shown stays. If that answer never had its states (a status answer dropped for a Fix / Float or a token, or one that failed),
	## no status is coming for it: say "unavailable" whatever the flag was, and let a floated row stop reading "updating".
	if _resp.is_empty() or _tree.is_empty() or bool(_resp.get("status_included", false)):
		return
	_status_unavailable = true
	Model.clear_pending(_resp)
	_rebuild_rows()


static func _route_missing(result: Dictionary) -> bool:
	## The framework's own 404 for an unknown route ({"detail": "Not Found"}); the backend's "Part not found" is a real answer and says nothing about the route.
	return int(result.get("code", 0)) == 404 and str(result.get("detail", "")) == "Not Found"


static func _reason(result: Dictionary) -> String:
	var text := str(result.get("error", ""))
	return text if text != "" else ("no answer (HTTP %d)" % int(result.get("code", 0)) if int(result.get("code", 0)) > 0 else "no answer")


func _sync_fold_button() -> void:
	if _fold_button != null:
		_fold_button.visible = _uses_tree_endpoint() # (grouping is the tree call's: the per-level fallback has nothing to fold)
	if _find_button != null:
		_find_button.visible = _uses_tree_endpoint() # (so is the filter)


func _tree_note(status_done: bool) -> String:
	var notes: PackedStringArray = []
	if (_resp.get("children", []) as Array).is_empty():
		notes.append("This assembly has no placed occurrences.")
	if bool(_resp.get("truncated_depth", false)) or bool(_resp.get("truncated_nodes", false)):
		notes.append("The tree is cut off at %d parts / %d levels; counts cover what is listed." % [int(_resp.get("max_nodes", 0)), int(_resp.get("max_depth", 0))])
	if status_done and bool(_resp.get("status_incomplete", false)):
		notes.append("Some levels' constraint states could not be read (marked on their rows).")
	return " ".join(notes)


func _note_placements_may_change() -> void:
	## A tree answer (or, in the per-level fallback, a re-read of the levels): a count read before it is dropped, and the one shown is read again once. This is the one
	## place an unreadable count (-1) is given another try (B8.1): not on every bar rebuild.
	_uses_gen += 1
	if not _uses_cache.is_empty():
		_uses_cache["fresh"] = false


func _adopt_response(resp: Dictionary) -> void:
	## Takes a tree answer as the current one and rebuilds the rows from it, keeping what was open (spec section 8).
	Model.normalise_tree(resp)
	if not bool(resp.get("status_included", false)):
		_note_placements_may_change()
		Model.carry_status(resp, _resp)
	_resp = resp
	var old_children: Array = (_tree[0]["children"] as Array) if not _tree.is_empty() and _tree[0].get("children") != null else []
	var rows := Model.merge_expanded(old_children, Model.rows_from_tree(resp.get("children", []), [], _root_part_id, bool(resp.get("status_failed", false)), _unsaved_part_ids()))
	if _restore_due:
		_restore_due = false
		_restore_open_rows(resp, rows)
	var root_name := str(resp.get("part_name", ""))
	if root_name == "":
		root_name = str(_part_names.get(_root_part_id, "Assembly"))
	_part_names[_root_part_id] = root_name
	_tree = [{
		"id": "", "name": root_name, "base_name": root_name, "override": false, "named": true, "resolved_part_id": _root_part_id,
		"children": rows, "expanded": true, "fixed": false, "backend_hidden": false, "suppressed": false, "missing": false,
		"path": [], "status": "", "state": "none", "parent_part_id": "",
	}]


func _row_text(row: Dictionary, button: Button = null) -> String:
	## The name first, then short extras in order of importance (state, hidden, rigid-set note, no status). With a `button`, each extra is added only while the text
	## still fits that button as laid out (its real width, its own theme font, icon and padding: so the problem bubble and any row buttons beside it are already
	## taken out); without one, all of them. What is left out is in the bottom bar when the row is selected (_row_detail), and the icon and tint still show the state.
	var text := str(row["name"])
	var extras := row_extras(row)
	for extra in extras:
		var longer: String = text + "  · %s" % str(extra)
		if button != null and _text_width(longer, button) > _text_room(button):
			break # (in priority order: once one does not fit, the rest are left for the bar)
		text = longer
	return text


const PROBLEM_STATES := ["missing", "cycle", "broken", "over_constrained", "near"]


func row_extras(row: Dictionary) -> Array:
	## The short words a row may wear after its name, in the order they are kept when the row is narrow (B8, the owner's order, 21 Nov): a problem state's word first
	## (missing, loop, broken, over, near); then "suppressed" (a suppressed part is not solved, so its state means little); the rigid-set note; the other state word
	## (unsaved, under n, full, fixed, updating); "no status"; "hidden" last. The bottom bar keeps the full reasons (_row_detail).
	var problem := ""
	var state_word := ""
	if bool(row.get("missing", false)):
		problem = "missing"
	elif row.has("state"):
		var state := str(row["state"])
		if PROBLEM_STATES.has(state):
			problem = Model.state_hint_short(state)
		else:
			state_word = Model.state_hint_short(state, int(row.get("dof", -1)))
	else:
		var status_word := _legacy_hint_short({"status": row.get("status", ""), "dof": row.get("dof", -1), "fixed": row.get("fixed", false)})
		if status_word == "over":
			problem = status_word
		else:
			state_word = status_word
	var extras: Array = [problem]
	if bool(row.get("suppressed", false)):
		extras.append("suppressed")
	extras.append(str(row.get("set_note", "")))
	extras.append(state_word)
	if bool(row.get("status_unavailable", false)):
		extras.append("no status")
	if _row_view_hidden(row):
		extras.append("hidden")
	return extras.filter(func(e): return str(e) != "")


static func _text_room(button: Button) -> float:
	## The width the button's text can use: its size less the stylebox's padding and the icon with its gap.
	var room := button.size.x - button.get_theme_stylebox("normal").get_minimum_size().x
	if button.icon != null:
		room -= button.icon.get_width() + button.get_theme_constant("h_separation")
	return room


static func _text_width(text: String, button: Button) -> float:
	return button.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x


func _fit_row_text(button: Button, row: Dictionary) -> void:
	## Once the button has its real size (and again when it changes: the panel is resized), the extras are fitted to it. The text change does not change the size
	## (the button expands to fill and clips), so this settles at once.
	if button.size.x < 40.0:
		return
	var text := _row_text(row, button)
	if text != button.text:
		button.text = text


static func _legacy_hint_short(row: Dictionary) -> String:
	## The per-level fallback's rows carry no `state`: the same short words from the constraint status.
	if bool(row.get("suppressed", false)):
		return "suppressed"
	match str(row.get("status", "")):
		"fixed":
			return "fixed"
		"fully_constrained":
			return "full"
		"under_constrained":
			return "under" + (" %d" % int(row.get("dof", -1)) if int(row.get("dof", -1)) >= 0 else "")
		"over_constrained":
			return "over"
	return "fixed" if bool(row.get("fixed", false)) else ""


func _row_detail(row: Dictionary) -> String:
	## The whole reason, for the bottom bar: "missing file: lost_bracket", "under-constrained (2 DOF)", "hidden in the view", the rigid set's note, and so on.
	var parts: PackedStringArray = []
	var hint := Model.state_hint(row, int(row.get("dof", -1)))
	if bool(row.get("missing", false)):
		parts.append("missing file") # (the bar's line starts with the name)
	elif hint != "":
		parts.append(hint)
	if _room_unknown_below(row):
		parts.append("can't tell whether the open room's part is inside: its rows have not been read (open it to see)")
	if _row_view_hidden(row):
		parts.append("hidden in the view")
	if bool(row.get("status_unavailable", false)):
		parts.append("constraint status unavailable")
	if str(row.get("set_note", "")) != "":
		parts.append(str(row["set_note"]))
	return ", ".join(parts)


func _row_view_hidden(row: Dictionary) -> bool:
	return not bool(row.get("missing", false)) and scope.row_hidden(_main, row.get("path", []))


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
		_bar_row = {}
		_bar_uses = ""
		_bar_greyed = ""
		_bar_hint.text = scope.bar_prompt()
		return
	var manager = _main.get("room_manager") if _main != null and scope.offers_room else null
	var room := room_action(row, manager)
	var nodes: Array = scope.row_nodes(_main, row.get("path", []))
	var ctx := {"has_nodes": not nodes.is_empty(), "hidden": scope.row_hidden(_main, row.get("path", [])), "room_text": str(room.get("text", ""))}
	var greyed: PackedStringArray = []
	var extras: Array = scope.extra_actions(_main, row)
	var extra_why := ""
	if extras.size() > 1 and extras.all(func(a) -> bool: return not bool(a["enabled"]) and str(a["why"]) == str(extras[0]["why"])):
		extra_why = str(extras[0]["why"]) # (Table and Bring greyed for one reason: said once, "Table, Bring: ...", so the hint stays short on the PARTS tab's narrow bar)
		greyed.append("%s: %s" % [", ".join(PackedStringArray(extras.map(func(a) -> String: return str(a["label"])))), extra_why])
	for action in extras + Model.actions_for(row, ctx): # (C6: the scope's own first: the Table scope's Table and Bring)
		var b := Button.new()
		b.text = _bar_label(action, row)
		b.custom_minimum_size = Vector2(0, ROW_HEIGHT * 0.9)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", tokens.font_small)
		b.disabled = not bool(action["enabled"])
		if str(action["id"]) == "delete":
			b.theme_type_variation = &"ButtonDanger"
		elif str(action["id"]) == "table":
			b.theme_type_variation = &"ButtonAccent"
		if b.disabled and not (extra_why != "" and extras.has(action)):
			greyed.append("%s: %s" % [action["label"], action["why"]])
		b.pressed.connect(_on_bar_action.bind(str(action["id"]), row, room))
		_bar_buttons.add_child(b)
	_bar_greyed = "; ".join(greyed)
	_bar_uses = ""
	_bar_row = row
	_set_bar_hint()
	if str(room.get("text", "")) == "Close room":
		_refresh_bar_uses(row, str(room["part_id"]))


func _set_bar_hint() -> void:
	var row := _bar_row
	if row.is_empty():
		return
	var detail := _row_detail(row)
	_bar_hint.text = "%s%s%s%s" % [str(row["name"]), ("  ·  " + detail) if detail != "" else "", ("  ·  " + _bar_uses) if _bar_uses != "" else "", ("  ·  " + _bar_greyed) if _bar_greyed != "" else ""]


func _refresh_bar_uses(row: Dictionary, part_id: String) -> void:
	## B8: a row whose room is open says how many times its Part is placed, as the room console does ("Placed N times: editing it here changes all of them"). The last
	## count for the same row, Part and assembly is kept and shown at once; it is read again only after a tree answer (the placements may have changed) and never on
	## every bar rebuild. A count that could not be read (-1) shows nothing, and is asked for again only after the next tree answer, like any other.
	var manager = _main.get("room_manager") if _main != null else null
	var e = manager.edit_api() if manager != null and manager.has_method("edit_api") else null
	if e == null or _root_part_id == "":
		return
	var path: Array = row.get("path", [])
	var root := _root_part_id
	var key := "%s|%s|%s" % [Model.path_key(path), part_id, root]
	if str(_uses_cache.get("key", "")) == key:
		_bar_uses = RoomConsole.uses_text(int(_uses_cache["count"]))
		_set_bar_hint()
		if bool(_uses_cache["fresh"]):
			return
	else:
		_uses_cache = {}
	var reading := "%s#%d" % [key, _uses_gen]
	if _uses_reading == reading:
		return # (this very count is being read already: its answer fills the bar)
	_uses_reading = reading
	var fresh := _uses_gen != _uses_read_gen # (the document changed since the last read: not from RoomEdit's cached lists; otherwise the cache is the cheap answer)
	_uses_read_gen = _uses_gen
	var count: int = await e.instance_count(root, part_id, fresh)
	if not is_instance_valid(self):
		return
	if _uses_reading == reading:
		_uses_reading = ""
	if reading != "%s#%d" % [key, _uses_gen]:
		if _has_selected and _selected == path:
			call_deferred("_refresh_bar_uses", row, part_id) # (the document changed while this was read: the answer may predate it, so ask again now)
		return
	if not _has_selected or _selected != path or root != _root_part_id or not is_instance_valid(manager) or not manager.is_open_for(part_id):
		return # (the selection, the document or the room moved on while this was read)
	_uses_cache = {"key": key, "count": count, "fresh": true} # (B8.1: an unreadable count, -1, shows nothing and is read again once per tree answer, not on every bar rebuild: _adopt_response ends `fresh`)
	_bar_uses = RoomConsole.uses_text(count)
	_set_bar_hint()


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
				note_fixed_changed(path, bool(row["fixed"]))
		"hide":
			scope.set_row_visible(_main, path, scope.row_hidden(_main, path), label)
			_rebuild_rows()
		"isolate":
			scope.isolate_row(_main, path, label)
			_rebuild_rows()
		"rename":
			_rename(row)
		"room":
			if not room.is_empty() and _main.get("room_manager") != null:
				_main.room_manager.toggle_room(room["part_id"], room["label"], room["parent_part_id"], room["occurrence_id"])
		"delete":
			_on_delete_pressed(row)
		_:
			_on_scope_action(action_id, row)


func _on_scope_action(_action_id: String, _row: Dictionary) -> void:
	## A window acts on the actions its scope adds (Scope.extra_actions): the table's Table and Bring.
	pass


func watch_mates(tool) -> void:
	## Live without losing what is open (V-7), and every Fix / Float the tool makes, from wherever (this window's bar, the tablet, an undo or a redo).
	tool.mates_changed.connect(request_refresh)
	tool.document_changed.connect(request_refresh)
	if tool.has_signal("occurrence_fixed_changed"):
		tool.occurrence_fixed_changed.connect(_on_occurrence_fixed)


func _on_occurrence_fixed(owner_part_id: String, occurrence_id: String, fixed: bool) -> void:
	## Every row of that occurrence (a sub-assembly placed twice shows it twice) is marked as the bar's Fix / Float marks it.
	var paths: Array = []
	if not _tree.is_empty():
		for row in Model.index_rows(_tree[0]["children"] as Array).values():
			if str(row.get("id", "")) == occurrence_id and str(row.get("parent_part_id", "")) == owner_part_id:
				paths.append(row["path"])
	if paths.is_empty():
		_mutation_seq += 1 # (not shown here: any read in flight still predates it)
		request_refresh()
		return
	for path in paths:
		note_fixed_changed(path, fixed)


func note_fixed_changed(path: Array, fixed: bool) -> void:
	## A Fix / Float the backend has accepted: shown at once (a pin, or "updating" for a Float until fresh status says what the part is now), any tree read still in
	## flight is made stale (it may predate this), and a fresh read is queued.
	_mutation_seq += 1
	if _endpoint_active():
		Model.set_node_fixed(_resp, path, fixed)
		if not fixed:
			_resp["status_included"] = false # (the floated part's status is not in the answer held any more: if the read that follows fails, _structure_failed settles it)
	var row := Model.find_row(_tree, path)
	if not row.is_empty():
		row["fixed"] = fixed
	_rebuild_rows()
	request_refresh()


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
	if _endpoint_active():
		request_refresh() # (the spec's names and groups are worked out from the answer: "Bolt <n>" renumber there)
	else:
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
	if _endpoint_active():
		_refresh_token += 1 # (the whole tree is one call: re-read it in place; what is open and selected stays)
		if await _load_endpoint(_refresh_token):
			return
		# the backend turned out not to have the call: the rows already here are re-read a level at a time below
	_note_placements_may_change() # (the fallback has no tree answer: its re-read of the levels is the same moment)
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
		return {"ok": false, "json": null, "code": 0, "error": "no backend configured"}
	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key, body != null)
	var err := req.request(backend_url + API_PREFIX + path, headers, method, JSON.stringify(body) if body != null else "")
	if err != OK:
		req.queue_free()
		return {"ok": false, "json": null, "code": 0, "error": "request failed to start (error %d)" % err}
	var result: Array = await req.request_completed
	req.queue_free()
	var result_code: int = result[0]
	var response_code: int = result[1]
	var raw: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "json": null, "code": 0, "error": "network error (result %d)" % result_code}
	var parsed = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	var ok: bool = response_code >= 200 and response_code < 300
	return {"ok": ok, "json": (parsed if ok else null), "code": response_code, "detail": (str(parsed.get("detail", "")) if parsed is Dictionary else ""), "error": ("" if ok else str(parsed))}
