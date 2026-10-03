extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): Shell and Mirror on the
## design table against the real feature schemas. A new part, a 60 x 40 rectangle extruded 20 mm; Shell opens its top face with a 2 mm
## wall (the real mesh gets more faces, same outside size), the Build tree lists it with its thickness and its Edit changes the wall;
## Mirror across the YZ plane doubles the part's width (two bodies, keep separate) and Undo takes it back.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_features.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func face_total(m: Mesh) -> int:
	return (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if m != null and m.get_surface_count() > 0 else 0


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
	var solid_faces := face_total(node.mesh)
	var outside := node.get_aabb().size

	# --- Shell: open the top face, 2 mm wall inward
	table.manager.activate("shell")
	var top := top_face(node)
	ed.faces = [top]
	ed.options["thickness"] = 2.0
	ed.options["shell_direction"] = "inward"
	await ed.apply_feature()
	var hollow: bool = await wait_for(func() -> bool: return face_total(node.mesh) > solid_faces)
	print("SMOKE Shell opens the top face and hollows the box on the real backend: more triangles, the outside the same size (60 x 40 x 20): ", hollow and node.get_aabb().size.is_equal_approx(outside) or (hollow and absf(node.get_aabb().size.z - 20.0) < 0.5), " ", node.get_aabb().size)
	await wait_for(func() -> bool: return table.build.features.size() == 3)
	var b = table.build
	var row: Dictionary = b.features[2] if b.features.size() == 3 else {}
	print("SMOKE the Build tree lists the shell with its wall and the opened face: ", b.names == ["Sketch 1", "Extrude 1", "Shell 1"] and str(row.get("type")) == "shell" and absf(float(row.get("thickness", 0.0)) - 2.0) < 0.001 and (row.get("faces_to_remove", []) as Array).size() == 1 and table.tree._build_rows.find_children("*", "Button", true, false).any(func(x): return x.text.contains("2 mm, 1 face(s) open")))
	var faces_before := face_total(node.mesh)
	await b.edit_typed(str(row["id"]), "4")
	await wait_for(func() -> bool: return absf(float(b.features[2].get("thickness", 0.0)) - 4.0) < 0.001)
	print("SMOKE Edit changes the wall to 4 mm on the backend: ", absf(float(b.features[2].get("thickness", 0.0)) - 4.0) < 0.001)
	table.manager.deactivate()

	# --- Mirror across YZ
	var width_before := node.get_aabb().size.x
	table.manager.activate("mirror")
	var feature_count: int = b.features.size()
	await ed.mirror_across({"fixed": "YZ"})
	var wider: bool = await wait_for(func() -> bool: return node.get_aabb().size.x > width_before * 1.8)
	print("SMOKE Mirror across the YZ plane doubles the width of the part on the real backend (two bodies, kept separate): ", wider, " ", width_before, " -> ", node.get_aabb().size.x)
	await wait_for(func() -> bool: return b.features.size() == feature_count + 1)
	print("SMOKE the Build tree lists it: ", b.features.back()["type"] == "mirror" and b.names.back() == "Mirror 1" and table.tree._build_rows.find_children("*", "Button", true, false).any(func(x): return x.text.contains("across YZ plane")))
	await ed.undo()
	var back: bool = await wait_for(func() -> bool: return absf(node.get_aabb().size.x - width_before) < 0.5)
	print("SMOKE Undo takes the mirror back: ", back)
	quit()
