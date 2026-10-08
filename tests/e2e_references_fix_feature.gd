extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): mending a flagged NON-sketch feature from its
## Build row (phase 4 of docs/implementation-plan.md). A 60 x 40 x 20 box; a fillet on the vertical edge at (0, 0); a chamfer on the vertical edge at (60, 40) of
## the filleted body. The fillet is then moved (a PATCH of its edge) onto the edge at (60, 40): that corner is consumed, so the backend flags the CHAMFER's
## reference lost. In the design table: the chamfer's Build row carries the note and offers Fix; Fix shows the part as the chamfer saw it (the roll back to the
## row before) and the laser picks a replacement edge, the vertical edge at (0, 40); Apply fix PATCHes the chamfer, the backend re-measures it and the flag clears,
## the part is rolled forward and rebuilt, and Cancel (tried first) changed nothing.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_references_fix_feature.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var table
var ed


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func vertical_edge_at(topology: Dictionary, x: float, y: float) -> Dictionary:
	for body_id in topology:
		var edges: Dictionary = topology[body_id]["edges"]
		for index in edges:
			var pts: PackedVector3Array = edges[index]
			if pts.size() >= 2 and absf(pts[0].x - x) < 0.01 and absf(pts[0].y - y) < 0.01 and absf(pts[pts.size() - 1].x - x) < 0.01 and absf(pts[pts.size() - 1].y - y) < 0.01 and absf(pts[0].z - pts[pts.size() - 1].z) > 1.0:
				return {"body": str(body_id), "index": int(index)}
	return {}


func row_of(feature_id: String) -> Dictionary:
	var listed: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features" % ed.part_id, null)
	if listed["ok"]:
		for f in listed["json"]:
			if str(f["id"]) == feature_id:
				return f
	return {}


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
	ed = table.editor

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

	var pristine: Dictionary = node.get_meta("topology")
	var first_edge := vertical_edge_at(pristine, 0, 0)
	var fillet: Dictionary = await ed.features.fillet(ed.part_id, [PartFeatures.edge_ref(str(first_edge["body"]), int(first_edge["index"]))], 3.0)
	await ed.refresh_geometry()
	var filleted: Dictionary = node.get_meta("topology")
	var chamfer_edge := vertical_edge_at(filleted, 60, 40)
	var chamfer: Dictionary = await ed.features.chamfer(ed.part_id, [PartFeatures.edge_ref(str(chamfer_edge["body"]), int(chamfer_edge["index"]))], 2.0)
	await ed.refresh_geometry()
	print("SMOKE a fillet and a chamfer are made: ", fillet["ok"] and chamfer["ok"])
	var consumed := vertical_edge_at(pristine, 60, 40)
	var moved: Dictionary = await ed._call(HTTPClient.METHOD_PATCH, "/document/parts/%s/fillet-features/%s" % [ed.part_id, fillet["id"]], {"edge_refs": [PartFeatures.edge_ref(str(consumed["body"]), int(consumed["index"]))]})
	await ed.refresh_geometry()
	await table.build.reload()
	var flagged: Dictionary = table.build.row(str(chamfer["id"]))
	var target: Dictionary = BuildTree.fix_target(flagged)
	print("SMOKE the fillet moved onto the chamfer's corner: the backend flags the chamfer's reference lost, its Build row says so and offers Fix for one edge: ", moved["ok"] and (flagged.get("lost_references", []) as Array) == ["edge_refs[0]"] and BuildTree.reference_note(flagged) == "lost reference" and target.get("kind") == "edge", " ", flagged.get("lost_references"))

	# --- Fix, then Cancel: nothing changes
	table.build.select(str(chamfer["id"]))
	await table.build.fix_selected()
	await wait_for(func() -> bool: return ed.state == "pick_edges" and not ed.fixing.is_empty())
	var at: int = table.build.index_of(str(chamfer["id"]))
	print("SMOKE Fix shows the part as the chamfer saw it (rolled back to the row before it) and lets the laser pick edges: ", table.build.rollback_to == str(table.build.features[at - 1]["id"]) and ed.state == "pick_edges" and ed.view_is_filtered())
	await ed.on_option("fix_cancel")
	var after_cancel: Dictionary = await row_of(str(chamfer["id"]))
	print("SMOKE Cancel puts everything back and the reference is still flagged (nothing was changed): ", ed.fixing.is_empty() and table.build.rollback_to == "" and ed.state == "pick_plane" and (after_cancel.get("lost_references", []) as Array).size() == 1)

	# --- Fix, pick the replacement, Apply
	table.build.select(str(chamfer["id"]))
	await table.build.fix_selected()
	await wait_for(func() -> bool: return ed.state == "pick_edges" and not ed.fixing.is_empty())
	var seen_by_chamfer: Dictionary = table.table_copy.get_meta("topology")
	var replacement := vertical_edge_at(seen_by_chamfer, 0, 40)
	print("SMOKE the part as the chamfer saw it has the vertical edge at (0, 40) to pick: ", not replacement.is_empty())
	ed._hover_face = {"kind": "edge", "body_id": replacement["body"], "index": int(replacement["index"]), "face_index": 0, "key": TopologyPick.entity_key("edge", str(replacement["body"]), int(replacement["index"]))}
	ed._toggle_edge()
	print("SMOKE one pick fills the one flagged reference (the options row offers Apply fix): ", ed.edges.size() == 1 and table.ui.option_button("fix_apply") != null and not table.ui.option_button("fix_apply").disabled)
	await ed.on_option("fix_apply")
	await wait_for(func() -> bool: return ed.fixing.is_empty())
	var mended: Dictionary = await row_of(str(chamfer["id"]))
	print("SMOKE Apply fix PATCHes the chamfer with the new edge, the backend re-measures it and the flag is gone: ", not bool(mended.get("has_lost_reference", false)) and (mended.get("lost_references", []) as Array).is_empty() and int(mended["edge_refs"][0]["index"]) == int(replacement["index"]), " ", mended.get("edge_refs"))
	await table.build.reload()
	print("SMOKE the part is rolled forward and the Build row no longer carries the note: ", table.build.rollback_to == "" and not ed.view_is_filtered() and BuildTree.reference_note(table.build.row(str(chamfer["id"]))) == "")
	var mesh: Dictionary = await ed.api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % ed.part_id)
	print("SMOKE ...and the backend still builds the whole part: ", mesh["ok"])
	quit()
