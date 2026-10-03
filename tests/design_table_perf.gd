extends SceneTree
## What the design table costs per frame in SCRIPT time, measured on whatever machine runs this (headless: no GPU, so it says nothing
## about rendering). The repo's one on-device number is that a Quest 3 runs GDScript about 2.5-3.7x slower than a desktop, and its rule is
## "no more than about 1.5 ms p95 of added script work per frame" (docs/local-retraction-benchmark.md). So this prints the desktop cost,
## times 3.7, against 1.5 ms. Measures: the table's and editor's per-frame work with the laser on a sketch of 150 entities (the snap
## search is the one thing that grows with the sketch), the snap search on its own, and the cost of rebuilding the sketch drawing (which
## happens when the sketch CHANGES, not per frame). Not in run_all.sh (timings); the asserts are generous.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_perf.gd

const Fake := preload("res://tests/helpers/fake_cad.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const Snap := preload("res://scripts/design_table/snap_resolver.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const QUEST_FACTOR := 3.7
const BUDGET_MS := 1.5


func mean_us(callable: Callable, runs: int) -> float:
	var t0 := Time.get_ticks_usec()
	for i in runs:
		callable.call()
	return float(Time.get_ticks_usec() - t0) / float(runs)


func _initialize() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	var r: XRController3D = origin.get_node("RightController")
	r.position = Vector3(1.0, 1.5, 1.0)
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await process_frame
	var box: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		p.set_meta("owner_part_id", "ASM")
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var table = main.design_table
	var fake := Fake.new()
	fake.occurrences = {"ASM": [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var pl := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [pl["origin"].x, pl["origin"].y, pl["origin"].z], "normal": [pl["n"].x, pl["n"].y, pl["n"].z],
			"x_axis": [pl["x"].x, pl["x"].y, pl["x"].z], "y_axis": [pl["y"].x, pl["y"].y, pl["y"].z]}
	table.editor.api = fake
	table.open()
	table.seat(box)
	for i in 100:
		await process_frame
		if table.editor.state == "pick_plane":
			break
	var ed = table.editor

	# 1. the table with a part on it and no sketch: the laser on the part (a physics ray each frame)
	var pivot_world: Vector3 = table.pivot.global_position
	r.global_transform = Transform3D(Basis.looking_at((pivot_world - Vector3(0, 1.8, 0.4)).normalized(), Vector3.UP), Vector3(0, 1.8, 0.4))
	for i in 3:
		await physics_frame
	var idle_us := mean_us(func() -> void:
		r.set_meta("ui_hover", false) # as controller.gd does at the start of every real frame
		table._process(0.011)
		ed._process(0.011), 300)

	# 2. a sketch of 150 entities, the laser on the sheet
	var face_plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, str(box.get_meta("body_ids")[0]), int(box.get_meta("face_ids")[0])))
	await ed.begin_sketch({"face": {"body_id": str(box.get_meta("body_ids")[0]), "index": int(box.get_meta("face_ids")[0])}})
	var s = ed.session
	for i in 150:
		var a := "pa%d" % i
		var b := "pb%d" % i
		s.points[a] = Vector2(i * 0.6, (i % 7) * 3.0)
		s.points[b] = Vector2(i * 0.6 + 4.0, (i % 5) * 3.0 + 6.0)
		s.lines["ln%d" % i] = {"a": a, "b": b, "construction": false}
	table.manager.activate("line")
	ed._refresh_view()
	var centre: Vector2 = ed.view.sheet_centre
	var world: Vector3 = table.table_copy.global_transform * SketchMath.from_sheet(centre + Vector2(20, 10), s.plane)
	var normal: Vector3 = (table.table_copy.global_transform.basis * (s.plane["n"] as Vector3)).normalized()
	r.global_transform = Transform3D(Basis.looking_at(-normal, Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT), world + normal * 0.45)
	for i in 3:
		await physics_frame
	var counter := {"hovered": 0} # a dictionary: a lambda copies a captured number, it can't change the original
	var sketch_us := mean_us(func() -> void:
		r.set_meta("ui_hover", false)
		table._process(0.011)
		ed._process(0.011)
		if ed.hovering:
			counter["hovered"] += 1, 300)
	var hovering: bool = counter["hovered"] == 300

	# 3. the snap search alone
	var snap_us := mean_us(func() -> void: Snap.resolve(centre + Vector2(20, 10), s, 4.0, true, ed._sheet_vertices, null), 300)

	# 4. rebuilding the drawing (when the sketch changes)
	var rebuild_us := mean_us(func() -> void: ed.view.rebuild(s, [], {}), 20)

	var idle_ms := idle_us / 1000.0
	var sketch_ms := sketch_us / 1000.0
	print("SMOKE per-frame script time, part on the table, laser on it (desktop): %.3f ms  -> Quest 3 estimate %.2f ms of %.1f" % [idle_ms, idle_ms * QUEST_FACTOR, BUDGET_MS])
	print("SMOKE per-frame script time, 150-entity sketch with the laser on the sheet (desktop): %.3f ms  -> Quest 3 estimate %.2f ms of %.1f" % [sketch_ms, sketch_ms * QUEST_FACTOR, BUDGET_MS])
	print("SMOKE ...of which the snap search over 300 points / 150 lines: %.3f ms" % (snap_us / 1000.0))
	print("SMOKE rebuilding the drawing mesh for 150 lines + 300 points (only when the sketch changes): %.2f ms" % (rebuild_us / 1000.0))
	print("SMOKE the laser was really on the sheet for the measurement: ", hovering)
	print("SMOKE inside the repo's per-frame rule even at the Quest 3 factor: ", sketch_ms * QUEST_FACTOR < BUDGET_MS)
	var meshes: int = table.find_children("*", "MeshInstance3D", true, false).size()
	print("SMOKE the console and its sketch are %d mesh nodes (slab, 4 frame bars, ring, handle + halo, deck quad, sheet, drawing, preview, cursor, plane squares)" % meshes)
	var viewports: Array = table.find_children("*", "SubViewport", true, false)
	print("SMOKE SubViewports under the table: %d  (%s)" % [viewports.size(), ", ".join(viewports.map(func(v): return "%dx%d" % [v.size.x, v.size.y]))])
	quit()
