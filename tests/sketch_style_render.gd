extends SceneTree
## NEEDS A REAL RENDER (Xvfb) AND A RUNNING BACKEND (secrets.cfg, a throwaway key): how a sketch LOOKS.
##   SKETCH_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/sketch_style_render.gd
## Draws a rectangle, a hexagon, a circle, an arc, a slot and two lines on the real backend, adds each kind of dimension (horizontal, vertical,
## radius, linear, angle) and leaves one candidate (yellow) showing, then renders the sheet face-on and saves a PNG: object lines heavy and
## solid, construction lines thin and chained, centre marks, extension lines, dimension lines with arrowheads and the values along them.
## Run it, look at the picture. Not in run_all.sh.

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")


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
	var origin_uv := Vector2.ZERO

	s.set_tool("rectangle")
	await s.tap({"uv": Vector2(-170, -60)})
	await s.tap({"uv": Vector2(-90, 40)})
	s.set_tool("polygon")
	s.polygon_sides = 6
	await s.tap({"uv": Vector2(-20, -10)})
	await s.tap({"uv": Vector2(20, -10)})
	s.set_tool("circle")
	await s.tap({"uv": Vector2(90, -10)})
	await s.tap({"uv": Vector2(115, -10)})
	s.set_tool("arc")
	await s.tap({"uv": Vector2(150, -50)})
	await s.tap({"uv": Vector2(175, -50)})
	await s.tap({"uv": Vector2(150, -25)})
	s.set_tool("line")
	await s.tap({"uv": Vector2(20, 60)})
	await s.tap({"uv": Vector2(90, 60)})
	s.finish_chain()
	await s.tap({"uv": Vector2(20, 60)})
	await s.tap({"uv": Vector2(60, 100)})
	s.finish_chain()

	# dimensions of each kind
	var rect_lines: Array = []
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if not l["construction"]:
			var a: Vector2 = s.points[l["a"]]
			var b: Vector2 = s.points[l["b"]]
			if a.x <= -89.0 and b.x <= -89.0 and a.x >= -171.0 and b.x >= -171.0 and a.y < 41.0 and b.y < 41.0 and a.y > -61.0 and b.y > -61.0:
				rect_lines.append(id)
	var corner_points: Array = []
	for id in s.points:
		var p: Vector2 = s.points[id]
		if p.is_equal_approx(Vector2(-170, -60)) or p.is_equal_approx(Vector2(-90, -60)) or p.is_equal_approx(Vector2(-90, 40)):
			corner_points.append(id)
	if corner_points.size() == 3:
		var pts := {}
		for id in corner_points:
			pts[s.points[id].snapped(Vector2(0.01, 0.01))] = id
		var bl: String = pts[Vector2(-170, -60)]
		var br: String = pts[Vector2(-90, -60)]
		var tr: String = pts[Vector2(-90, 40)]
		await dimension(s, [{"kind": "point", "id": bl}, {"kind": "point", "id": br}], "horizontal")
		await dimension(s, [{"kind": "point", "id": br}, {"kind": "point", "id": tr}], "vertical")
	var circle_id: String = s.circles.keys()[0]
	await dimension(s, [{"kind": "circle", "id": circle_id}], "radius")
	var tail: Array = s.lines.keys().slice(-2)
	await dimension(s, [{"kind": "line", "id": tail[0]}, {"kind": "line", "id": tail[1]}], "angle")
	await dimension(s, [{"kind": "line", "id": tail[0]}], "length")
	s.set_tool("slot")
	await s.tap({"uv": Vector2(-130, 75)})
	await s.tap({"uv": Vector2(-60, 75)})
	await s.tap({"uv": Vector2(-95, 87)})
	# leave a candidate showing: pick the arc for its radius / diameter
	s.set_tool("select")
	await s.select({"kind": "arc", "id": s.arcs.keys()[0]})
	await wait_for(func() -> bool: return not s.ghosts.is_empty())
	print("SMOKE the sketch has ", s.lines.size(), " lines, ", s.circles.size(), " circle, ", s.arcs.size(), " arc, ", s.dimension_items().size(), " drawn dimensions and ", s.ghosts.size(), " candidates")

	table.apply_pose(Vector3(0.0, 0.26, 0.0), table.pivot.basis.orthonormalized(), 1.0)
	table._slab.visible = false # (so the slab does not hide the sheet's lower part from this camera)
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
	var dir_out := OS.get_environment("SKETCH_RENDER_DIR")
	for distance in [0.62]:
		eye.global_position = mid + normal * distance
		eye.look_at(mid, up)
		await create_timer(0.8).timeout
		var img := root.get_texture().get_image()
		if dir_out != "":
			img.save_png(dir_out.path_join("sketch_style.png"))
		var lit := 0
		for y in range(0, img.get_height(), 8):
			for x in range(0, img.get_width(), 8):
				var c := img.get_pixel(x, y)
				if c.r + c.g + c.b > 0.35:
					lit += 1
		print("SMOKE the picture is not blank: ", lit > 200, " ", lit)
	quit()
