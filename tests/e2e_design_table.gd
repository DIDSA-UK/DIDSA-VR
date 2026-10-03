extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY — never against a shared backend):
## the design table end to end. It builds a small assembly on the backend (a plate part made with the sketch session and
## the feature calls themselves, placed twice in an assembly), loads it into the arena, puts one instance on the table,
## and drives the real editing flow: the part is looked up from its occurrence, a sketch is opened on a real top face
## (checking the plane the backend returns and that the part is turned to lie on it), a circle is drawn and dimensioned
## with a typed radius, extruded (both arena instances change, not just the one on the table), a fillet is applied to a
## picked edge and taken back by Undo, and the part is exported in the native format. Also: an assembly-of-parts is refused.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_design_table.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api
var ed


func req(method: int, path: String, body = null) -> Dictionary:
	return await api.request(method, path, body)


func ok(label: String, r: Dictionary) -> bool:
	if not r["ok"]:
		print("SMOKE FAILED setup ", label, ": ", r["error"])
	return r["ok"]


func face_count(node: MeshInstance3D) -> int:
	var seen := {}
	for id in node.get_meta("face_ids", []):
		seen[int(id)] = true
	return seen.size()


func wait_for(pred: Callable, frames := 600) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func top_face(part: MeshInstance3D) -> Dictionary:
	## The planar face whose outward normal is most nearly +Z (part frame), with the highest centre.
	var best := {}
	var best_z := -INF
	var bodies: Array = part.get_meta("body_ids")
	var seen := {}
	for i in bodies.size():
		var key := "%s:%d" % [bodies[i], int(part.get_meta("face_ids")[i])]
		if seen.has(key):
			continue
		seen[key] = true
		var tris := TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i]))
		var plane := SketchMath.plane_from_face_triangles(tris)
		if not plane.is_empty() and plane["n"].dot(Vector3(0, 0, 1)) > 0.99 and plane["origin"].z > best_z:
			best_z = plane["origin"].z
			best = {"body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i]), "plane": plane}
	return best


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true # the turn to the table is instant (set after main loads: it applies the saved setting)
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	table = main.design_table
	table.configure_backend(str(cfg.get_value("backend", "url")), str(cfg.get_value("backend", "api_key")))
	api = table.api
	ed = table.editor

	# --- build the document
	if not ok("new", await req(HTTPClient.METHOD_POST, "/document/new")):
		quit(); return
	var asm_r := await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "Asm"})
	var plate_r := await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "Plate"})
	if not (ok("asm", asm_r) and ok("plate", plate_r)):
		quit(); return
	var asm_id: String = asm_r["json"]["id"]
	var plate_id: String = plate_r["json"]["id"]
	var sketch := SketchSession.new(Callable(api, "request"))
	sketch.owner_part_id = plate_id
	var made: bool = await sketch.open_sketch({"fixed": "XY"})
	sketch.set_tool("rectangle")
	await sketch.tap({"uv": Vector2(0, 0)})
	await sketch.tap({"uv": Vector2(40, 30)})
	var feats := PartFeatures.new(Callable(api, "request"))
	var extruded: Dictionary = await feats.extrude(plate_id, sketch.feature_id, true, 0.0, 10.0, [])
	print("SMOKE built the plate through the session and the feature calls: ", made and sketch.profile_ok() and extruded["ok"], " ", extruded["error"])
	for occ in [["occ1", [0, 0, 0]], ["occ2", [100, 0, 0]]]:
		await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % asm_id, {"id": occ[0], "resolved_part_id": plate_id,
			"transform": {"translation": occ[1], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
	var glb: Dictionary = await api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % asm_id)
	main._resolved_part_id = asm_id
	main._show_model(glb["bytes"], "", 0.001)
	var nodes: Array = get_nodes_in_group("grabbable_parts")
	print("SMOKE the arena shows two placed instances of the plate: ", glb["ok"] and nodes.size() == 2 and nodes[0].get_meta("owner_part_id") == asm_id)

	# --- looking the part up
	var node: MeshInstance3D = nodes[0]
	var found: String = await ed.resolve_definition(asm_id, str(node.get_meta("occurrence_id")))
	print("SMOKE the part behind an occurrence is found through the owner's occurrences (the glb names only the owner): ", found == plate_id, " ", found)
	var refused: String = await ed.resolve_definition(asm_id, "")
	print("SMOKE an assembly of other parts is refused with a reason: ", refused.begins_with("!") and refused.contains("assembly"), " ", refused)
	var same: Array = await ed.arena_nodes_of(plate_id)
	print("SMOKE every arena node showing the plate is found: ", same.size() == 2)

	# --- seat, then open a sketch on the real top face
	table.open()
	table.seat(node)
	var ready: bool = await wait_for(func() -> bool: return ed.state == "pick_plane")
	print("SMOKE after seating, the editor looks the part up and waits for a plane: ", ready and ed.part_id == plate_id)
	var face := top_face(table.table_copy)
	print("SMOKE the plate's top face is found on the table copy: ", not face.is_empty() and TopologyPick.is_planar_face(table.table_copy, face["body_id"], face["index"]))
	var opened: bool = await ed.begin_sketch({"face": {"body_id": face["body_id"], "index": face["index"]}})
	var plane: Dictionary = ed.session.plane
	print("SMOKE a sketch opens on that face: ", opened and ed.state == "sketch" and ed.session.is_open())
	print("SMOKE ...the backend's plane is the top face (normal +Z, 10 mm up): ", plane["n"].dot(Vector3(0, 0, 1)) > 0.999 and absf(plane["origin"].z - 10.0) < 0.01)
	print("SMOKE ...and my provisional plane from the triangles agrees on the normal: ", plane["n"].dot(face["plane"]["n"]) > 0.999)
	var up: Vector3 = table.pivot.basis * (plane["n"] as Vector3)
	var right: Vector3 = table.pivot.basis * (plane["x"] as Vector3)
	var away: Vector3 = table.pivot.basis * (plane["y"] as Vector3)
	print("SMOKE the part is turned so the plane lies flat on the table (normal up, x right, y away): ", up.is_equal_approx(Vector3.UP) and right.is_equal_approx(Vector3.RIGHT) and away.is_equal_approx(Vector3(0, 0, -1)), " ", up, right, away, " plane x/y/n ", plane["x"], plane["y"], plane["n"])
	print("SMOKE the chosen face is highlighted on the part: ", ed.highlight.pick_nodes().size() == 1)
	print("SMOKE the sheet and the drawing are shown: ", ed.view != null and ed.view.get_child_count() >= 4)

	# --- draw a circle, dimension it with a typed radius
	table.manager.activate("circle")
	var centre_uv := SketchMath.to_sheet(table.table_copy.get_aabb().get_center(), plane)
	await ed.session.tap({"uv": centre_uv, "id": ""})
	var r1: Dictionary = await ed.session.tap({"uv": centre_uv + Vector2(4, 0), "id": ""})
	print("SMOKE a circle is drawn on the sheet through the real sketch API: ", r1["done"] and ed.session.circles.size() == 1 and ed.session.profile_ok())
	table.manager.activate("dimension")
	var circle_id: String = ed.session.circles.keys()[0]
	await ed.session.select({"kind": "circle", "id": circle_id})
	print("SMOKE the Dimension tool offers the circle's radius: ", ed.session.ghosts.size() == 2 and absf(ed.session.ghosts[0]["value"] - 4.0) < 0.01)
	await ed.dimension_typed("radius", "6.5")
	var c: Dictionary = ed.session.circles[circle_id]
	var radius: float = ed.session.points[c["c"]].distance_to(ed.session.points[c["p"]])
	print("SMOKE typing 6.5 on the numeric pad sets the radius to 6.5: ", absf(radius - 6.5) < 0.01, " (", radius, ")")
	await ed.dimension_typed("radius", "oops")
	print("SMOKE ...text that isn't a number is refused: ", table.status() == "That isn't a number.")

	# --- extrude it: both arena instances change, not just the one on the table
	var before_a := node.get_aabb().size.z
	var before_b: float = nodes[1].get_aabb().size.z
	var faces_before := face_count(node)
	table.manager.activate("extrude")
	ed.options["depth"] = 5.0
	ed.options["boss"] = true
	await ed.apply_feature()
	print("SMOKE the extrude is applied: ", ed.feature_stack.size() == 1, " ", table.status())
	print("SMOKE ...the arena node that's on the table grew by 5 mm: ", absf(node.get_aabb().size.z - (before_a + 5.0)) < 0.01, " (", before_a, " -> ", node.get_aabb().size.z, ")")
	print("SMOKE ...and so did the OTHER instance in the arena: ", absf(nodes[1].get_aabb().size.z - (before_b + 5.0)) < 0.01)
	print("SMOKE ...the table copy shows it too, with new faces: ", absf(table.table_copy.get_aabb().size.z - node.get_aabb().size.z) < 0.01 and face_count(node) > faces_before)
	print("SMOKE ...and the editor is back to choosing a plane, the sketch spent: ", ed.state == "pick_plane" and ed.session == null and ed.view == null)
	print("SMOKE ...with a collider on the new mesh so the new faces can be picked: ", table.table_copy.get_children().any(func(ch): return ch is StaticBody3D))

	# --- fillet a picked edge, then take it back
	var faces_pre_fillet := face_count(node)
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "circle":
			edge_index = int(index) # a rim of the boss: a seam line of the cylinder can't be rounded
			break
	table.manager.activate("fillet")
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": TopologyPick.entity_key("edge", body_id, edge_index)}]
	ed.options["radius"] = 1.0
	await ed.apply_feature()
	print("SMOKE a fillet on a picked edge is applied and adds a face: ", ed.feature_stack.size() == 2 and face_count(node) > faces_pre_fillet, " ", table.status())
	await ed.undo()
	print("SMOKE Undo takes the fillet back and the faces return: ", ed.feature_stack.size() == 1 and face_count(node) == faces_pre_fillet)
	var exported: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native?part_id=%s" % plate_id)
	var types: Array = []
	if exported["ok"]:
		for f in exported["json"]["document"]["parts"][0]["features"]:
			types.append(f["type"])
	print("SMOKE the plate in the native export has both sketches and both extrudes, no fillet: ", types.count("sketch") == 2 and types.count("extrude") == 2 and types.count("fillet") == 0, " ", types)

	# --- a cut from a face: into the part
	table.manager.deactivate()
	face = top_face(table.table_copy)
	var again: bool = await ed.begin_sketch({"face": {"body_id": face["body_id"], "index": face["index"]}})
	table.manager.activate("rectangle")
	var c2 := SketchMath.to_sheet(table.table_copy.get_aabb().get_center(), ed.session.plane)
	await ed.session.tap({"uv": c2 + Vector2(-3, -3), "id": ""})
	await ed.session.tap({"uv": c2 + Vector2(3, 3), "id": ""})
	table.manager.activate("extrude")
	ed.options["boss"] = false
	ed.options["depth"] = 2.0
	var distances: Array = ed.extrude_distances()
	var faces_pre_cut := face_count(node)
	await ed.apply_feature()
	print("SMOKE a cut goes into the part (negative along the face normal), targeting the body sketched on: ", again and distances == [0.0, -2.0] and ed.extrude_targets().size() == 1, " ", table.status())
	print("SMOKE ...and it changes the part (a pocket adds faces): ", face_count(node) > faces_pre_cut)

	# --- lifting returns the real node, edited, to the arena
	table.close()
	print("SMOKE closing the table returns the edited part to the arena: ", node.visible and table.seated == null and node.get_aabb().size.z > before_a + 4.0)
	print("SMOKE ...and its instances carry the stale-mates flag, with the Enforce button over the one handed back: ", nodes.all(func(n): return n.get_meta("mates_dirty", false)) and table.enforce_button.is_showing())

	# --- save: a native file the flat app can open, with its extra keys kept, that round-trips
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	main._native_extras = {"hidden_feature_ids": ["flat-app-state"], "section_planes": []}
	var saved_path: String = await main.save_native_snapshot("user://e2e_snapshot.didsa")
	print("SMOKE the session is saved as a native file: ", saved_path == "user://e2e_snapshot.didsa" and FileAccess.file_exists(saved_path))
	var saved = JSON.parse_string(FileAccess.get_file_as_string(saved_path)) if saved_path != "" else null
	var saved_ok: bool = saved is Dictionary
	print("SMOKE ...in the flat app's format (schema 1, a root part, both parts): ", saved_ok and int(saved["schema_version"]) == 1 and saved["document"]["root_part_id"] == asm_id and saved["document"]["parts"].size() == 2)
	print("SMOKE ...keeping the flat app's own extra keys: ", saved_ok and saved.get("hidden_feature_ids") == ["flat-app-state"])
	var saved_features: Array = []
	if saved_ok:
		for p in saved["document"]["parts"]:
			if p["id"] == plate_id:
				saved_features = p["features"].map(func(f): return f["type"])
	print("SMOKE ...with the edits made on the table in it: ", saved_features.count("extrude") == 3 and saved_features.count("sketch") == 3 and saved_features.count("create_plane") == 2 and saved_features.count("fillet") == 0, " ", saved_features)
	var occurrence_count: int = 0
	if saved_ok:
		for p in saved["document"]["parts"]:
			if p["id"] == asm_id:
				occurrence_count = p["occurrences"].size()
	print("SMOKE ...and the assembly's two placed instances: ", occurrence_count == 2)
	await main.open_native_file(saved_path) # VR's own Open path: it must send the file's text as it is, not re-written with floats for integers
	var reopened: Array = get_nodes_in_group("grabbable_parts")
	print("SMOKE opening the saved file in VR loads the edited assembly (both instances): ", main.status_text.begins_with("Opened") and reopened.size() == 2, " ", main.status_text)
	var reexport: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native?part_id=%s" % plate_id)
	var again_types: Array = []
	if reexport["ok"]:
		again_types = reexport["json"]["document"]["parts"][0]["features"].map(func(f): return f["type"])
	print("SMOKE ...with the same features on the part (the file round-trips through the backend): ", again_types == saved_features, " ", again_types)
	var grown := true
	for n in reopened:
		grown = grown and n.get_aabb().size.z > before_a + 4.0
	print("SMOKE ...and the reopened parts have the edited shape: ", grown)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://e2e_snapshot.didsa"))
	quit()
