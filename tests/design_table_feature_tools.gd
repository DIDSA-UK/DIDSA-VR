extends SceneTree
## The feature-tool interface (scripts/design_table/features/): every feature tool the deck lists is registered, its option list has the
## shape the panel and the deck's old row both take, its request is the checked create body the backend wants (the same one a preview
## PATCHes and Redo resends), and the checks refuse what the backend would. Pure: a stub stands in for the editor.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_feature_tools.gd  (see tests/README.md)

const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")


class FakeSession extends RefCounted:
	var feature_id := "S1"
	var sketch_id := "SK1"
	var ok := true
	func profile_ok() -> bool: return ok


class FakeTable extends RefCounted:
	var status := ""
	func set_status(text: String) -> void: status = text


class Ed extends RefCounted:
	const BuildTree := preload("res://scripts/design_table/build_tree.gd")
	var options := {"boss": true, "flip": false, "new_body": false, "depth": 10.0, "radius": 2.0, "distance": 2.0, "angle": 360.0, "thickness": 2.0, "shell_direction": "inward", "mirror_fuse": false,
		"ext_sym": false, "ext_thin": false, "ext_wall": 2.0, "ext_dir": "outward", "ext_draft": false, "ext_angle": 5.0, "ext_draft_out": true}
	var editing := {}
	var activating_edit := false
	var session: RefCounted = null
	var table := FakeTable.new()
	var state := "sketch"
	var edges: Array = []
	var faces: Array = []
	var revolve_axis := ""
	var typed: Array = []
	var cleared := 0
	var state_set := ""
	func seed_sketch_id() -> String: return session.feature_id if session != null else ""
	func seed_sketch_internal_id() -> String: return session.sketch_id if session != null else ""
	var seed_sketch := ""
	func targets_option() -> Dictionary: return {"id": "targets", "text": "Targets: none", "toggle": true, "pressed": false}
	func seed_axis_sketch_id() -> String: return session.sketch_id if session != null else ""
	func seed_ready() -> bool: return session != null and session.profile_ok()
	func start_sketch_pick() -> void: state_set = "pick_sketch"
	func extrude_distances() -> Array: return [-float(options["depth"]) * 0.5, float(options["depth"]) * 0.5] if bool(options["ext_sym"]) else [0.0, 10.0]
	func extrude_targets() -> Array: return []
	func edge_refs() -> Array: return edges.map(func(e): return PartFeatures.edge_ref(str(e["body_id"]), int(e["index"])))
	func body_ids() -> Array: return ["B1"]
	func type_option(key: String, title: String) -> void: typed.append([key, title])
	func clear_picks() -> void:
		cleared += 1
		edges.clear()
		faces.clear()
	func set_state(s: String) -> void: state_set = s
	func start_edge_picks() -> void: state_set = "pick_edges"
	var highlight = null


func _initialize() -> void:
	var tools := FeatureTools.make_all()
	var deck_ids: Array = TableTools.FEATURE_TOOLS.map(func(t): return t[0])
	print("SMOKE every tool on the deck's Feature row has a feature tool: ", deck_ids.all(func(id): return tools.has(id)), " ", tools.keys())
	var ed := Ed.new()
	var shaped := true
	for id in ["extrude", "revolve", "fillet", "chamfer", "shell", "mirror"]: # (the later tools have their own tests with the real editor)
		for o in tools[id].options(ed):
			shaped = shaped and o is Dictionary and o.has("id") and o.has("text")
	print("SMOKE every option has an id and a text: ", shaped)

	# Extrude
	var ex = tools["extrude"]
	print("SMOKE Extrude's options are Boss, Cut, Flip, Both sides, New body, Depth, Thin wall, Draft, Targets (a picked sketch's bodies to fuse into, shown with no sketch open), Apply (Apply off with no sketch): ", ex.options(ed).map(func(o): return o["id"]) == ["boss", "cut", "flip", "ext_sym", "new_body", "depth", "ext_thin", "ext_draft", "targets", "apply"] and ex.options(ed)[-1]["disabled"])
	ed.options["boss"] = false
	print("SMOKE ...Cut takes New body away: ", not ex.options(ed).any(func(o): return o["id"] == "new_body"))
	print("SMOKE ...without a closed shape its request is refused with a reason: ", not ex.request(ed)["ok"] and str(ex.request(ed)["error"]) != "")
	ed.session = FakeSession.new()
	ed.options["boss"] = true
	var req: Dictionary = ex.request(ed)
	print("SMOKE ...with one it is the extrude-features body: ", req["ok"] and req["route"] == "extrude-features" and req["body"]["sketch_feature_id"] == "S1" and req["body"]["extrude_type"] == "boss" and req["body"]["end_distance"] == 10.0, " ", req["body"])
	print("SMOKE ...handle_option toggles Flip and asks for a typed Depth, and leaves Apply to the editor: ", ex.handle_option(ed, "flip") and ed.options["flip"] and ex.handle_option(ed, "depth") and ed.typed == [["depth", "Depth (mm)"]] and not ex.handle_option(ed, "apply"))
	print("SMOKE ...it spends the sketch: ", ex.finishes_sketch())
	# Phase 7.1: both sides, thin wall, draft
	ed.options["depth"] = 20.0
	ex.handle_option(ed, "ext_sym")
	req = ex.request(ed)
	print("SMOKE 7.1 Both sides spans minus half to plus half of the depth: ", req["ok"] and req["body"]["start_distance"] == -10.0 and req["body"]["end_distance"] == 10.0, " ", req["body"])
	print("SMOKE ...and greys Flip: ", ex.options(ed).filter(func(o): return o["id"] == "flip")[0]["disabled"])
	ex.handle_option(ed, "ext_sym")
	req = ex.request(ed)
	print("SMOKE ...a plain extrude sends no wall or draft fields at all: ", not req["body"].has("thickness") and not req["body"].has("draft_angle"))
	ex.handle_option(ed, "ext_thin")
	ed.options["ext_wall"] = 1.5
	ex.handle_option(ed, "ext_dir_inward")
	req = ex.request(ed)
	print("SMOKE ...Thin wall sends the wall and its side: ", req["ok"] and req["body"]["thickness"] == 1.5 and req["body"]["thickness_direction"] == "inward", " ", req["body"])
	var ids: Array = ex.options(ed).map(func(o): return o["id"])
	print("SMOKE ...it adds the wall value and Out / In / Mid, and greys Draft: ", ids.has("ext_wall") and ids.has("ext_dir_symmetric") and ex.options(ed).filter(func(o): return o["id"] == "ext_draft")[0]["disabled"])
	ed.options["ext_draft"] = true
	print("SMOKE ...a wall and a draft together are refused with a reason: ", not ex.request(ed)["ok"] and str(ex.request(ed)["error"]).contains("can't be combined"))
	ed.options["ext_thin"] = false
	ed.options["ext_angle"] = 7.0
	req = ex.request(ed)
	print("SMOKE ...Draft sends the angle and whether it widens: ", req["ok"] and req["body"]["draft_angle"] == 7.0 and req["body"]["draft_outward"] == true and not req["body"].has("thickness"), " ", req["body"])
	ed.options["ext_angle"] = 90.0
	print("SMOKE ...a draft of 90 degrees or more is refused: ", not ex.request(ed)["ok"])
	ed.options["ext_angle"] = 5.0
	ed.options["ext_draft"] = false
	ed.options["ext_thin"] = true
	ed.options["ext_wall"] = 0.0
	print("SMOKE ...a wall of zero is refused: ", not ex.request(ed)["ok"])
	ed.options["ext_thin"] = false
	ex.handle_option(ed, "ext_angle")
	print("SMOKE ...Angle and Wall ask for a typed number: ", ed.typed.back() == ["ext_angle", "Draft angle (degrees, under 90)"])
	# Edit in the tool: the row's settings come back, a PATCH turns a wall off with an explicit null, never resends the profile or the bodies
	ed.options["ext_draft"] = false
	var row := {"type": "extrude", "id": "E1", "sketch_feature_id": "S9", "extrude_type": "boss", "start_distance": -10.0, "end_distance": 10.0, "thickness": -1.5, "thickness_direction": "symmetric", "draft_angle": null, "draft_outward": true, "target_body_ids": ["B1"]}
	ex.load_from_row(ed, row)
	print("SMOKE Edit loads a symmetric thin extrude: ", ed.options["ext_sym"] and ed.options["ext_thin"] and ed.options["ext_wall"] == 1.5 and ed.options["ext_dir"] == "symmetric" and not ed.options["ext_draft"] and ed.options["depth"] == 20.0)
	ed.editing = {"id": "E1", "type": "extrude", "original": row}
	ed.session = null
	ed.seed_sketch = ""
	var edit_req: Dictionary = ex.request(ed)
	print("SMOKE ...its PATCH body keeps the old sketch and bodies out and, with the span untouched, the distances too: ", edit_req["ok"] and not edit_req["body"].has("sketch_feature_id") and not edit_req["body"].has("target_body_ids") and not edit_req["body"].has("start_distance"), " ", edit_req["body"])
	ed.options["ext_thin"] = false
	var off: Dictionary = ex.patch_body(ex.request(ed))
	print("SMOKE ...turning the wall off PATCHes thickness: null, and the draft stays null: ", off.has("thickness") and off["thickness"] == null and off.has("draft_angle") and off["draft_angle"] == null)
	ed.options["depth"] = 30.0
	print("SMOKE ...changing the depth sends the new span: ", ex.request(ed)["body"].has("end_distance"))
	print("SMOKE ...undo's payload is the row's old values (a null wall stays a null): ", ex.row_payload(row).has("thickness") and ex.row_payload(row)["start_distance"] == -10.0 and ex.row_payload(row).has("draft_angle"))
	print("SMOKE ...Extrude edits in its own tool and its Build row says both sides / wall / draft: ", ex.edits_in_tool() and BuildTree.summary([row], 0) == "Boss 20 mm, both sides, wall 1.5")
	ed.editing = {}
	ed.session = FakeSession.new() # (back to where the checks after this block expect to find the editor)
	ed.options["depth"] = 10.0
	ed.options["ext_sym"] = false
	ed.options["ext_thin"] = false


	# Revolve
	var rv = tools["revolve"]
	print("SMOKE Revolve waits for its axis: ", rv.options(ed)[-1]["disabled"] and not rv.request(ed)["ok"])
	ed.revolve_axis = "L3"
	req = rv.request(ed)
	print("SMOKE ...then asks for revolve-features about that line: ", req["ok"] and req["route"] == "revolve-features" and req["body"]["axis_ref"]["entity_id"] == "L3" and req["body"]["angle"] == 360.0)

	# Fillet / Chamfer
	var fl = tools["fillet"]
	print("SMOKE Fillet with no edges is refused and Apply is off: ", not fl.request(ed)["ok"] and fl.options(ed)[-1]["disabled"])
	ed.edges = [{"body_id": "B1", "index": 4}]
	req = fl.request(ed)
	print("SMOKE ...with an edge it is fillet-features with the edge ref and the radius: ", req["ok"] and req["route"] == "fillet-features" and req["body"] == {"edge_refs": [{"body_id": "B1", "shape_type": "edge", "index": 4}], "radius": 2.0})
	print("SMOKE ...Clear forgets the picks: ", fl.handle_option(ed, "clear_edges") and ed.cleared == 1 and ed.edges.is_empty())
	ed.edges = [{"body_id": "B1", "index": 4}]
	req = tools["chamfer"].request(ed)
	print("SMOKE Chamfer is chamfer-features with the distance: ", req["ok"] and req["route"] == "chamfer-features" and req["body"]["distance"] == 2.0)

	# Shell
	var sh = tools["shell"]
	print("SMOKE Shell with no faces is refused: ", not sh.request(ed)["ok"])
	ed.faces = [{"body_id": "B1", "index": 2}]
	ed.options["shell_direction"] = "outward"
	req = sh.request(ed)
	print("SMOKE ...with a face it is shell-features on that body, outward: ", req["ok"] and req["route"] == "shell-features" and req["body"]["body_id"] == "B1" and req["body"]["thickness_direction"] == "outward" and req["body"]["faces_to_remove"] == [{"body_id": "B1", "shape_type": "face", "index": 2}])
	print("SMOKE ...Inward and Outward are a pair: ", sh.handle_option(ed, "shell_in") and ed.options["shell_direction"] == "inward")

	# Mirror
	var mi = tools["mirror"]
	req = mi.request(ed, {"spec": {"fixed": "XY"}})
	print("SMOKE Mirror across a reference plane is mirror-features with a fixed plane: ", req["ok"] and req["route"] == "mirror-features" and req["body"]["mirror_plane"] == {"fixed_plane": "XY"} and req["body"]["merge"] == "keep_separate")
	req = mi.request(ed, {"spec": {"face": {"body_id": "B1", "index": 7}}})
	print("SMOKE ...across a face it is a face ref: ", req["body"]["mirror_plane"] == {"face_ref": {"body_id": "B1", "shape_type": "face", "index": 7}})
	print("SMOKE ...its only setting is Fuse into one: ", mi.options(ed).map(func(o): return o["id"]) == ["mirror_fuse"] and mi.handle_option(ed, "mirror_fuse") and ed.options["mirror_fuse"])

	# The Build tree knows how to edit the same six
	print("SMOKE the done texts read as before: ", tools["fillet"].done_text() == "Fillet done." and tools["mirror"].done_text() == "Mirrored.")
	quit()
