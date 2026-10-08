extends SceneTree
## Picking the lines and curves of FINISHED sketches (Phase 5.4, scripts/design_table/sketch_picks.gd and the editor's pick_curves state): the
## sketches the part already has are read once, read-only (nothing is made), their lines, circles and arcs are drawn on the part and offered to
## the laser; a pull picks one (lit, in pick order), a second lets it go; a Build row can leave its sketch out; a helper is never offered; a
## flipped sketch is left out; the lines go when curve picking ends; the refs are the backend's SketchEntityRef.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_picks.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	await rig.draw_rectangle()
	var sketch_feature: String = ed.session.feature_id
	var sketch_id: String = ed.session.sketch_id
	fake.sketch_plane = "XY"
	fake.feature_rows["PART_BOX"] = [{"id": sketch_feature, "type": "sketch", "sketch_id": sketch_id, "plane_feature_id": null, "name": "Sketch 1"}]
	await table.build.reload()
	table.manager.deactivate()
	ed.end_sketch()
	await rig.frames(3)
	fake.calls.clear()
	await ed.start_curve_picks()
	await rig.frames(3)
	var made: Array = fake.calls.filter(func(c): return String(c[0]).begins_with("POST") and not String(c[0]).ends_with("solve-and-refresh"))
	print("SMOKE choosing curve picking puts the editor in pick_curves: ", ed.state == "pick_curves")
	print("SMOKE ...the finished sketch is read (solve + export) and nothing is made: ", not rig.calls_to("/export").is_empty() and made.is_empty(), " ", made)
	var picks = ed.sketch_picks
	print("SMOKE ...its four lines are on the part as candidates, in the sketch's plane: ", picks != null and picks.candidates().size() == 4 and picks.candidates().all(func(c): return c["entity_type"] == "line" and c["sketch_feature_id"] == sketch_feature))
	print("SMOKE ...and drawn as one mesh child of the copy: ", picks.get_parent() == table.table_copy and picks.get_node_or_null("SketchCurves") != null)
	var first: Dictionary = picks.candidates()[0]
	var mid: Vector3 = (first["points"][0] + first["points"][1]) * 0.5
	var world_mid: Vector3 = table.table_copy.global_transform * mid
	var hit: Dictionary = picks.nearest(world_mid + Vector3(0, 0.4, 0), Vector3.DOWN, 0.012)
	print("SMOKE a ray down onto the middle of a line finds that line, with its distance: ", hit.get("key", "") == first["key"] and float(hit.get("distance", 0.0)) > 0.0)
	print("SMOKE ...a ray that misses every line finds none: ", picks.nearest(world_mid + Vector3(5, 5, 5), Vector3.DOWN, 0.012).is_empty())
	print("SMOKE ...its ref is the backend's sketch entity ref: ", picks.entity_ref(first) == {"sketch_id": sketch_id, "entity_type": "line", "entity_id": first["entity_id"]})
	# the laser: aim at the line's middle from above (the console tilts the part, so aim along the line's own direction in the world)
	var aim_from: Vector3 = world_mid + (table.table_copy.global_transform.basis * Vector3(0, 0, 1)).normalized() * 0.4
	await rig.aim(aim_from, world_mid)
	print("SMOKE aiming at that line lights it and takes the laser: ", ed.hovering and ed._hover_face.get("kind") == "curve" and ed._hover_face["key"] == first["key"])
	await rig.pull()
	print("SMOKE a pull picks it (lit in the set colour): ", ed.curve_picks.size() == 1 and ed.highlight.set_nodes().size() == 1 and ed.curve_refs() == [picks.entity_ref(first)])
	await rig.pull()
	print("SMOKE a second pull lets it go: ", ed.curve_picks.is_empty() and ed.highlight.set_nodes().is_empty())
	picks.set_included(sketch_feature, false)
	print("SMOKE leaving the sketch out (its Build row) takes its lines away: ", picks.candidates().is_empty())
	picks.set_included(sketch_feature, true)
	print("SMOKE ...and putting it back brings them: ", picks.candidates().size() == 4)
	table.build.select(sketch_feature)
	table.tree.show_tab("build")
	await rig.frames(3)
	var lines_button: Button = _find_button(table.tree._build_rows, "Lines: on")
	print("SMOKE the selected sketch's Build row offers Lines: on while curves are being picked: ", lines_button != null)
	if lines_button != null:
		lines_button.pressed.emit()
		await rig.frames(2)
	print("SMOKE ...pressing it leaves that sketch's lines out, and the button says so: ", picks.candidates().is_empty() and _find_button(table.tree._build_rows, "Lines: off") != null)
	picks.set_included(sketch_feature, true)
	ed.curve_limit = 1
	ed.curve_picks = [first.duplicate()]
	ed._hover_face = picks.candidates()[1].duplicate()
	ed._toggle_curve()
	print("SMOKE with a limit of one a new pick replaces the one before: ", ed.curve_picks.size() == 1 and ed.curve_picks[0]["key"] == picks.candidates()[1]["key"])
	table.manager.activate("fillet")
	await rig.frames(2)
	print("SMOKE leaving curve picking takes the lines off the part and forgets the picks: ", ed.state == "pick_edges" and picks.candidates().is_empty() and ed.curve_picks.is_empty())
	# a sketch that cannot be placed is left out, a reopen of one that can is untouched
	fake.sketch_plane = "XY"
	ed.set_state("pick_plane")
	fake.feature_rows["PART_BOX"][0]["sketch_id"] = ""
	await table.build.reload()
	await ed.start_curve_picks()
	print("SMOKE a sketch row with no sketch is left out, and the user is told there is nothing to pick from: ", ed.sketch_picks.candidates().is_empty() and table.status().contains("no finished sketch"))
	quit()


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null
