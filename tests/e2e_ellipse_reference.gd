extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): ELLIPSE EDGES as references (R-F). A 40 x 20 ellipse extruded 8 mm; a new sketch on the XY plane (the bottom rim lies in it): the part's
## references offer the elliptical rim, a pick on it makes ONE pinned reference ellipse of 20 x 10 radii in the real sketch (flagged a reference, quiet), the same pick again makes nothing new,
## and a line started on a point of it solves.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_ellipse_reference.gd  (needs secrets.cfg and a running backend that has the R-F convert)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	var table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	ed.preview_enabled = false
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	table.manager.activate("ellipse")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(0, 10)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 8.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	var refs: RefCounted = ed.part_refs
	print("SMOKE the part's references see the elliptical rim in the sketch plane: ", refs != null and refs.ellipse_edges.size() >= 1, " ", refs.ellipse_edges.size() if refs != null else 0)
	var rim := Vector2(20.0 * cos(0.7), 10.0 * sin(0.7))
	var pick: Dictionary = refs.pick(rim, 2.0, ["point", "line", "circle", "arc", "ellipse"])
	print("SMOKE ...a pick near it is an ellipse entity with an ellipse_edge reference: ", pick.get("kind", "") == "ellipse" and pick["ref"]["kind"] == "ellipse_edge", " ", pick.get("kind"))
	var made: Dictionary = await s.ensure_reference(pick["ref"])
	print("SMOKE ensure_reference makes ONE pinned reference ellipse of 20 x 10 radii in the real sketch: ", made["ok"] and s.ellipses.size() == 1 and s.is_reference(made["id"]), " ", made.get("message", ""))
	if s.ellipses.size() == 1:
		var el: Dictionary = s.ellipses[made["id"]]
		var a: float = s.points[el["ma"]].distance_to(s.points[el["c"]])
		var b: float = s.points[el["mi"]].distance_to(s.points[el["c"]])
		print("SMOKE ...its radii are the part's (20 and 10) and its centre is pinned: ", absf(a - 20.0) < 0.05 and absf(b - 10.0) < 0.05 and s.point_locked.get(el["c"], false), " ", a, " ", b)
	var again: Dictionary = await s.ensure_reference(pick["ref"])
	print("SMOKE the same pick again makes no second ellipse: ", again["ok"] and again["id"] == made["id"] and s.ellipses.size() == 1)
	table.manager.activate("line")
	await s.tap({"uv": Vector2(0, 0)})
	var drawn: Dictionary = await s.tap({"uv": Vector2(30, 5)})
	print("SMOKE a line drawn beside it solves with the pinned ellipse in the sketch (no redundancy): ", drawn["ok"] and s.converged, " dof ", s.dof)
	quit()
