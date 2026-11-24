extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + Mesa llvmpipe). Tree B8: the Assembly Tree's 480 px panel drawn for real while a room is open (rows outside it dimmed, the rows
## inside wearing the rail) and with the new row-hint order on narrow rows. Asserts what the drawn controls carry (dimmed and railed rows, no hint cut off), not how it looks.
## TREE_RENDER_DIR=/some/dir also writes tree_b8_room.png and tree_b8_closed.png. A Mesa software render of the panel's own viewport, not what the headset shows.
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/tree_b8_render.gd  (ci_render.sh)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")

var main
var window
var rooms


class FakeRooms extends Node:
	signal rooms_changed
	var parts: Array = []

	func open_part_ids() -> Array:
		return parts.duplicate()

	func is_open_for(part_id: String) -> bool:
		return parts.has(part_id)

	func is_placing_for(_part_id: String) -> bool:
		return false

	func edit_api():
		return null


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func occ(id: String, part: String, name: String, status: String, children: Array, prefix: Array, suppressed: bool = false) -> Dictionary:
	var node_path: Array = prefix + [id]
	return {
		"occurrence_id": id, "path": node_path, "external_ref": null, "ref_part_id": part, "resolved_part_id": part, "part_name": name, "name_override": null,
		"kind": "assembly" if not children.is_empty() else "part", "fixed": status == "fixed", "hidden": false, "suppressed": suppressed, "color": null,
		"constraint": {"status": status, "dof": 2, "rigid_set": null, "broken_mates": 0, "near_mates": 0},
		"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": children,
	}


func answer(method: int, path: String, _body) -> Dictionary:
	if method == HTTPClient.METHOD_GET and path.begins_with("/parts/R/assembly-tree"):
		return {"ok": true, "json": {
			"part_id": "R", "part_name": "Rig", "kind": "assembly", "feature_count": 0, "status_included": path.contains("status=true"),
			"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
			"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0},
			"children": [
				occ("a1", "A", "Frame", "fully_constrained", [occ("b1", "B", "Bolt M4", "under_constrained", [], ["a1"])], []),
				occ("a2", "A", "Frame", "fully_constrained", [occ("b2", "B", "Bolt M4", "fixed", [], ["a2"])], []),
				occ("c", "C", "Plate left", "under_constrained", [], [], true),
				occ("d", "D", "Drive plate", "over_constrained", [], [], true),
			],
			"truncated": false, "node_count": 6, "max_depth": 32, "max_nodes": 10000, "truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
		}, "error": ""}
	if method == HTTPClient.METHOD_GET and path == "/parts/R":
		return {"ok": true, "json": {"name": "Rig"}, "error": ""}
	return {"ok": false, "json": null, "code": 404, "error": "404"}


func line_for(path: Array):
	return window._row_controls.get(Model.path_key(path))


func clipped(b: Button) -> bool:
	var w: float = b.get_theme_font("font").get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, b.get_theme_font_size("font_size")).x
	var icon_w := (b.icon.get_width() + 4.0) if b.icon != null else 0.0
	return w + icon_w + b.get_theme_stylebox("normal").get_minimum_size().x > b.size.x


func shoot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var dir := OS.get_environment("TREE_RENDER_DIR")
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	window._viewport.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main._resolved_part_id = "R"
	rooms = FakeRooms.new()
	main.room_manager = rooms
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	for i in 30:
		await process_frame
	for p in [["a1"], ["a2"]]:
		Model.find_row(window._tree, p)["expanded"] = true
	window._rebuild_rows()
	for i in 8:
		await process_frame
	var plate = line_for(["c"])
	var drive = line_for(["d"])
	var plate_text: String = (plate.get_child(2) as Button).text if plate != null else ""
	var drive_text: String = (drive.get_child(2) as Button).text if drive != null else ""
	check("(setup) rows drawn; a suppressed row says 'suppressed' ('%s'), a suppressed over-constrained one keeps its problem word first ('%s')" % [plate_text, drive_text], plate_text == "Plate left  · suppressed" and drive_text.begins_with("Drive plate  · over"))
	await shoot("tree_b8_closed")
	rooms.parts = ["A"]
	window._on_rooms_changed()
	for i in 8:
		await process_frame
	var frame1 = line_for(["a1"])
	var bolt2 = line_for(["a2", "b2"])
	check("a room is open: both Frames and their Bolts are full and wear the rail on the drawn controls", frame1 != null and bolt2 != null and frame1.modulate.a > 0.9 and bolt2.modulate.a > 0.9 and (frame1.get_meta("rail") as Control).visible and (bolt2.get_meta("rail") as Control).visible and (frame1.get_meta("rail") as Control).size.x > 1.0)
	check("...the plates beside them are dimmed and have no rail", line_for(["c"]).modulate.a < 0.9 and not (line_for(["c"]).get_meta("rail") as Control).visible and line_for(["d"]).modulate.a < 0.9)
	var cut: Array = window.visible_lines().filter(func(l): return (l.get_child(2) as Button).visible and clipped(l.get_child(2)) and (l.get_child(2) as Button).text.contains("  · "))
	check("no row's hint is cut off in the 480 px panel", cut.is_empty())
	await shoot("tree_b8_room")
	main.queue_free()
	await process_frame
	quit(0)
