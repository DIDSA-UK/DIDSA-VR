extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as tests/tablet_render.gd):
##   TABLE_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/design_table_render.gd
## Puts the real box-and-cylinder fixture on the design table (fake backend), opens a sketch on a face, draws a rectangle and a
## circle, picks a line for Dimension, and renders the console from where a user's eyes would be, saving PNGs
## ($TABLE_RENDER_DIR) so the 3D result — slab, deck, handle, the part turned flat, the sheet, the drawing, the labels — can be
## eyeballed. Checks the picture isn't blank. GL-compatibility render, not the project's mobile renderer: a layout smoke test.

const Fake := preload("res://tests/helpers/fake_cad.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
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
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await process_frame
	var box: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var owner_id := str(box.get_meta("owner_part_id", "ASM"))
	var table = main.design_table
	var fake := Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var pl := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [pl["origin"].x, pl["origin"].y, pl["origin"].z], "normal": [pl["n"].x, pl["n"].y, pl["n"].z],
			"x_axis": [pl["x"].x, pl["x"].y, pl["x"].z], "y_axis": [pl["y"].x, pl["y"].y, pl["y"].z]}
	table.editor.api = fake
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk_box", "plane_feature_id": null, "has_lost_reference": false},
		{"type": "extrude", "id": "body_box", "sketch_feature_id": "sk_box", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 12.0, "target_body_ids": []},
		{"type": "fillet", "id": "fil_box", "edge_refs": [{"body_id": "body_box", "index": 0}], "radius": 2.0},
	]}

	table.tree._tree = [{"id": "", "name": "Pump_Assy", "named": true, "resolved_part_id": owner_id, "expanded": true, "children": [
		{"id": "occ_box", "name": "Housing", "named": true, "resolved_part_id": "PART_BOX", "children": null, "expanded": false},
		{"id": "occ_cyl", "name": "Impeller", "named": true, "resolved_part_id": "PART_CYL", "children": null, "expanded": false}]}]
	var eye := Camera3D.new()
	eye.fov = 75.0
	main.add_child(eye)
	eye.make_current()
	table.open()
	table.tree._rebuild_rows()
	table.seat(box)
	for i in 60:
		await process_frame
		if table.editor.state == "pick_plane":
			break
	var dir := OS.get_environment("TABLE_RENDER_DIR")
	eye.global_position = cam.global_position + Vector3(0.0, 0.0, 0.1)
	eye.look_at(table.global_position + Vector3(0.0, 0.12, 0.0))
	await create_timer(0.6).timeout
	var shot1 := root.get_texture().get_image()
	if dir != "":
		shot1.save_png(dir.path_join("table_1_pick_plane.png"))

	# the Build tab of the tree beside the table, an extrude selected (its action strip under it)
	if dir != "":
		await table.build.reload()
		table.build.select("body_box")
		await create_timer(0.5).timeout
		root.get_texture().get_image().save_png(dir.path_join("table_7_build_tree.png"))
		var tree_pos: Vector3 = table.tree.global_position
		eye.global_position = tree_pos + table.tree.global_transform.basis.z * 0.6
		eye.look_at(tree_pos)
		await create_timer(0.5).timeout
		root.get_texture().get_image().save_png(dir.path_join("table_8_build_tree_close.png"))
		eye.global_position = cam.global_position + Vector3(0.0, 0.0, 0.1)
		eye.look_at(table.global_position + Vector3(0.0, 0.12, 0.0))

	# a face picked: the part turns flat, a rectangle and a circle drawn
	var tris_face := {}
	var bodies: Array = box.get_meta("body_ids")
	for i in bodies.size():
		var key := "%s:%d" % [bodies[i], int(box.get_meta("face_ids")[i])]
		var pl := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(box, str(bodies[i]), int(box.get_meta("face_ids")[i])))
		if not pl.is_empty() and pl["n"].dot(Vector3(0, 0, 1)) > 0.99 and (tris_face.is_empty() or pl["origin"].z > tris_face["plane"]["origin"].z):
			tris_face = {"body_id": str(bodies[i]), "index": int(box.get_meta("face_ids")[i]), "plane": pl}
	await table.editor.begin_sketch({"face": {"body_id": tris_face["body_id"], "index": tris_face["index"]}})
	var ed = table.editor
	var c: Vector2 = ed.view.sheet_centre
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": c + Vector2(-30, -20), "id": ""})
	await ed.session.tap({"uv": c + Vector2(10, 14), "id": ""})
	table.manager.activate("circle")
	await ed.session.tap({"uv": c + Vector2(22, -4), "id": ""})
	await ed.session.tap({"uv": c + Vector2(34, -4), "id": ""})
	table.manager.activate("dimension")
	await ed.session.select({"kind": "line", "id": ed.session.lines.keys()[0]})
	await create_timer(0.3).timeout
	eye.global_position = cam.global_position + Vector3(0.0, 0.0, 0.1)
	eye.look_at(table.global_position + Vector3(0.0, 0.12, 0.0))
	for i in 20:
		await process_frame
	var shot2 := root.get_texture().get_image()
	if dir != "":
		shot2.save_png(dir.path_join("table_2_sketch.png"))
		# the deck up close, as the user reads it
		var deck_world: Vector3 = table._deck_quad.global_position
		eye.global_position = deck_world + table._deck_quad.global_transform.basis.z * 0.55
		eye.look_at(deck_world)
		table.manager.activate("extrude")
		await create_timer(0.4).timeout
		root.get_texture().get_image().save_png(dir.path_join("table_3_deck.png"))

	# handled on the table: moved aside and scaled up with two hands, the table engaged (glowing frame, TABLE ACTIVE chip)
	if dir != "":
		table.apply_pose(Vector3(0.12, 0.26, 0.02), table.pivot.basis.orthonormalized(), 1.4)
		table.set_engaged(true)
		await create_timer(0.4).timeout
		root.get_texture().get_image().save_png(dir.path_join("table_4_engaged_deck.png"))
		eye.global_position = cam.global_position + Vector3(0.0, 0.0, 0.1)
		eye.look_at(table.global_position + Vector3(0.0, 0.12, 0.0))
		await create_timer(0.3).timeout
		root.get_texture().get_image().save_png(dir.path_join("table_5_engaged.png"))

	# the glass slab dragged bigger, a corner bracket lit
	if dir != "":
		table.set_engaged(false)
		table.set_slab_size(Vector2(0.85, 0.55))
		table.resizer._set_hover(3)
		await create_timer(0.4).timeout
		root.get_texture().get_image().save_png(dir.path_join("table_6_glass_resized.png"))

	var lit := 0
	for y in range(0, shot2.get_height(), 8):
		for x in range(0, shot2.get_width(), 8):
			if shot2.get_pixel(x, y).get_luminance() > 0.05:
				lit += 1
	print("SMOKE the console draws something (not a blank picture): ", lit > 300, " (", lit, " lit samples)")
	print("SMOKE it got as far as a drawn sketch to look at: ", ed.session != null and ed.session.shapes.size() == 1 and ed.session.circles.size() == 1)
	quit()
