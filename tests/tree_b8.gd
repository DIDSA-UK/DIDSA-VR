extends SceneTree
## Tree B8: room context in the world Assembly Tree, and the row-hint order. Full scene against a small fake backend and a fake room manager.
##   1. while a room is open, every row that is not a placement of the room's Part (or below one) is dimmed; two placements of the Part and the rows below them stay full and
##      wear the rail; a sibling and the root are dimmed; closing the room undims everything; the same under a filter; a re-used control keeps nothing of the old row
##   2. the bottom bar of a row whose room is open says "Placed N times" as the room console does (and nothing for a row without a room)
##   3. the hint order: a problem word first, then suppressed, the rigid-set note, the other state word, hidden last; on a narrow row the later ones are the ones left out
## NOT covered: how the dimming and the rail look (Mesa pictures: tools/assembly_tree_render_check/, scenario k) or read in the headset.
## Run: "$GODOT" --headless --path . --script res://tests/tree_b8.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")

var main
var window
var rooms


class FakeRooms extends Node:
	signal rooms_changed
	var parts: Array = []
	var count := 2
	var calls := 0 ## how many counts were asked for
	var fresh_calls := 0 ## ...of them, how many asked to skip any cache
	var hold := false ## answers wait until this clears

	func open_part_ids() -> Array:
		return parts.duplicate()

	func is_open_for(part_id: String) -> bool:
		return parts.has(part_id)

	func is_placing_for(_part_id: String) -> bool:
		return false

	func edit_api():
		return self

	func instance_count(_root: String, _part: String, fresh: bool = false) -> int:
		calls += 1
		fresh_calls += 1 if fresh else 0
		var seen := count # (what the document said when it was asked: a slow answer predates later changes)
		await Engine.get_main_loop().process_frame # (an answer takes a frame: a late one can meet a newer selection or a closed room)
		while hold:
			await Engine.get_main_loop().process_frame
		return seen


class HiddenStub extends Node:
	func tree_row_hidden(_path) -> bool:
		return true


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func until(condition: Callable, seconds: float = 4.0) -> bool:
	## Frames until the condition holds (bounded): no fixed wait to outrun on a slow machine.
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < end:
		await process_frame
	return condition.call()


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func node(id: String, part: String, name: String, children: Array, prefix: Array) -> Dictionary:
	var node_path: Array = prefix + [id]
	return {
		"occurrence_id": id, "path": node_path, "external_ref": null, "ref_part_id": part, "resolved_part_id": part, "part_name": name, "name_override": null,
		"kind": "assembly" if not children.is_empty() else "part", "fixed": false, "hidden": false, "suppressed": false, "color": null, "constraint": null,
		"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": children,
	}


func tree_answer(with_status: bool) -> Dictionary:
	# Rig: two placements of Frame (each with a Bolt below it), a Plate beside them, and a Lid with a Bolt below it (that Bolt is not in a Frame).
	var children := [
		node("a1", "A", "Frame", [node("b1", "B", "Bolt", [], ["a1"])], []),
		node("a2", "A", "Frame", [node("b2", "B", "Bolt", [], ["a2"])], []),
		node("c", "C", "Plate", [], []),
		node("d", "D", "Lid", [node("b3", "B", "Bolt", [], ["d"])], []),
	]
	return {
		"part_id": "R", "part_name": "Rig", "kind": "assembly", "feature_count": 0, "status_included": with_status,
		"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
		"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0},
		"children": children, "truncated": false, "node_count": 7, "max_depth": 32, "max_nodes": 10000,
		"truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
	}


func answer(method: int, path: String, _body) -> Dictionary:
	if method == HTTPClient.METHOD_GET and path.begins_with("/parts/R/assembly-tree"):
		return {"ok": true, "json": tree_answer(path.contains("status=true")), "error": ""}
	if method == HTTPClient.METHOD_GET and path == "/parts/R":
		return {"ok": true, "json": {"name": "Rig"}, "error": ""}
	return {"ok": false, "json": null, "code": 404, "error": "404"}


func desc_for(path: Array) -> Dictionary:
	var key := Model.path_key(path)
	for d in window._descs:
		if str(d["kind"]) == "row" and Model.path_key((d["row"] as Dictionary).get("path", [])) == key:
			return d
	return {}


func state_of(path: Array) -> String:
	## "full" / "dim" and "rail" or "plain" of a row, as listed (the descs) and, when it is drawn, as its control shows it.
	var d := desc_for(path)
	if d.is_empty():
		return "not listed"
	var listed := ("dim" if bool(d.get("room_dim", false)) else "full") + (" rail" if bool(d.get("room_in", false)) else "")
	var line = window._row_controls.get(Model.path_key(path))
	if line == null:
		return listed
	var shown := ("dim" if (line as Control).modulate.a < 0.9 else "full") + (" rail" if bool((line.get_meta("rail") as Control).visible) else "")
	return listed if shown == listed else "MISMATCH %s vs %s" % [listed, shown]


func open_all() -> void:
	for p in [["a1"], ["a2"], ["d"]]:
		Model.find_row(window._tree, p)["expanded"] = true
	window._rebuild_rows()


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main._resolved_part_id = "R"
	main._settings.tree_open_docs = []
	rooms = FakeRooms.new()
	main.room_manager = rooms
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	await frames(8)
	check("(setup) the tree call was used and the rows are here", window._endpoint_active() and window.row_count() == 5)
	open_all()
	await frames(3)

	# --- 1. no room open: nothing dimmed, no rail
	check("1. no room open: every row full and plain", [["a1"], ["a1", "b1"], ["a2"], ["a2", "b2"], ["c"], ["d"], ["d", "b3"]].all(func(p): return state_of(p) == "full"))

	# --- 1. the room of Part A is open
	rooms.parts = ["A"]
	window._on_rooms_changed()
	await frames(3)
	check("1. both placements of the room's Part are full and wear the rail", state_of(["a1"]) == "full rail" and state_of(["a2"]) == "full rail")
	check("1. the rows below each placement are full with the rail", state_of(["a1", "b1"]) == "full rail" and state_of(["a2", "b2"]) == "full rail")
	check("1. a sibling is dimmed, without the rail", state_of(["c"]) == "dim")
	check("1. a row below another sibling is dimmed too, though it is a Bolt like the ones inside", state_of(["d"]) == "dim" and state_of(["d", "b3"]) == "dim")
	var root_desc: Dictionary = window._descs[0]
	check("1. the root row is outside the room: dimmed", bool(root_desc.get("room_dim", false)) and not bool(root_desc.get("room_in", false)))

	# --- 1. a re-used control keeps nothing of the old row: close the room, everything is undimmed and the rail is gone, on every drawn control
	rooms.parts = []
	window._on_rooms_changed()
	await frames(3)
	var leftovers := 0
	for line in window.visible_lines():
		if (line as Control).modulate.a < 0.9 or (line.get_meta("rail") as Control).visible:
			leftovers += 1
	check("1. closing the room undims every row and takes every rail away (%d drawn lines left marked)" % leftovers, leftovers == 0 and window.visible_lines().size() > 0 and state_of(["c"]) == "full")

	# --- 1. under a filter the room still dims what it does not hold
	rooms.parts = ["A"]
	window.set_query("bolt")
	window._on_rooms_changed()
	await frames(3)
	check("1. under a filter the Bolts inside the room are full, the one in the Lid is dimmed", state_of(["a1", "b1"]).begins_with("full") and state_of(["d", "b3"]).begins_with("dim"))
	window.clear_query()
	await frames(2)

	# --- 1. a room on the root's own Part holds every row
	rooms.parts = ["R"]
	window._on_rooms_changed()
	await frames(3)
	check("1. a room of the assembly's own Part: every row inside", state_of(["c"]) == "full rail" and bool((window._descs[0] as Dictionary).get("room_in", false)))
	rooms.parts = ["A"]
	window._on_rooms_changed()
	await frames(2)

	# --- 2. the bottom bar
	window._has_selected = true
	window._selected = ["a1"]
	window._rebuild_bar()
	await frames(4)
	check("2. a row whose room is open says how often its Part is placed: '%s'" % window._bar_hint.text, window._bar_hint.text.contains("Placed 2 times: editing it here changes all of them") and window._bar_hint.text.begins_with("Frame"))
	window._selected = ["c"]
	window._rebuild_bar()
	await frames(4)
	check("2. a row with no room says nothing of the kind", not window._bar_hint.text.contains("Placed"))
	rooms.count = 1
	window._selected = ["a2"]
	window._rebuild_bar()
	await frames(4)
	check("2. once it is placed once the bar says so", window._bar_hint.text.contains("Placed once"))
	window._selected = ["a1"]
	window._rebuild_bar()
	window._selected = ["c"] # (the selection moves on before the count is read: a late answer is dropped)
	window._rebuild_bar()
	await frames(4)
	check("2. a late count for a row no longer selected is not shown", not window._bar_hint.text.contains("Placed"))
	window._uses_cache = {}
	window._selected = ["a1"]
	rooms.count = -1 # (the occurrences could not be read: the count is unknown)
	window._rebuild_bar()
	await frames(4)
	check("2. a count that could not be read says nothing (not 'Not placed in the assembly')", not window._bar_hint.text.contains("Placed") and not window._bar_hint.text.contains("Not placed") and int(window._uses_cache.get("count", 0)) == -1)
	rooms.count = 2
	await until(func(): return window._refresh_timer == null and not window._busy) # (any refresh the room changes queued is out of the way)
	await frames(30)
	window._rebuild_bar()
	await frames(4)
	rooms.calls = 0
	rooms.fresh_calls = 0
	window._uses_cache = {}
	window._rebuild_bar()
	await frames(4)
	for i in 5:
		window._rebuild_bar()
		await frames(2)
	check("2. the last count for the same row and Part is kept: five more bar rebuilds read nothing again (%d reads, %d from the backend)" % [rooms.calls, rooms.fresh_calls], rooms.calls == 1 and rooms.fresh_calls == 0 and window._bar_hint.text.contains("Placed 2 times"))
	rooms.count = 3
	window.request_refresh() # (a tree answer: the placements may have changed)
	await until(func(): return rooms.calls >= 2)
	await frames(4)
	check("2. after a tree answer it is read once more, from the backend and not from a cache (the old one stayed shown meanwhile): %d reads, %d fresh" % [rooms.calls, rooms.fresh_calls], rooms.calls == 2 and rooms.fresh_calls == 1 and window._bar_hint.text.contains("Placed 3 times"))
	# a read that was in flight when the document changed lands afterwards: it is dropped and the count is read again
	window._uses_cache = {}
	window._rebuild_bar()
	await frames(4)
	rooms.count = 2
	rooms.hold = true
	rooms.calls = 0
	window._uses_cache = {}
	window._uses_reading = ""
	window._rebuild_bar() # (a read of 2 starts and waits)
	await frames(3)
	rooms.count = 3 # (a component is added: the document now has 3)
	window.request_refresh()
	await until(func(): return rooms.calls >= 2)
	rooms.hold = false # (released whatever the wait found, so nothing is left parked)
	await until(func(): return window._bar_hint.text.contains("Placed 3 times"))
	await frames(4)
	check("2. a read in flight when the document changed is dropped (the bar says 3, not the 2 it saw: %d reads)" % rooms.calls, window._bar_hint.text.contains("Placed 3 times") and not window._bar_hint.text.contains("Placed 2"))
	rooms.count = -1
	window._uses_cache = {}
	window._uses_reading = ""
	window._rebuild_bar()
	await frames(4)
	var said_nothing: bool = not window._bar_hint.text.contains("Placed") and not window._bar_hint.text.contains("Not placed")
	rooms.count = 2 # (the failure was a moment's: the next bar rebuild asks again)
	window._rebuild_bar()
	await frames(4)
	check("2. an unreadable count says nothing and is not kept as the answer: the next rebuild asks again and shows it", said_nothing and window._bar_hint.text.contains("Placed 2 times"))
	rooms.count = 3
	window._selected = ["a1"]
	rooms.count = 3
	window._rebuild_bar()
	rooms.parts = [] # (the room closes before the count is read)
	window._on_rooms_changed()
	await frames(4)
	check("2. a late count for a room that has closed is not shown", not window._bar_hint.text.contains("Placed"))

	# --- 3. the hint order
	var base := {"name": "Peg", "path": ["x"], "id": "x"}
	var row := base.duplicate()
	row.merge({"state": "missing", "suppressed": true, "set_note": "moves with 2 other parts"})
	check("3. a problem word comes first, then suppressed, then the rigid-set note: %s" % str(window.row_extras(row)), window.row_extras(row) == ["missing", "suppressed", "moves with 2 other parts"])
	row = base.duplicate()
	row.merge({"state": "under_constrained", "dof": 2, "set_note": "moves with Peg"})
	check("3. the rigid-set note comes before 'under n': %s" % str(window.row_extras(row)), window.row_extras(row) == ["moves with Peg", "under 2"])
	row = base.duplicate()
	row.merge({"state": "fully_constrained", "suppressed": true})
	check("3. suppressed comes before the state word 'full': %s" % str(window.row_extras(row)), window.row_extras(row) == ["suppressed", "full"])
	row = base.duplicate()
	row.merge({"state": "fixed", "set_note": "moves with Peg"})
	check("3. the note comes before 'fixed'", window.row_extras(row) == ["moves with Peg", "fixed"])
	for pair in [["cycle", "loop"], ["broken", "broken"], ["over_constrained", "over"], ["near", "near"]]:
		row = base.duplicate()
		row.merge({"state": pair[0], "suppressed": true, "set_note": "n"})
		check("3. '%s' is a problem state: its word '%s' stays first" % [pair[0], pair[1]], window.row_extras(row)[0] == pair[1] and window.row_extras(row).size() == 3)
	row = base.duplicate()
	row.merge({"state": "unsaved", "set_note": "n"})
	check("3. 'unsaved' is not a problem word: the note first", window.row_extras(row) == ["n", "unsaved"])
	row = base.duplicate()
	row.merge({"missing": true, "state": "missing"})
	check("3. a missing row says 'missing' once", window.row_extras(row) == ["missing"])
	row = base.duplicate()
	row.merge({"status": "under_constrained", "dof": 3, "suppressed": true, "set_note": "n"}) # (the per-level fallback's row: no state key)
	check("3. the per-level fallback's rows follow the same order: %s" % str(window.row_extras(row)), window.row_extras(row) == ["suppressed", "n", "under 3"])
	row = base.duplicate()
	row.merge({"state": "fixed", "set_note": "n", "status_unavailable": true})
	var real_main = window._main
	window._main = HiddenStub.new()
	check("3. 'hidden' is last: %s" % str(window.row_extras(row)), window.row_extras(row) == ["n", "fixed", "no status", "hidden"])
	window._main.free()
	window._main = real_main

	# --- 3. a narrow row keeps the first words and leaves the later ones for the bar
	row = base.duplicate()
	row.merge({"state": "near", "suppressed": true, "set_note": "moves with Peg"})
	var button := Button.new()
	button.theme_type_variation = &"ButtonRail"
	var first: String = "Peg  · near"
	button.size = Vector2(window._text_width(first, button) + button.get_theme_stylebox("normal").get_minimum_size().x + 4.0, 56)
	var narrow: String = window._row_text(row, button)
	check("3. a narrow row keeps the problem word and leaves 'suppressed' and the note for the bar ('%s')" % narrow, narrow == first)
	button.size.x += window._text_width("  · suppressed", button) + 4.0
	check("3. a little wider it gets 'suppressed' next, the note still left out ('%s')" % window._row_text(row, button), window._row_text(row, button) == first + "  · suppressed")
	button.free()
	main.queue_free()
	await frames(2)
	quit(0)
