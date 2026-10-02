extends SceneTree
## Talks to a real backend (LOCAL ONLY, same caveat as e2e_backend.gd): proves the edge / vertex path end to end
## against the real thing - the real glb's topology extras reach the parts, and a CONCENTRIC mate made from a circular
## EDGE on each of two placed parts, and a MEASURE of an edge and a vertex, are accepted by the real backend, which
## resolves the raw SubShapeRef indices this client sends (the very ones DIDSA-CAD's `_topology_extras` exported).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_edges.gd   (secrets.cfg -> a running backend; assembly.didsa)

var main


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg") or not FileAccess.file_exists("res://assembly.didsa"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend) and assembly.didsa")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://secrets.cfg"
	var started := Time.get_ticks_msec()
	root.add_child(main)
	await process_frame
	while Time.get_ticks_msec() - started < 60000 and not main.status_text.begins_with("Loaded "):
		await process_frame
	if not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: model didn't load: ", main.status_text)
		quit(1)
		return
	var parts: Array = []
	for n in get_nodes_in_group("grabbable_parts"):
		if n.get_meta("occurrence_id", "") != "":
			parts.append(n)
	print("SMOKE placed parts: ", parts.size())
	var with_topology := 0
	for p in parts:
		if p.has_meta("topology"):
			with_topology += 1
	print("SMOKE the real backend's glb carries topology on every placed part: ", with_topology == parts.size() and parts.size() >= 2)

	# one circular edge per part
	var circles: Array = []
	for p in parts:
		var found := {}
		for body_id in p.get_meta("topology"):
			var body: Dictionary = p.get_meta("topology")[body_id]
			for idx in body["edge_kinds"]:
				if body["edge_kinds"][idx] == "circle" and found.is_empty():
					found = {"kind": "edge", "body_id": body_id, "index": int(idx), "face_index": 0, "key": "x"}
		print("SMOKE part ", p.name, " circular edge: ", found)
		circles.append(found)
	if circles.size() < 2 or circles[0].is_empty() or circles[1].is_empty():
		print("SMOKE FAILED: need a circular edge on two parts")
		quit(1)
		return

	# ---- MATES: concentric from two circular edges
	var mates = main._mates_tool
	mates.set_active(true)
	mates.try_pick(parts[0], 0, circles[0])
	mates.try_pick(parts[1], 0, circles[1])
	print("SMOKE two edge picks recorded: ", mates.can_create(), " ", mates.picked_labels())
	var refs: Array = mates.build_create_payload()["references"]
	print("SMOKE ...as EDGE SubShapeRefs: ", refs[0]["subshape_ref"]["shape_type"] == "edge" and refs[1]["subshape_ref"]["shape_type"] == "edge")
	mates.mate_type = "concentric"
	var owner: String = mates._picks[0]["owner_part_id"]
	var created: Dictionary = await mates.create_mate()
	print("SMOKE the real backend accepts a CONCENTRIC mate between two circular edges: ", created["ok"], " ", created.get("error", ""))
	await mates.refresh_mates(owner)
	var mate = mates.mates.back() if not mates.mates.is_empty() else null
	print("SMOKE ...and it is listed, type concentric, on edge refs: ", mate != null and mate.get("type") == "concentric")
	if mate != null:
		await mates.delete_mate(owner, mate.get("id", ""))
	mates.set_active(false)

	# ---- MEASURE: edge to edge, then vertex to vertex
	var measure = main._measure_tool
	measure.set_active(true)
	await measure.try_pick(parts[0], 0, circles[0])
	await measure.try_pick(parts[1], 0, circles[1])
	print("SMOKE ...the backend reports the distance between the two circles: ", measure.result.get("distance") != null, " (", measure.result.get("distance"), ")")
	measure.clear_picks()
	var vertices: Array = []
	for p in parts:
		var v := {}
		for body_id in p.get_meta("topology"):
			var body: Dictionary = p.get_meta("topology")[body_id]
			for idx in body["vertices"]:
				if v.is_empty():
					v = {"kind": "vertex", "body_id": body_id, "index": int(idx), "face_index": 0, "key": "y"}
		vertices.append(v)
	await measure.try_pick(parts[0], 0, vertices[0])
	await measure.try_pick(parts[1], 0, vertices[1])
	print("SMOKE ...the backend reports the distance between the two corners: ", measure.result.get("distance") != null, " (", measure.result.get("distance"), ")")
	print("SMOKE PASSED (read the lines above)")
	quit()
