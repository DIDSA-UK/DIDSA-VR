extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend), AND needs a DIDSA-CAD backend that has
## the Point Merge routes (POST /sketch/sketches/{id}/points/merge and PUT /sketch/sketches/{id}/state). A new part and a sketch on XY; four separate
## lines go round a square but the last one ends a hair away from where the first one starts, so the profile is open (it looks closed and is not); the two
## points are picked with the Select tool and merged; the profile is closed; undo restores the sketch IN PLACE (same ids, both points back) and it is open
## again. Refusals come back in the backend's own words: two ends of one line, and a dimension held between the two points.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_merge.gd   (DIDSA_NO_LANDING=1, secrets.cfg pointing at a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var s


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func line_between(a: Dictionary, b: Dictionary) -> String:
	## One line from pick `a` to pick `b` (picks as session.tap takes them: a position, or an existing point's id), and its id.
	s.set_tool("line")
	s.finish_chain()
	var before: Array = s.lines.keys()
	await s.tap(a)
	await s.tap(b)
	s.finish_chain()
	for id in s.lines:
		if not before.has(id):
			return id
	return ""


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	table.surface.settle_seconds = 0.0

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	var opened: bool = await table.editor.begin_sketch({"fixed": "XY"})
	s = table.editor.session
	print("SMOKE a sketch opens on XY: ", opened and s.is_open())

	# --- a square of four separate lines, the last ending a hair (0.2 mm) from the first line's start
	var a := Vector2(20, 20)
	var b := Vector2(60, 20)
	var c := Vector2(60, 60)
	var d := Vector2(20, 60)
	var l1: String = await line_between({"uv": a}, {"uv": b})
	var b_id: String = s.lines[l1]["b"]
	var l2: String = await line_between({"uv": b, "id": b_id}, {"uv": c})
	var c_id: String = s.lines[l2]["b"]
	var l3: String = await line_between({"uv": c, "id": c_id}, {"uv": d})
	var d_id: String = s.lines[l3]["b"]
	var l4: String = await line_between({"uv": d, "id": d_id}, {"uv": a + Vector2(0, 0.2)})
	var first_start: String = s.lines[l1]["a"]
	var last_end: String = s.lines[l4]["b"]
	print("SMOKE four lines go round, the last ending a hair off the first one's start: two points, 0.2 mm apart, and the profile is open: ", s.lines.size() == 4 and first_start != last_end and s.points[first_start].distance_to(s.points[last_end]) < 0.3 and not s.profile_ok())

	# --- merge them with the Select tool
	s.set_tool("select")
	await s.select({"kind": "point", "id": last_end})
	await s.select({"kind": "point", "id": first_start})
	var menu_ids: Array = s.menu().map(func(o): return o["id"])
	print("SMOKE the two stacked points offer Merge: ", s.merge_offered() and menu_ids.has("merge"))
	var points_before: int = s.points.size()
	var before_export: Dictionary = (await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/export", null))["json"]
	var merged: Dictionary = await s.apply_menu("merge")
	var kept: String = s.lines[l4]["b"]
	print("SMOKE Merge is accepted: one point fewer, the last line now ends on the point the first starts on, one point serves both: ", merged["ok"] and s.points.size() == points_before - 1 and s.lines[l1]["a"] == kept and s.lines[l4]["b"] == kept and not s.points.has(first_start if kept != first_start else last_end))
	print("SMOKE ...the profile is closed (a loop to extrude): ", s.profile_ok() and s.profile_status == "closed_loop" and s.converged)
	print("SMOKE ...the selection is cleared and it is on the undo stack, named merge: ", s.selection.is_empty() and s.undo_label() == "merge")

	# --- undo puts the sketch back in place
	var undone: bool = await s.undo()
	var after_export: Dictionary = (await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/export", null))["json"]
	print("SMOKE undo restores BOTH points under their own ids, and the sketch is open again: ", undone and s.points.has(first_start) and s.points.has(last_end) and s.lines[l4]["b"] == last_end and s.lines[l1]["a"] == first_start and not s.profile_ok())
	print("SMOKE ...and the whole sketch is what it was before the merge (same ids, same entities and constraints): ", str(before_export.get("id", "")) == str(after_export.get("id", "")) and (before_export["points"] as Array).size() == (after_export["points"] as Array).size() and (before_export["entities"] as Array).size() == (after_export["entities"] as Array).size())
	print("SMOKE ...in place: the sketch feature still points at the same sketch: ", table.editor.session.sketch_id == s.sketch_id and s.is_open())

	# --- refusals, in the backend's words
	await s.select({"kind": "point", "id": first_start})
	await s.select({"kind": "point", "id": b_id})
	print("SMOKE two ends of one line are not offered Merge: ", not s.merge_offered())
	# a dimension between the two points (0.5 mm), then Merge on them
	s.selection.clear()
	await s.select({"kind": "point", "id": last_end})
	await s.select({"kind": "point", "id": first_start})
	var said := []
	s.status.connect(func(t): said.append(t))
	var dim: Dictionary = await s.api.call(HTTPClient.METHOD_POST, "/sketch/sketches/" + s.sketch_id + "/constraints", {"type": "distance", "point_a_id": last_end, "point_b_id": first_start, "distance": 0.5})
	await s.refresh(true)
	var refused: Dictionary = await s.merge_selected()
	var undo_before: String = s.undo_label()
	print("SMOKE a dimension held between the two points makes the backend refuse, in its words (not the code), and nothing changes: ", dim["ok"] and not refused["ok"] and str(refused["message"]).contains("dimension") and said.size() >= 1 and s.points.has(last_end) and s.points.has(first_start) and undo_before != "merge")
	print("SMOKE e2e done: ", true)
	quit()
