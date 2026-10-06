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
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	print("SMOKE references on: ", s.references_ok, " ", ed.part_refs.vertices.size(), " corners ", ed.part_refs.edges.size(), " edges")
	table.manager.activate("dimension")
	# light the right-hand edge of the part
	var hit: Dictionary = ed.part_refs.pick(Vector2(30, 0), 2.0, ["line"])
	ed.view.set_reference_hover(hit.get("ref", {}))
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
	if dir_out != "":
		root.get_texture().get_image().save_png(dir_out.path_join("references.png"))
	quit()
