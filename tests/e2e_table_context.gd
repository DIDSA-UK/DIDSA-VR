extends SceneTree
## Talks to a real backend, LOCAL ONLY (same caveat as e2e_new_part.gd): T6's selection-first editing end to end. A new part with a 60 x 40 x 12 box; with no tool
## chosen an edge of it is selected (a pull on what the laser lights), the drawer offers Fillet first, choosing it starts Fillet with that edge picked, Apply: the
## part really has a fillet feature (the backend's feature list) and a new mesh; then a flat face is selected and New sketch on face opens a sketch on THAT face (the
## backend made an offset_face plane on it, and the sketch's plane is the face's).
## Run: DIDSA_NO_LANDING=1 DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_table_context.gd
## Needs secrets.cfg to point at a running backend (tools/start_backend.sh).

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var table
var ed
var api


func check(what: String, ok: bool, extra = "") -> void:
	print("SMOKE ", what, ": ", ok, " ", extra)


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
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	api = table.api
	table.surface.settle_seconds = 0.0
	ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0), "id": ""})
	await ed.session.tap({"uv": Vector2(60, 40), "id": ""})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 12.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and ed.state == "pick_plane")
	await wait_for(func() -> bool: return table.table_copy != null and table.table_copy.has_meta("topology"), 300)
	check("a 60 x 40 x 12 box is on the table and no tool is chosen", not table.is_blank() and ed.state == "pick_plane" and table.active_tool == "")
	var part_id: String = ed.part_id

	# --- an edge: select it as a pull on the lit edge does, then Fillet from the drawer
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "line":
			edge_index = int(index)
			break
	ed.hover_part_entity = {"kind": "edge", "body_id": body_id, "index": edge_index, "key": TopologyPick.entity_key("edge", body_id, edge_index)}
	ed.select_part_entity(ed.hover_part_entity)
	await process_frame
	check("selecting an edge shows the drawer with Fillet first", table.drawer.shown and table.drawer.actions[0]["id"] == "fillet" and table.drawer.actions[0]["enabled"])
	table.drawer.button_named("Action_fillet").pressed.emit()
	await wait_for(func() -> bool: return table.active_tool == "fillet" and ed.edges.size() == 1)
	check("Fillet starts with the edge picked", ed.state == "pick_edges" and ed.edges.size() == 1 and not table.drawer.shown)
	ed.options["radius"] = 2.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return ed.state == "pick_plane" or table.active_tool == "", 600)
	var listed: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/features" % part_id)
	var types: Array = []
	for f in (listed["json"] if listed["ok"] and listed["json"] is Array else []):
		types.append(str(f.get("type", "")))
	check("the backend's feature list for the part has a fillet after the extrude", "fillet" in types and "extrude" in types, str(types))

	# --- a flat face: New sketch on face
	table.manager.deactivate() # (the tool stays on after Apply, as on the deck: put it down)
	await wait_for(func() -> bool: return ed.state == "pick_plane" and table.table_copy.has_meta("topology"), 300)
	topo = table.table_copy.get_meta("topology")
	body_id = topo.keys()[0]
	var face_index := -1
	var kinds: Array = topo[body_id].get("face_kinds", [])
	for fi in kinds.size():
		if str(kinds[fi]) == "plane":
			face_index = fi
			break
	check("the part has a flat face to pick", face_index >= 0, str(kinds))
	ed.select_part_entity({"kind": "face", "body_id": body_id, "index": face_index, "key": TopologyPick.entity_key("face", body_id, face_index)})
	await process_frame
	check("a flat face shows New sketch on face first", table.drawer.shown and table.drawer.actions[0]["id"] == "sketch_on_face")
	table.drawer.button_named("Action_sketch_on_face").pressed.emit()
	var opened: bool = await wait_for(func() -> bool: return ed.state == "sketch" and ed.session != null)
	check("the sketch is open and the drawer is away", opened and not table.drawer.shown)
	var planes: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/features" % part_id)
	var made_plane := false
	for f in (planes["json"] if planes["ok"] and planes["json"] is Array else []):
		if str(f.get("type", "")) in ["create_plane", "plane"] or str(f.get("plane_type", "")) == "offset_face":
			made_plane = true
	check("...on a plane the backend made on that face (offset_face)", made_plane or not ed.chosen_face.is_empty(), str(ed.chosen_face))
	check("...and the editor says which face it is", int(ed.chosen_face.get("index", -1)) == face_index)
	quit()
