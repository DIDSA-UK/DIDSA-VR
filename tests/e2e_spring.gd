extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the SPRING tool and a varying-pitch HELIX (DIDSA-CAD's Spring feature and pitch_points).
## Spring: the bug report's spring (10 mm mean diameter, 0.3 mm wire, 20 mm long, 10 active coils, closed and ground both ends) is made by the tool
## and comes back as a row whose working pitch the backend worked out ((20 - 2 x 0.3) / 9.5), and as a body in the part's mesh; Edit > free length 25
## > Apply PATCHes it; a free length the coils can't reach is refused in the backend's words (the solid length).
## Helix: Pitch: varies with 1 mm at the start and 3 mm at 10 mm makes a curve row with those pitch points, 5 ln 3 turns.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_spring.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func fresh_part() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")


func rows_of(ed, type: String) -> Array:
	return ((await ed.features.list_features(ed.part_id))["features"] as Array).filter(func(f): return str(f.get("type", "")) == type)


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

	# --- Spring
	await fresh_part()
	table.manager.activate("spring")
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	ed.option_typed("s_wire", "0.3")
	ed.option_typed("s_coils", "10")
	await ed.apply_feature()
	var springs: Array = await rows_of(ed, "spring")
	var row: Dictionary = springs[0] if not springs.is_empty() else {}
	var pitch := (20.0 - 2.0 * 0.3) / 9.5
	print("SMOKE Apply makes the bug report's spring (0.3 mm wire, ground ends) and the backend works its pitch out: ", not row.is_empty() and absf(float(row.get("wire_diameter", 0.0)) - 0.3) < 1e-9 and str(row.get("start_end", "")) == "closed_ground" and absf(float(row.get("active_pitch", 0.0)) - pitch) < 1e-6 and absf(float(row.get("total_coils", 0.0)) - 12.0) < 1e-9, " ", row.get("active_pitch"), " ", row.get("total_coils"))
	print("SMOKE ...its Build row reads it: ", BuildTree.summary(springs, 0) == "D 10 x 0.3 wire, 20 long, 10 coils, closed, ground / closed, ground", " ", BuildTree.summary(springs, 0))
	var spring_id: String = str(row.get("id", ""))
	await table.build.reload()
	await ed.begin_tool_edit(spring_id)
	ed.option_typed("s_length", "25")
	await ed.apply_feature()
	springs = await rows_of(ed, "spring")
	row = springs[0] if not springs.is_empty() else {}
	print("SMOKE Edit > free length 25 > Apply PATCHes the spring (pitch (25 - 0.6) / 9.5): ", absf(float(row.get("free_length", 0.0)) - 25.0) < 1e-9 and absf(float(row.get("active_pitch", 0.0)) - (25.0 - 0.6) / 9.5) < 1e-6, " ", row.get("active_pitch"))
	var refused: Dictionary = await ed.features.update_feature(ed.part_id, "spring", spring_id, {"free_length": 2.0})
	print("SMOKE a free length the coils can't reach is refused in the backend's words (the solid length): ", not bool(refused["ok"]) and str(refused["error"]).contains("solid"), " ", refused["error"])
	table.manager.deactivate()
	await process_frame

	# --- Varying-pitch helix
	await fresh_part()
	table.manager.activate("helix")
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var tool = ed.tools["helix"]
	await ed.on_option("h_pitch_mode")
	tool.type_value(ed, "h_ppitch_0", "1")
	tool.type_value(ed, "h_at_1", "10")
	tool.type_value(ed, "h_ppitch_1", "3")
	await ed.apply_feature()
	var curves: Array = await rows_of(ed, "curve")
	var curve: Dictionary = curves[0] if not curves.is_empty() else {}
	print("SMOKE Pitch: varies (1 at the start, 3 at 10 mm) makes a curve with those pitch points, 10 mm tall, 5 ln 3 turns: ", not curve.is_empty() and curve.get("pitch_points") == [{"at": 0.0, "pitch": 1.0}, {"at": 10.0, "pitch": 3.0}] and (curve.get("segments", []) as Array).is_empty() and absf(float(curve.get("total_height", 0.0)) - 10.0) < 1e-9 and absf(float(curve.get("total_turns", 0.0)) - 5.0 * log(3.0)) < 1e-6, " ", curve.get("pitch_points"), " ", curve.get("total_turns"))
	print("SMOKE ...its Build row says the pitch varies: ", BuildTree.summary(curves, 0).contains("pitch varies over 2 points"), " ", BuildTree.summary(curves, 0))
	quit()
