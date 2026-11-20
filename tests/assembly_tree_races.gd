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
	check("2. straight after a Float the row says 'updating': no pin, no blank 'free', the state is 'pending'", p_row()["state"] == "pending" and Model.state_icon(p_row()) == "" and window._row_text(p_row()).contains("..."))
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

	# --- 3. hints
	var missing_row: Dictionary = Model.find_row(window._tree, ["m"])
	var text: String = window._row_text(missing_row)
	check("3. a missing file's row is its name first, then one short word (no 'missing file: ' in front of it)", text == "lost_bracket  · missing")
	check("...the longest hint of any state is short enough for the panel", (Model.STATES + ["pending"]).all(func(s): return Model.state_hint_short(s, 12).length() <= 11))
	check("...and the full words are in the bottom bar when the row is selected", window._row_detail(missing_row) == "missing file")
	window._selected = ["m"]
	window._has_selected = true
	window._rebuild_rows()
	check("...the bar's hint line carries them for the selected row", window._bar_hint.text == "lost_bracket  ·  missing file  ·  Fix: its file is missing; Hide: nothing of it is on screen; Isolate: nothing of it is on screen; Rename: only a placed part has its own name" or window._bar_hint.text.begins_with("lost_bracket  ·  missing file"))
	window._selected = ["p"]
	window._rebuild_rows()
	check("...and under-constrained with its degrees of freedom, in full", window._bar_hint.text.contains("under-constrained (2 DOF)") and window._row_text(p_row()).contains("under 2") and not window._row_text(p_row()).contains("under-constrained"))
	main.queue_free()
	await frames(2)
	quit(0)
