extends SceneTree
## Tree A5.1: a Fix / Float made from the Assembly Tree against a slow backend (a fake one that holds back an answer), and what the row says meanwhile.
##   1. an answer to a tree read sent BEFORE a Float, delivered AFTER it, is not shown (before A5.1 it put the part back to "fixed" until the next refresh), and the
##      read that follows leaves the row as the backend now has it; the same for the ?status=true half of a read
##   2. straight after a Float the row says "updating" (no icon, never a blank that reads as "free"), also when a structure-only answer comes first, and it
##      never shows a state that is wrong: fixed stays a pin, a Float becomes the fresh status when it arrives
##   3. the row's own hint is short (fits a 480 px panel); the full reason is in the bottom bar when the row is selected
## NOT covered: how it looks (tests/assembly_tree_render.gd, under Mesa), or the headset.
## Run: "$GODOT" --headless --path . --script res://tests/assembly_tree_races.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")

var main
var window
var backend_fixed := true ## the fake backend's truth for occurrence "p"
var hold_next := ""  ## "structure" / "status": hold the next such answer back until release() (its content is taken NOW: it predates what happens meanwhile)
var held: Dictionary = {}
var held_released := false
var held_answered := false
var calls: Array = []
var status_fails := false ## the ?status=true call fails


class FakeMates extends "res://scripts/mates_tool.gd":
	var on_patch := Callable()

	func _api_request(method: int, _path: String, body_dict) -> Dictionary:
		if method == HTTPClient.METHOD_PATCH:
			if on_patch.is_valid():
				on_patch.call(bool(body_dict.get("fixed", false)))
			return {"ok": true, "code": 200, "json": {}, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func tree(with_status: bool) -> Dictionary:
	var constraint = {"status": "fixed" if backend_fixed else "under_constrained", "dof": 0 if backend_fixed else 2, "rigid_set": null, "broken_mates": 0, "near_mates": 0} if with_status else null
	return {
		"part_id": "R", "part_name": "Rig", "kind": "assembly", "feature_count": 0, "status_included": with_status,
		"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
		"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0},
		"children": [{
			"occurrence_id": "p", "path": ["p"], "external_ref": null, "ref_part_id": "P", "resolved_part_id": "P", "part_name": "Peg", "name_override": null,
			"kind": "part", "fixed": backend_fixed, "hidden": false, "suppressed": false, "color": null, "constraint": constraint,
			"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": [],
		}, {
			"occurrence_id": "m", "path": ["m"], "external_ref": "lost_bracket.didsa", "ref_part_id": null, "resolved_part_id": null, "part_name": null, "name_override": "lost_bracket",
			"kind": "missing", "fixed": false, "hidden": false, "suppressed": false, "color": null, "constraint": null,
			"feature_count": null, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": [],
		}],
		"truncated": false, "node_count": 2, "max_depth": 32, "max_nodes": 10000, "truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
	}


func answer(method: int, path: String, _body) -> Dictionary:
	calls.append(path)
	if method == HTTPClient.METHOD_GET and path.begins_with("/parts/R/assembly-tree"):
		var with_status := path.contains("status=true")
		if with_status and status_fails:
			return {"ok": false, "json": null, "code": 0, "error": ""}
		var snapshot := tree(with_status) # (taken when the request is answered by the backend; a held answer keeps this, whatever happens next)
		var kind := "status" if with_status else "structure"
		if hold_next == kind:
			hold_next = ""
			held_released = false
			held_answered = false
			while not held_released:
				await process_frame
			held_answered = true
		return {"ok": true, "json": snapshot, "error": ""}
	if method == HTTPClient.METHOD_GET and path == "/parts/R":
		return {"ok": true, "json": {"name": "Rig"}, "error": ""}
	return {"ok": false, "json": null, "code": 404, "error": "404"}


func p_row() -> Dictionary:
	return Model.find_row(window._tree, ["p"])


func settle(seconds: float = 1.6) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await process_frame


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main._resolved_part_id = "R"
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	await frames(8)

	check("(setup) the window read the tree and the part is fixed (a pin)", p_row().get("state") == "fixed" and Model.state_icon(p_row()) == "pin")

	# --- 1. the stale answer: the read is sent while the part is fixed, the Float happens, the (old) answer arrives afterwards
	hold_next = "structure"
	window.request_refresh()
	await settle(0.9) # (the refresh timer fires, the structure read is now held back)
	check("(setup) a structure read is in flight, held back", hold_next == "" and not held_answered)
	backend_fixed = false # the Float reaches the backend ...
	window.note_fixed_changed(["p"], false) # ... and the window is told
	check("2. straight after a Float the row says 'updating': no pin, no blank 'free', the state is 'pending'", p_row()["state"] == "pending" and Model.state_icon(p_row()) == "" and window._row_text(p_row()).ends_with("· updating"))
	held_released = true # the old answer (fixed: true) lands now
	await frames(3)
	check("1. the answer that predates the Float is not shown: the row is not a pin again", p_row()["state"] != "fixed" and not bool(p_row()["fixed"]))
	await settle(2.0)
	check("...and the read that follows leaves it as the backend has it (under-constrained, from the fresh status)", p_row()["state"] == "under_constrained" and Model.state_icon(p_row()) == "lock_open")

	# --- the same, with the status half held back (the structure answer came first)
	backend_fixed = true
	window.note_fixed_changed(["p"], true)
	await settle(2.0)
	check("(setup) fixed again, from the backend", p_row()["state"] == "fixed")
	hold_next = "status"
	window.request_refresh()
	await settle(1.2)
	check("(setup) the status read is in flight, held back", hold_next == "" and not held_answered)
	backend_fixed = false
	window.note_fixed_changed(["p"], false)
	held_released = true
	await frames(3)
	check("1b. a ?status=true answer that predates the Float is dropped too", p_row()["state"] != "fixed")
	await settle(2.0)
	check("...and the following read settles on the backend's truth", p_row()["state"] == "under_constrained")

	# --- 2. a structure-only answer straight after a Float: no old status is carried over a changed flag, and the row stays 'updating'
	window.note_fixed_changed(["p"], true)
	backend_fixed = true
	await settle(2.0)
	backend_fixed = false
	hold_next = "status"
	window.note_fixed_changed(["p"], false) # (the refresh it queues reads the structure first, then holds the status)
	await settle(1.4)
	check("2b. while only the structure has arrived, the floated part is 'updating', not blank and not fixed", p_row()["state"] == "pending" and Model.state_icon(p_row()) == "")
	held_released = true
	await settle(0.5)
	check("...and the status then replaces it", p_row()["state"] == "under_constrained")

	# --- 1c. nothing shown yet (a first load, or after mark_stale): a dropped answer must restart the load, not leave "Loading..."
	hold_next = "structure"
	window.mark_stale()
	await settle(0.4)
	check("(setup) the first load is in flight, held back, nothing shown yet", hold_next == "" and not held_answered and window._tree.is_empty())
	window.note_fixed_changed(["p"], false) # (a Float elsewhere while it is in flight)
	held_released = true
	await settle(1.2)
	check("1c. the dropped first answer restarts the load: the rows are there, not stuck on 'Loading...'", not window._tree.is_empty() and window._status_label.text != "Loading..." and p_row().get("state") == "under_constrained")

	# --- 2c. the status half fails: "updating" is cleared, now and in later structure-only answers
	backend_fixed = true
	window.note_fixed_changed(["p"], true)
	await settle(2.0)
	status_fails = true
	backend_fixed = false
	window.note_fixed_changed(["p"], false)
	check("(setup) floated: updating", p_row()["state"] == "pending")
	await settle(2.0)
	check("2c. when ?status=true fails the row falls back to its flag (free: not fixed), it is not 'updating' for good", p_row()["state"] == "none" and not window._row_text(p_row()).contains("updating"))
	window.request_refresh()
	await settle(2.0)
	check("...and a later structure-only answer does not bring 'updating' back", p_row()["state"] == "none")
	status_fails = false
	window.request_refresh()
	await settle(2.0)
	check("...the next good status settles it", p_row()["state"] == "under_constrained")

	# --- 5. a Fix / Float from outside the tree's bar: the tablet's, and an undo / redo of the bar's
	var mates := FakeMates.new()
	mates.command_stack = main.command_stack
	mates.backend_url = "http://example.invalid"
	mates.api_key = "k"
	mates.on_patch = func(fixed: bool) -> void: backend_fixed = fixed
	main.add_child(mates)
	await process_frame
	mates._nested_states["R"] = {"occurrences": {"p": {"fixed": false}}, "mated": {}}
	var real_mates = main._mates_tool
	main._mates_tool = mates
	window.watch_mates(mates)
	await mates.set_occurrence_fixed("R", "p", true, "Peg", false) # (the tablet's Fix: nothing goes through the tree's bar)
	check("5. a Fix made outside the tree's bar shows at once: a pin", p_row()["state"] == "fixed" and Model.state_icon(p_row()) == "pin")
	await settle(2.0)
	await mates.set_occurrence_fixed("R", "p", false, "Peg", false)
	check("5. a Float made outside the tree's bar shows 'updating' at once (and marks the read in flight stale)", p_row()["state"] == "pending")
	await settle(2.0)
	check("...and settles on the fresh status", p_row()["state"] == "under_constrained")
	await mates.set_occurrence_fixed("R", "p", true, "Peg", false)
	await settle(2.0)
	await window._on_bar_action("fix", p_row(), {}) # Float from the bar (one undo step)
	check("5. Float from the tree's bar: updating", p_row()["state"] == "pending" and not backend_fixed)
	main.command_stack.undo() # Undo: fixed again, through the command stack, not the bar
	await frames(3)
	check("5. ...Undo settles on the pin at once, not 'updating'", p_row()["state"] == "fixed" and Model.state_icon(p_row()) == "pin" and backend_fixed)
	await settle(2.0)
	check("...and the fresh status agrees", p_row()["state"] == "fixed")
	main.command_stack.redo()
	await frames(3)
	check("5. ...Redo shows the Float again (updating) and then the fresh status", p_row()["state"] == "pending")
	await settle(2.0)
	check("...settled", p_row()["state"] == "under_constrained")
	main._mates_tool = real_mates

	# --- 3. hints
	var missing_row: Dictionary = Model.find_row(window._tree, ["m"])
	var text: String = window._row_text(missing_row)
	check("3. a missing file's row is its name first, then one short word (no 'missing file: ' in front of it)", text == "lost_bracket  · missing")
	check("...the longest hint of any state is short enough for the panel", (Model.STATES + ["pending"]).all(func(s): return Model.state_hint_short(s, 12).length() <= 11))
	check("...and the full words are in the bottom bar when the row is selected", window._row_detail(missing_row) == "missing file")
	window._selected = ["m"]
	window._has_selected = true
	window._rebuild_rows()
	check("...the bar's hint line is the name, the full reason, then why the greyed actions are greyed (exactly)", window._bar_hint.text == "lost_bracket  ·  missing file  ·  Fix: its file is missing; Hide: nothing of it is on screen; Isolate: nothing of it is on screen; Rename: only a placed part has its own name")
	window._selected = ["p"]
	window._rebuild_rows()
	check("...and under-constrained with its degrees of freedom, in full", window._bar_hint.text.contains("under-constrained (2 DOF)") and window._row_text(p_row()).contains("under 2") and not window._row_text(p_row()).contains("under-constrained"))
	main.queue_free()
	await frames(2)
	quit(0)
