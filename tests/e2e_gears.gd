extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the GEAR TOOLS (gears-and-motion plan M2). On a fresh part: an external gear (module 2, 20 teeth, 10 mm wide) is made with the
## Gear tool, its coarse preview (nothing stored) answers with a mesh, Apply makes a body about 44 x 44 x 10 mm, and Edit > Bore 8 > Apply gives it one more cylindrical face (the bore, found
## in the part's face kinds, the faces a concentric mate picks) while Edit > teeth 24 widens it. An internal gear (module 2, 40 teeth, 100 mm ring), a rack (module 2, 10 teeth) and a bevel
## gear (module 2, 20 teeth, 45 degrees, bore 8) each make a body with triangles; the Build rows read as gears.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_gears.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const FeaturePreview := preload("res://scripts/design_table/feature_preview.gd")

var main
var table


func wait_for(pred: Callable, frames := 1800) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func fresh_part() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")


func cylinder_faces() -> int:
	## How many faces of the seated part the backend calls cylindrical.
	var n := 0
	var topology: Dictionary = table.seated.get_meta("topology", {})
	for body in topology.values():
		for kind in (body as Dictionary).get("face_kinds", []):
			if str(kind) == "cylinder":
				n += 1
	return n


func unique_bodies() -> int:
	var seen := {}
	for id in table.seated.get_meta("body_ids", []):
		seen[str(id)] = true
	return seen.size()


func reset_gear(ed) -> void:
	## The tool keeps the numbers last used (for the next gear); a test starts each gear from the defaults.
	for key in ed.tools["gear"].DEFAULTS:
		ed.options[key] = ed.tools["gear"].DEFAULTS[key]


func triangles() -> int:
	return FeaturePreview.triangle_count(table.seated.mesh) if table.seated != null and table.seated.mesh != null else 0


func features(ed) -> Array:
	return (await ed.features.list_features(ed.part_id))["features"]


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

	# External gear, no bore first
	await fresh_part()
	table.manager.activate("gear")
	await process_frame
	ed.options["g_bore"] = 0.0
	ed._update_options()
	ed.preview_enabled = true
	ed.schedule_preview()
	var previewed: bool = await wait_for(func() -> bool: return ed.preview.is_showing())
	print("SMOKE the Gear tool's coarse preview (real route) answers with a mesh and stores nothing: ", previewed and ed.preview_feature_id == "" and ed.preview.triangles > 0 and (await features(ed)).is_empty(), " ", ed.preview.triangles)
	ed.preview_enabled = false
	var circles: bool = await wait_for(func() -> bool: return str(ed.tools["gear"].readout(ed.options)[0]).begins_with("Pitch 40") and ed.tools["gear"]._circles.has("key"))
	print("SMOKE ...the readout carries the backend's circle sizes: pitch 40, tip 44, root 35 and the centre distance to a 20-tooth gear 40: ", circles and ed.tools["gear"].readout(ed.options) == ["Pitch 40  Tip 44  Root 35 mm", "Centre distance to a 20-tooth gear: 40 mm"], " ", ed.tools["gear"].readout(ed.options))
	await ed.apply_feature()
	var made: bool = await wait_for(func() -> bool: return not table.is_blank() and triangles() > 0)
	var size: Vector3 = table.seated.get_aabb().size
	var rows: Array = await features(ed)
	print("SMOKE Apply makes a real gear body about 44 x 44 x 10 mm: ", made and rows.size() == 1 and str(rows[0]["type"]) == "gear" and absf(size.x - 44.0) < 1.0 and absf(size.z - 10.0) < 0.5, " ", size, " ", rows.size())
	var plain_cylinders := cylinder_faces()
	var plain_triangles := triangles()
	print("SMOKE ...its row reads External 20 teeth, module 2: ", BuildTree.summary(rows, 0) == "External 20 teeth, module 2")
	await table.build.reload()
	await ed.begin_tool_edit(str(rows[0]["id"]))
	print("SMOKE Edit opens the Gear tool with the gear's own numbers: ", table.active_tool == "gear" and ed.options["g_teeth"] == 20.0 and ed.options["g_module"] == 2.0 and ed.options["g_bore"] == 0.0)
	ed.option_typed("g_bore", "8")
	await ed.apply_feature()
	await wait_for(func() -> bool: return cylinder_faces() > plain_cylinders)
	print("SMOKE Edit > Bore 8 > Apply PATCHes the real gear: the part gains a cylindrical face (the bore) and loses no body: ", cylinder_faces() == plain_cylinders + 1 and unique_bodies() == 1, " ", plain_cylinders, " -> ", cylinder_faces())
	rows = await features(ed)
	print("SMOKE ...the row now says bore 8: ", BuildTree.summary(rows, 0) == "External 20 teeth, module 2, bore 8")
	await table.build.reload()
	await ed.begin_tool_edit(str(rows[0]["id"]))
	ed.option_typed("g_teeth", "24")
	await ed.apply_feature()
	await wait_for(func() -> bool: return table.seated.get_aabb().size.x > 50.0)
	print("SMOKE Edit > 24 teeth widens the gear to about 52 mm: ", absf(table.seated.get_aabb().size.x - 52.0) < 1.0, " ", table.seated.get_aabb().size)
	await ed.undo()
	await wait_for(func() -> bool: return table.seated.get_aabb().size.x < 50.0)
	print("SMOKE ...Undo puts the 20 teeth back: ", absf(table.seated.get_aabb().size.x - 44.0) < 1.0, " ", table.seated.get_aabb().size)

	# Helical external gear with a bore, on the XZ plane
	await fresh_part()
	table.manager.activate("gear")
	await process_frame
	reset_gear(ed)
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	ed.option_typed("g_helix", "15")
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and triangles() > 0)
	rows = await features(ed)
	var plane_ref = rows[0].get("plane_ref", {}) if not rows.is_empty() else {}
	print("SMOKE a helical gear with a bore, stood on the XZ plane, is made (its row keeps the plane, the helix and the bore): ", not rows.is_empty() and str(plane_ref.get("fixed_plane")) == "XZ" and absf(float(rows[0]["helix_angle_degrees"]) - 15.0) < 1e-9 and float(rows[0]["bore_diameter"]) == 8.0 and cylinder_faces() >= 1, " ", plane_ref)

	# Internal gear
	await fresh_part()
	table.manager.activate("gear")
	await process_frame
	reset_gear(ed)
	await ed.on_option("g_internal")
	ed.option_typed("g_teeth", "40")
	ed.option_typed("g_outer", "100")
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and triangles() > 0)
	size = table.seated.get_aabb().size
	rows = await features(ed)
	print("SMOKE an internal gear (40 teeth, 100 mm ring) is made, 100 mm across, with no bore: ", not rows.is_empty() and bool(rows[0]["is_internal"]) and absf(size.x - 100.0) < 1.0 and float(rows[0].get("bore_diameter", 0.0)) == 0.0, " ", size)
	print("SMOKE ...its row reads Internal 40 teeth, module 2: ", BuildTree.summary(rows, 0) == "Internal 40 teeth, module 2")

	# A bore too big is refused by the backend and said in the status line
	await fresh_part()
	table.manager.activate("gear")
	await process_frame
	reset_gear(ed)
	ed.option_typed("g_bore", "38")
	await ed.apply_feature()
	rows = await features(ed)
	print("SMOKE a bore of 38 mm in a 35 mm root is refused by the real backend, no gear is made, and the status says so: ", rows.is_empty() and table.status().begins_with("Couldn't do that") and table.status().contains("too big"), " ", table.status())

	# Rack
	await fresh_part()
	table.manager.activate("rack")
	await process_frame
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and triangles() > 0)
	size = table.seated.get_aabb().size
	rows = await features(ed)
	print("SMOKE a rack (module 2, 10 teeth) is made: a body about 63 mm long: ", not rows.is_empty() and str(rows[0]["type"]) == "rack" and maxf(size.x, size.y) > 55.0 and maxf(size.x, size.y) < 70.0, " ", size)
	await table.build.reload()
	await ed.begin_tool_edit(str(rows[0]["id"]))
	ed.option_typed("r_teeth", "20")
	await ed.apply_feature()
	await wait_for(func() -> bool: return maxf(table.seated.get_aabb().size.x, table.seated.get_aabb().size.y) > 100.0)
	print("SMOKE ...Edit > 20 teeth doubles its length: ", maxf(table.seated.get_aabb().size.x, table.seated.get_aabb().size.y) > 110.0, " ", table.seated.get_aabb().size)

	# Bevel gear
	await fresh_part()
	table.manager.activate("bevel_gear")
	await process_frame
	ed.preview_enabled = true
	ed.schedule_preview()
	previewed = await wait_for(func() -> bool: return ed.preview.is_showing())
	print("SMOKE the Bevel tool's coarse preview answers with a mesh: ", previewed and ed.preview.triangles > 0)
	ed.preview_enabled = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and triangles() > 0, 3600)
	rows = await features(ed)
	print("SMOKE Apply makes a real bevel gear (module 2, 20 teeth, 45 degrees, bore 8) with a cylindrical bore face: ", not rows.is_empty() and str(rows[0]["type"]) == "bevel_gear" and float(rows[0]["bore_diameter"]) == 8.0 and cylinder_faces() >= 1 and triangles() > 100, " ", triangles(), " ", cylinder_faces())
	print("SMOKE ...its row reads as a bevel gear: ", BuildTree.summary(rows, 0) == "20 teeth, module 2, cone 45 deg", " ", BuildTree.summary(rows, 0) if not rows.is_empty() else "")
	quit()
