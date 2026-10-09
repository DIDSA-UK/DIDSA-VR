extends SceneTree
## The design table's VISIBILITY model (scripts/design_table/visibility.gd, docs/sketch-as-seed-plan.md steps 1): pure rules, then the load
## rule and the category batch rule wired into the Build tree with a FAKE backend. Pure: which sketches are seeds (extrude, revolve, loft
## sections, sweep profile and path; not a pattern direction; not when rolled back), the load rule over the file's hidden ids, the "3 of 5"
## state, show-all-unless-all-visible, the session-only switches. Scene: a part seated with a consumed sketch comes up with it hidden and
## a free sketch shown (nothing marked unsaved), the rule runs once per part per loaded file, a category button edits `hidden_feature_ids`
## and nothing else is written to the file.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_visibility.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const Vis := preload("res://scripts/design_table/visibility.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var fake


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await process_frame
	return false


func rows_fixture() -> Array:
	return [
		{"type": "sketch", "id": "sk_a", "sketch_id": "sA"},
		{"type": "extrude", "id": "ex_a", "sketch_feature_id": "sk_a"},
		{"type": "sketch", "id": "sk_b", "sketch_id": "sB"},
		{"type": "sketch", "id": "sk_c", "sketch_id": "sC"},
		{"type": "create_plane", "id": "pl_1"},
		{"type": "sketch", "id": "sk_d", "sketch_id": "sD"},
		{"type": "sketch", "id": "sk_e", "sketch_id": "sE"},
		{"type": "loft", "id": "lo_1", "sections": [{"sketch_feature_id": "sk_b"}, {"sketch_feature_id": "sk_c"}]},
		{"type": "sketch", "id": "sk_f", "sketch_id": "sF"},
		{"type": "sketch", "id": "sk_g", "sketch_id": "sG"},
		{"type": "sweep", "id": "sw_1", "sketch_feature_id": "sk_d", "path_refs": [{"sketch_id": "sE", "entity_type": "line", "entity_id": "l1"}]},
		{"type": "revolve", "id": "rv_1", "sketch_feature_id": "sk_f", "axis_ref": {"sketch_id": "sF"}},
		{"type": "pattern", "id": "pa_1", "direction": {"sketch_id": "sG", "entity_id": "l9"}},
		{"type": "fillet", "id": "fi_1"},
		{"type": "surface", "id": "su_1"},
	]


func _initialize() -> void:
	var rows := rows_fixture()
	var seeds := Vis.seed_sketch_ids(rows)
	print("SMOKE seeds: extrude, loft sections, sweep profile and path, revolve (not a pattern's direction sketch, not a free sketch): ", seeds == ["sk_a", "sk_b", "sk_c", "sk_d", "sk_e", "sk_f"])
	print("SMOKE a rolled-back feature consumes nothing (rolling back the loft frees both sections): ", Vis.seed_sketch_ids(rows, ["lo_1"]) == ["sk_a", "sk_d", "sk_e", "sk_f"])
	print("SMOKE categories: sketches, planes, surfaces, bodies (everything else): ", Vis.ids_of(rows, Vis.SKETCHES).size() == 7 and Vis.ids_of(rows, Vis.PLANES) == ["pl_1"] and Vis.ids_of(rows, Vis.SURFACES) == ["su_1"] and Vis.ids_of(rows, Vis.BODIES) == ["ex_a", "lo_1", "sw_1", "rv_1", "pa_1", "fi_1"] and Vis.ids_of(rows, Vis.CURVES).is_empty())

	var loaded := Vis.load_hidden(rows, [])
	print("SMOKE load rule: consumed sketches and created planes hidden, free sketches, bodies and surfaces shown: ", loaded == ["sk_a", "sk_b", "sk_c", "sk_d", "sk_e", "sk_f", "pl_1"])
	var loaded2 := Vis.load_hidden(rows, ["su_1", "fi_1", "sk_g", "other_part", "sk_a"])
	print("SMOKE ...a body, surface or other part's id the file hid stays hidden; a sketch the file hid follows the rule (a free one is shown again): ", loaded2.has("su_1") and loaded2.has("fi_1") and loaded2.has("other_part") and not loaded2.has("sk_g") and loaded2.has("sk_a") and loaded2.count("sk_a") == 1)
	print("SMOKE ...rolled back, the load rule shows the freed sketches: ", not Vis.load_hidden(rows, [], ["lo_1"]).has("sk_b") and Vis.load_hidden(rows, [], ["lo_1"]).has("sk_a"))

	var st := Vis.category_state(rows, loaded, Vis.SKETCHES)
	print("SMOKE the sketches read '1 of 7' and 'some' after the load rule: ", st["label"] == "1 of 7" and st["state"] == "some" and st["visible"] == 1)
	print("SMOKE a category with nothing in it is 'empty' (3D curves); all visible is 'all'; none is 'none': ", Vis.category_state(rows, loaded, Vis.CURVES)["state"] == "empty" and Vis.category_state(rows, [], Vis.SKETCHES)["state"] == "all" and Vis.category_state(rows, Vis.ids_of(rows, Vis.SKETCHES), Vis.SKETCHES)["state"] == "none")
	var shown := Vis.toggle_category(rows, loaded, Vis.SKETCHES)
	print("SMOKE the button on a mixed category shows ALL its items, leaving other categories and parts alone: ", Vis.category_state(rows, shown, Vis.SKETCHES)["state"] == "all" and shown.has("pl_1") and shown.size() == 1)
	var hidden_all := Vis.toggle_category(rows, shown + ["other_part"], Vis.SKETCHES)
	print("SMOKE ...on an all-visible category it hides all (off then on always ends with everything visible): ", Vis.category_state(rows, hidden_all, Vis.SKETCHES)["state"] == "none" and hidden_all.has("other_part") and Vis.category_state(rows, Vis.toggle_category(rows, hidden_all, Vis.SKETCHES), Vis.SKETCHES)["state"] == "all")
	print("SMOKE rolled-back features are not counted (rolling back the loft takes its row out of Bodies, 5 of 5): ", Vis.category_state(rows, [], Vis.BODIES, ["lo_1"])["label"] == "5 of 5" and Vis.category_state(rows, ["fi_1"], Vis.BODIES, ["lo_1"])["label"] == "4 of 5")

	var vis := Vis.new(true)
	print("SMOKE session switches start off except edge lines, which follow the Display mode: ", not vis.is_on(Vis.REFERENCE_PLANES) and not vis.is_on(Vis.ORIGIN_AXES) and not vis.is_on(Vis.DIMENSIONS) and not vis.is_on(Vis.CONSTRUCTION) and vis.is_on(Vis.EDGE_LINES) and not Vis.new(false).is_on(Vis.EDGE_LINES))
	vis.toggle(Vis.ORIGIN_AXES)
	vis.set_on("nonsense", true)
	print("SMOKE ...they toggle, unknown names are ignored, set_all and reset work: ", vis.is_on(Vis.ORIGIN_AXES) and not vis.is_on("nonsense") and (func(): vis.set_all(false); return not vis.is_on(Vis.ORIGIN_AXES) and not vis.is_on(Vis.EDGE_LINES)).call() and (func(): vis.reset(true); return vis.is_on(Vis.EDGE_LINES)).call())

	# --- scene: the rule and the button over the Build tree
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	var box_bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(box_bytes, "", 0.001)
	await frames(3)
	var box: MeshInstance3D
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var owner_id := str(box.get_meta("owner_part_id", ""))
	if owner_id == "":
		owner_id = "ASM"
		for p in get_nodes_in_group("grabbable_parts"):
			p.set_meta("owner_part_id", owner_id)
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = box_bytes
	fake.filtered_mesh_bytes = box_bytes
	fake.feature_rows = {"PART_BOX": rows_fixture()}
	table.api = fake
	table.editor.api = fake
	main.set_hidden_feature_ids(["su_1", "sk_g"], false) # as a loaded file would carry them
	main.document_dirty = false
	table.open()
	table.seat(box)
	var ready: bool = await settle(func() -> bool: return table.build.features.size() == rows.size())
	var want: Array = ["su_1", "sk_a", "sk_b", "sk_c", "sk_d", "sk_e", "sk_f", "pl_1"]
	var got: Array = main.hidden_feature_ids()
	print("SMOKE seating a part applies the load rule to the file's hidden list (surface kept, free sketch shown, consumed sketches and planes hidden): ", ready and got.size() == want.size() and want.all(func(id): return got.has(id)))
	print("SMOKE ...without marking the file unsaved: ", not main.document_dirty)
	print("SMOKE ...and the Build tree counts say so: ", table.build.category_state(Vis.SKETCHES)["label"] == "1 of 7" and table.build.category_state(Vis.PLANES)["label"] == "0 of 1")

	main.set_feature_hidden("sk_g", true) # the user hides the free sketch by hand
	table.build.reload()
	await frames(3)
	print("SMOKE reloading the same part does not run the rule again (the hand-made hide stays): ", main.hidden_feature_ids().has("sk_g"))
	await table.build.toggle_category(Vis.SKETCHES)
	print("SMOKE the Sketches button on a mixed state shows them all (hand-made hide included) and marks the file unsaved: ", table.build.category_state(Vis.SKETCHES)["state"] == "all" and not main.hidden_feature_ids().has("sk_g") and main.hidden_feature_ids().has("su_1") and main.document_dirty)
	await table.build.toggle_category(Vis.SKETCHES)
	print("SMOKE ...pressed again it hides them all: ", table.build.category_state(Vis.SKETCHES)["state"] == "none")
	print("SMOKE the only visibility key in the saved file is hidden_feature_ids: ", main.native_extras_to_add({}).keys().filter(func(k): return str(k).contains("hidden") or str(k).contains("visib") or str(k).begins_with("vr_")) == ["hidden_feature_ids"])
	await table.build.toggle_category(Vis.CURVES)
	print("SMOKE a category with nothing in it ignores its button: ", table.build.category_state(Vis.CURVES)["state"] == "empty")
	quit()
