extends SceneTree
## NEEDS A REAL RENDER (Xvfb) AND A RUNNING BACKEND (secrets.cfg, a throwaway key): the part clipped to the sketch window, in the real pipeline.
##   SKETCH_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/sketch_clip_picture.gd
## A real 60 x 40 x 20 mm part (new part, a rectangle extruded), a sketch on its top face, zoomed 120x about a corner so the part is far bigger than the
## room. Pictures: sketch_clip_on.png (the part cut to the window's box) and sketch_clip_off.png (the same frame with the clip taken off, the part filling
## everything). The test samples a spot well below the window: the part there with the clip off, not with it on; and checks the clip is off again once the sketch ends. Run it, look at the pictures.
## Not in run_all.sh.

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func top_face(part: MeshInstance3D) -> Dictionary:
	var best := {}
	var best_z := -INF
	var bodies: Array = part.get_meta("body_ids")
	var seen := {}
	for i in bodies.size():
		var key := "%s:%d" % [bodies[i], int(part.get_meta("face_ids")[i])]
		if seen.has(key):
			continue
		seen[key] = true
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i])))
		if not plane.is_empty() and plane["n"].dot(Vector3(0, 0, 1)) > 0.99 and plane["origin"].z > best_z:
			best_z = plane["origin"].z
			best = {"kind": "face", "body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i]), "key": key}
	return best


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
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
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
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(60, 40)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	main.view_modes.set_mode(main.view_modes.Mode.SHADED_EDGES)
	await ed.begin_sketch({"face": top_face(node)})
	var s = ed.session
	print("SMOKE a sketch is open and the clip is on, the copy flagged: ", s != null and ed.clip.active and table.table_copy.has_meta("window_clip"))

	table._slab.visible = false
	table._ring.visible = false
	var eye := Camera3D.new()
	eye.fov = 50.0
	main.add_child(eye)
	eye.make_current()
	var copy: Node3D = table.table_copy
	var plane: Dictionary = s.plane
	var window_mid: Vector3 = table.to_global(table.window_anchor)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	var up: Vector3 = (copy.global_transform.basis * (plane["y"] as Vector3)).normalized()

	# zoom 120x about the part's corner (60, 40) so the corner is under the window's middle and the rest of the part is huge around it
	var rot: Basis = table.pivot.basis.orthonormalized()
	var corner_world: Vector3 = copy.global_transform * Vector3(60, 40, 20)
	var factor := 120.0
	var spot: Vector3 = table.pivot.position + table.pivot.basis * (copy.transform * Vector3(60, 40, 20))
	table.apply_pose(spot + (table.pivot.position - spot) * factor - (table.pivot.position - spot) * 0.0, rot, table.user_scale * factor)
	# slide so that the corner is under the window's middle (in the plane)
	var corner_now: Vector3 = copy.global_transform * Vector3(60, 40, 20)
	var slide: Vector3 = window_mid - corner_now
	slide -= normal * normal.dot(slide)
	table.pivot.position += table.to_local(table.to_global(Vector3.ZERO) + slide) - table.to_local(table.to_global(Vector3.ZERO))
	eye.global_position = window_mid + normal * 0.7
	eye.look_at(window_mid, up)
	await create_timer(1.0).timeout
	var dir_out := OS.get_environment("SKETCH_RENDER_DIR")
	var on_shot := root.get_texture().get_image()
	if dir_out != "":
		on_shot.save_png(dir_out.path_join("sketch_clip_on.png"))
	var below_on := on_shot.get_pixel(300, 720) # well below the window's lower edge (the window is the middle 980 x 490 of the 1600 x 800 picture, scaled): part, if unclipped

	# the box in the world: the part's far corner is well outside it
	var far: Vector3 = copy.global_transform * Vector3(0, 0, 0)
	print("SMOKE the zoomed part reaches far beyond the window (the box excludes the part's far corner, includes the window's middle): ", not ed.clip.contains_world(far) and ed.clip.contains_world(window_mid))

	ed.clip.end()
	await create_timer(0.8).timeout
	var off_shot := root.get_texture().get_image()
	if dir_out != "":
		off_shot.save_png(dir_out.path_join("sketch_clip_off.png"))
	var below_off := off_shot.get_pixel(300, 720)
	print("SMOKE below the window the part is cut away (the picture there is not the part's pale face), and the same spot is the part without the clip: ", below_on, " against ", below_off, " ", below_on.r < 0.6 and below_off.r > 0.7)
	# the clip comes back for the next frame (the editor's per-frame update does not restart it: end() is final until the next sketch)
	ed.end_sketch()
	await process_frame
	print("SMOKE ending the sketch leaves the copy unclipped and unflagged: ", not ed.clip.active and not table.table_copy.has_meta("window_clip"))
	quit()
