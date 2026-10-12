extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): Phase 7.3's ways to make a plane, against the real feature schemas
## and the real planes the backend computes. A 60 x 40 x 20 box. Middle between XY (z = 0) and a plane made at z = 30 is the plane z = 15; Through a corner (parallel to XY, the corner
## (60, 40, 20)) is z = 20; To edge (the vertical edge at (0, 0), the corner (0, 40, 20)) is square to Z at z = 20; 3 corners (0,0,0), (60,0,0), (0,0,20) is the plane y = 0.
## A sketch on a plane made one of these ways takes a rectangle that extrudes (as a new body, so the volume goes up whichever way the plane faces).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_plane_types.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func total(ed) -> float:
	var res: Dictionary = await ed.api.request(HTTPClient.METHOD_GET, "/document/parts/%s/mass-properties" % ed.part_id)
	var t := 0.0
	if bool(res.get("ok", false)):
		for v in (res["json"]["body_volumes"] as Dictionary).values():
			t += float(v)
	return t


func rect(ed, a: Vector2, b: Vector2) -> void:
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": a})
	await ed.session.tap({"uv": b})


func vertex_at(node: MeshInstance3D, p: Vector3) -> Dictionary:
	var topo: Dictionary = node.get_meta("topology")
	for body_id in topo:
		var vertices: Dictionary = topo[body_id]["vertices"]
		for index in vertices:
			if (vertices[index] as Vector3).distance_to(p) < 0.01:
				return {"kind": "vertex", "body_id": str(body_id), "index": int(index), "key": TopologyPick.entity_key("vertex", str(body_id), int(index))}
	return {}


func vertical_edge_at(node: MeshInstance3D, x: float, y: float) -> Dictionary:
	var topo: Dictionary = node.get_meta("topology")
	for body_id in topo:
		var edges: Dictionary = topo[body_id]["edges"]
		for index in edges:
			var pts: PackedVector3Array = edges[index]
			if pts.size() >= 2 and absf(pts[0].x - x) < 0.01 and absf(pts[0].y - y) < 0.01 and absf(pts[pts.size() - 1].x - x) < 0.01 and absf(pts[pts.size() - 1].y - y) < 0.01 and absf(pts[0].z - pts[pts.size() - 1].z) > 1.0:
				return {"kind": "edge", "body_id": str(body_id), "index": int(index), "key": TopologyPick.entity_key("edge", str(body_id), int(index))}
	return {}


func last_plane(ed) -> Dictionary:
	await table.build.reload()
	var rows: Array = table.build.features.filter(func(f): return str(f.get("type")) == "create_plane")
	return rows.back() if not rows.is_empty() else {}


func vec(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


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
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	ed.preview_enabled = false
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	await rect(ed, Vector2(0, 0), Vector2(60, 40))
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var b = table.build

	# --- an ordinary offset plane first (z = 30), to have a made plane to take the middle with
	table.manager.activate("create_plane")
	ed._hover_plane = "XY"
	await ed._pick_plane()
	ed.option_typed("plane_offset", "30")
	await ed.apply_feature()
	var offset_row := await last_plane(ed)
	var offset_id := str(offset_row.get("id", ""))
	print("SMOKE The offset plane is still made as before (z = 30): ", offset_id != "" and absf(vec(offset_row["origin"]).z - 30.0) < 0.01, " ", offset_row.get("origin"))

	# --- Middle: XY and the made plane
	table.manager.activate("create_plane")
	await ed.on_option("pl_m_midplane")
	ed._hover_plane = "XY"
	await ed._pick_plane()
	ed._hover_plane = "plane:" + offset_id
	await ed._pick_plane()
	await ed.apply_feature()
	var mid := await last_plane(ed)
	print("SMOKE Middle between XY and the plane at z = 30 is the plane z = 15 on the real backend: ", str(mid.get("plane_type")) == "midplane" and absf(vec(mid["origin"]).z - 15.0) < 0.01 and absf(absf(vec(mid["normal"]).z) - 1.0) < 0.001, " ", mid.get("origin"), " ", mid.get("normal"))

	# --- On corner: parallel to XY through the corner (60, 40, 20)
	table.manager.activate("create_plane")
	await ed.on_option("pl_m_vertex")
	ed._hover_plane = "XY"
	await ed._pick_plane()
	ed.vertices = [vertex_at(node, Vector3(60, 40, 20))]
	await ed.apply_feature()
	var through := await last_plane(ed)
	print("SMOKE On corner (parallel to XY through (60, 40, 20)) is the plane z = 20: ", str(through.get("plane_type")) == "parallel_to_face_through_vertex" and absf(vec(through["origin"]).z - 20.0) < 0.01 and absf(absf(vec(through["normal"]).z) - 1.0) < 0.001, " ", through.get("origin"), " ", through.get("normal"))

	# --- To edge: square to the vertical edge at (0, 0), through the corner (0, 40, 20)
	table.manager.activate("create_plane")
	await ed.on_option("pl_m_edge")
	ed.edges = [vertical_edge_at(node, 0, 0)]
	ed.vertices = [vertex_at(node, Vector3(0, 40, 20))]
	await ed.apply_feature()
	var normal_row := await last_plane(ed)
	print("SMOKE To edge (square to the vertical edge, through (0, 40, 20)) is the plane z = 20: ", str(normal_row.get("plane_type")) == "normal_to_edge_through_vertex" and absf(vec(normal_row["origin"]).z - 20.0) < 0.01 and absf(absf(vec(normal_row["normal"]).z) - 1.0) < 0.001, " ", normal_row.get("origin"), " ", normal_row.get("normal"))

	# --- 3 corners: (0,0,0), (60,0,0), (0,0,20) is the plane y = 0
	table.manager.activate("create_plane")
	await ed.on_option("pl_m_points")
	ed.vertices = [vertex_at(node, Vector3(0, 0, 0)), vertex_at(node, Vector3(60, 0, 0)), vertex_at(node, Vector3(0, 0, 20))]
	await ed.apply_feature()
	var three := await last_plane(ed)
	print("SMOKE 3 corners (0,0,0), (60,0,0), (0,0,20) is the plane y = 0 (normal along Y): ", str(three.get("plane_type")) == "three_points" and absf(vec(three["origin"]).y) < 0.01 and absf(absf(vec(three["normal"]).y) - 1.0) < 0.001, " ", three.get("origin"), " ", three.get("normal"))
	table.manager.deactivate()

	# --- A sketch on the 3-corner plane takes a rectangle that extrudes (as a new body)
	var before := await total(ed)
	ed.set_state("pick_plane")
	ed._hover_plane = "plane:" + str(three["id"])
	await ed._pick_plane()
	await wait_for(func() -> bool: return ed.state == "sketch")
	await rect(ed, Vector2(10, 5), Vector2(20, 15))
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["new_body"] = true
	ed.options["depth"] = 5.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return table.build.features.size() >= 8 or not ed._preview_running, 60)
	var after := await total(ed)
	for i in 20: # (the extrude may still be settling)
		if absf(after - before) > 100.0:
			break
		await process_frame
		after = await total(ed)
	print("SMOKE A sketch on it takes a 10 x 10 rectangle and a 5 mm extrude (a new body, 500 mm3 more): ", absf(after - before - 500.0) < 5.0, " ", before, " -> ", after)
	ed.options["new_body"] = false
	quit()
