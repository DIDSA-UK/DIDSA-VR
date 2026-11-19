extends SceneTree
## NEEDS A REAL RENDER (Xvfb) AND A RUNNING BACKEND: how the part's own corners and edges look under a sketch (the quiet reference lines, a lit corner and a lit edge).
##   SKETCH_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/references_render.gd
## Not in run_all.sh.

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")


func wait_for(pred: Callable, frames := 600) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func dimension(s, entities: Array, key: String) -> void:
	## Picks the entities with the Dimension tool and confirms the candidate `key` at the value it already has (so the drawing does not move).
	s.set_tool("dimension")
	for e in entities:
		await s.select(e)
	for g in s.ghosts:
		if g["key"] == key:
			var r: Dictionary = await s.confirm_ghost(key, float(g["value"]))
			return


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend")
		quit()
		return
	DisplayServer.window_set_size(Vector2i(1600, 800))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	cam.position = Vector3(0, 1.6, 0)
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	var table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	s.set_tool("rectangle")
	await s.tap({"uv": Vector2(-30, -20)})
	await s.tap({"uv": Vector2(30, 20)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var node: MeshInstance3D = table.seated
	# a hole and a notch so there are more edges than a box has
	await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	table.manager.activate("circle")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(8, 0)})
	table.manager.activate("extrude")
	ed.options["boss"] = false
	ed.options["flip"] = true # a cut goes the other way from a boss: down into the part from the plane it was sketched on, which here is the part's own base, so flip it up into it
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	ed.options["flip"] = false
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	print("SMOKE references on: ", s.references_ok, " ", ed.part_refs.vertices.size(), " corners ", ed.part_refs.edges.size(), " edges")
	table.manager.activate("dimension")
	# a silent reference dimension: the hole's centre to the part's right-hand edge, both picked as the part's own geometry (the sketch makes the pinned
	# helpers; none of them is drawn as sketch geometry)
	var hit: Dictionary = ed.part_refs.pick(Vector2(30, 0), 2.0, ["line"])
	var centre_pick: Dictionary = ed.part_refs.pick(Vector2(0.5, 0.5), 3.0, ["point"])
	await dimension(s, [centre_pick, hit], "perpendicular")
	var helper_lines: Array = s.lines.keys().filter(func(id): return s.is_reference(id))
	print("SMOKE the dimension made reference helpers (the edge as a pinned line, the hole's centre), none selectable: ", not helper_lines.is_empty() and s.nearest_entity(Vector2(30, 0), 1.0, ["line"]).is_empty() and s.reference_ids.size() >= 3, " ", s.reference_ids.size())
	print("SMOKE ...and the dimension is a reference one, in brackets (no constraint sent to the backend for it): ", s.dimension_items().filter(func(i): return i.get("driven", false)).size() == 1)
	ed.view.set_reference_hover({})
	table.apply_pose(table.pivot.position, table.pivot.basis.orthonormalized(), 1.0)
	table._slab.visible = false
	table._ring.visible = false
	var eye := Camera3D.new()
	eye.fov = 50.0
	main.add_child(eye)
	eye.make_current()
	var copy: Node3D = table.table_copy
	var plane: Dictionary = s.plane
	var mid: Vector3 = copy.global_transform * (plane["origin"] as Vector3)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	var up: Vector3 = (copy.global_transform.basis * (plane["y"] as Vector3)).normalized()
	eye.global_position = mid + normal * 0.62
	eye.look_at(mid, up)
	await create_timer(0.8).timeout
	var dir_out := OS.get_environment("SKETCH_RENDER_DIR")
	var shot := root.get_texture().get_image()
	if dir_out != "":
		shot.save_png(dir_out.path_join("references.png"))
	# the helper line lies exactly on the part's edge: where it is, the picture shows the quiet reference blue, not the heavy object line or the chained construction line
	var on_edge: Vector2 = eye.unproject_position(copy.global_transform * SketchMath.from_sheet(Vector2(30, 5), plane)) * (Vector2(shot.get_size()) / root.get_visible_rect().size) # the saved picture is the window's size, not the viewport's
	var best_blue := 0.0
	var seen_object := false
	for dx in range(-8, 9):
		for dy in range(-8, 9):
			var c := shot.get_pixel(clampi(int(on_edge.x) + dx, 0, shot.get_width() - 1), clampi(int(on_edge.y) + dy, 0, shot.get_height() - 1))
			best_blue = maxf(best_blue, c.b - c.r)
			if c.r > 0.9 and c.g < 0.5: # the warning colour of a lit / selected sketch line
				seen_object = true
	var seen_blue: bool = best_blue > 0.15
	print("SMOKE the part's edge under the helper is drawn in the quiet reference blue and no sketch line of the helper's own is drawn over it: ", seen_blue and not seen_object)
	quit()
