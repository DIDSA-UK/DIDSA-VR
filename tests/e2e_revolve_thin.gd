extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): a THIN Revolve of an OPEN
## profile (DIDSA-CAD docs/flutter-testing-feedback-2026-11-11-plan.md item 5, V3). A new part, a sketch on XY with an L-shaped chain of two lines (no closed
## shape) and a vertical CONSTRUCTION line as the axis; the revolve tool takes the sketch (the backend's profile says open_chain), Thin is locked on, 360
## degrees, wall 2 mm away from the axis; the real mesh is a cup with its wall outside the chain (64 mm across, 17 along the axis) and the Build tree
## row says 'thin 2 mm'.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_revolve.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api


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
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	api = table.api
	table.surface.settle_seconds = 0.0
	var ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	s.set_tool("line")
	await s.tap({"uv": Vector2(10, 0)})
	await s.tap({"uv": Vector2(30, 0)})
	await s.tap({"uv": Vector2(30, 15)})
	s.finish_chain()
	await s.tap({"uv": Vector2(0, -5)})
	await s.tap({"uv": Vector2(0, 40)})
	s.finish_chain()
	var axis_line := ""
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if absf(s.points[l["a"]].x) < 0.01 and absf(s.points[l["b"]].x) < 0.01 and absf(s.points[l["b"]].y - s.points[l["a"]].y) > 40.0:
			axis_line = id
	s.selection = [{"kind": "line", "id": axis_line}]
	await s.toggle_construction() # a guide: not part of the chain
	await wait_for(func() -> bool: return s.open_chain_ok())
	print("SMOKE the L chain is the sketch's one open chain (no closed shape) and the axis line is construction: ", axis_line != "" and not s.profile_ok() and s.open_chain_ok(), " status ", s.profile_status)

	table.manager.activate("revolve")
	ed.revolve_axis = axis_line
	var opts: Array = ed.tools["revolve"].options(ed)
	var thin_opt: Dictionary = {}
	for o in opts:
		if o["id"] == "rev_thin":
			thin_opt = o
	print("SMOKE the revolve tool has Thin locked on, with the directions read against the axis: ", thin_opt.get("pressed", false) and thin_opt.get("disabled", false) and opts.any(func(o) -> bool: return o["text"] == "Away from axis"))
	ed.options["boss"] = true
	ed.options["angle"] = 360.0
	ed.options["rev_wall"] = 2.0
	ed.options["rev_dir"] = "outward"
	await ed.apply_feature()
	var done: bool = await wait_for(func() -> bool: return not table.is_blank())
	var size := node.get_aabb().size
	print("SMOKE the real mesh is a thin cup: 64 mm across (the wall is outside the chain, which reaches 30 mm out) and 17 along the axis: ", done and absf(size.x - 64.0) < 1.5 and absf(size.z - 64.0) < 1.5 and absf(size.y - 17.0) < 1.5, " ", size)
	await wait_for(func() -> bool: return table.build.features.size() == 2)
	var b = table.build
	var thin_ok: bool = b.features.size() == 2 and str(b.features[1].get("type")) == "revolve" and b.features[1].get("thickness") != null and absf(float(b.features[1]["thickness"]) - 2.0) < 1e-6
	print("SMOKE the Build tree lists the thin revolve with its wall: ", thin_ok and table.tree._build_rows.find_children("*", "Button", true, false).any(func(x): return x.text.contains("thin 2 mm")))
	quit()
