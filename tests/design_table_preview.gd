extends SceneTree
## The translucent PREVIEW before Apply (Phase 5.5; scripts/design_table/feature_preview.gd and the editor's schedule_preview): eager create +
## PATCH for Fillet / Extrude (the feature is made as soon as the tool has what it needs, PATCHed when a setting changes, deleted when the picks
## go or the tool changes, kept by Apply with no second create), the part's own copy untouched while previewing, the coarse path (a stub tool whose
## preview is the coarse-preview route: nothing stored), the body-mesh JSON -> mesh conversion, and the triangle BUDGET (a preview over it is not
## drawn and the user is told). Fake backend: this checks the sequence of calls and what is drawn, not the real shape.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_preview.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const FeaturePreview := preload("res://scripts/design_table/feature_preview.gd")
const FeatureTool := preload("res://scripts/design_table/features/feature_tool.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")


class CoarseTool extends "res://scripts/design_table/features/feature_tool.gd":
	func _init() -> void:
		id = "coarse_test"
	func preview_mode() -> String:
		return "coarse"
	func preview_route() -> String:
		return "coarse-test-features/coarse-preview"
	func request(_ed, _extra: Dictionary = {}) -> Dictionary:
		return PartFeatures._good("coarse-test-features", {"count": 3})


var _applied := false


func _apply_in_background(ed) -> void:
	await ed.apply_feature()
	_applied = true


func _tetra(scale_by: float = 1.0) -> Dictionary:
	return {"body_id": "coarse-preview", "source": "coarse", "mesh": {
		"vertices": [[0, 0, 0], [10 * scale_by, 0, 0], [0, 10 * scale_by, 0], [0, 0, 10 * scale_by]],
		"normals": [[0, 0, -1], [0, 0, -1], [0, 0, -1], [0, 0, -1]],
		"triangle_indices": [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]], "edges": []}}


func _initialize() -> void:
	# --- pure: the JSON -> mesh conversion and the budget
	var mesh := FeaturePreview.mesh_from_bodies([_tetra()])
	print("SMOKE a coarse body's JSON becomes a mesh with its four triangles: ", mesh != null and FeaturePreview.triangle_count(mesh) == 4)
	print("SMOKE ...two bodies are two surfaces, an empty list is no mesh: ", FeaturePreview.mesh_from_bodies([_tetra(), _tetra(2.0)]).get_surface_count() == 2 and FeaturePreview.mesh_from_bodies([]) == null)
	print("SMOKE ...its triangles are flipped to Godot's winding (the backend's are counter-clockwise from outside): ", (mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).slice(0, 3) == PackedInt32Array([0, 1, 2]))
	var big := {"body_id": "coarse-preview", "source": "coarse", "mesh": {"vertices": [], "normals": [], "triangle_indices": [], "edges": []}}
	var count := FeaturePreview.MAX_TRIANGLES + 10
	for i in count:
		big["mesh"]["triangle_indices"].append([0, 1, 2])
	big["mesh"]["vertices"] = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]
	big["mesh"]["normals"] = [[0, 0, 1], [0, 0, 1], [0, 0, 1]]
	var heavy := FeaturePreview.mesh_from_bodies([big])
	var holder := Node3D.new()
	root.add_child(holder)
	var shower := FeaturePreview.new()
	print("SMOKE BUDGET: the limit is %d triangles; a mesh just over it is not drawn and says so, one at the limit is drawn: " % FeaturePreview.MAX_TRIANGLES, not shower.show(holder, heavy) and shower.skipped_over_budget and not shower.is_showing() and FeaturePreview.within_budget(FeaturePreview.MAX_TRIANGLES) and not FeaturePreview.within_budget(FeaturePreview.MAX_TRIANGLES + 1))
	print("SMOKE ...a small one is drawn, translucent and double-sided, on its parent: ", shower.show(holder, mesh) and shower.node.get_parent() == holder and (shower.node.material_override as StandardMaterial3D).albedo_color.a < 1.0 and (shower.node.material_override as StandardMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED)
	shower.clear()
	print("SMOKE ...and clear takes it away: ", not shower.is_showing())

	# --- the editor
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	var mesh_before = table.table_copy.mesh
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "line":
			edge_index = int(index)
			break
	table.manager.activate("fillet")
	await rig.frames(3)
	print("SMOKE choosing Fillet with no edges makes nothing and draws nothing: ", rig.calls_to("POST /document/parts/PART_BOX/fillet-features").is_empty() and not ed.preview.is_showing() and ed.preview_feature_id == "")
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview.is_showing())
	var creates: Array = rig.calls_to("POST /document/parts/PART_BOX/fillet-features")
	print("SMOKE a valid pick creates the fillet at once (one POST) and draws its result translucent on the part: ", creates.size() == 1 and ed.preview_feature_id != "" and ed.preview.is_showing() and ed.preview.node.get_parent() == table.table_copy, " ", creates.size())
	print("SMOKE ...the part's own mesh is NOT replaced while previewing (the picks stay valid): ", table.table_copy.mesh == mesh_before)
	print("SMOKE ...the preview mesh is fetched coarse (quality 0.3): ", rig.calls_to("/assembly-mesh.glb").any(func(c): return String(c[0]).contains("quality=0.3")))
	var made_id: String = ed.preview_feature_id
	ed.option_typed("radius", "3.5")
	await rig.settle(func() -> bool: return not rig.calls_to("PATCH /document/parts/PART_BOX/fillet-features/").is_empty())
	await rig.frames(3)
	var patches: Array = rig.calls_to("PATCH /document/parts/PART_BOX/fillet-features/")
	print("SMOKE changing the radius PATCHes that feature (no second create): ", patches.size() >= 1 and patches.back()[1]["radius"] == 3.5 and rig.calls_to("POST /document/parts/PART_BOX/fillet-features").size() == 1 and String(patches.back()[0]).ends_with(made_id))
	ed.clear_picks()
	ed.schedule_preview()
	await rig.settle(func() -> bool: return not ed.preview.is_showing() and ed.preview_feature_id == "")
	print("SMOKE with no pick left the preview feature is deleted and the overlay goes: ", not rig.calls_to("DELETE /document/parts/PART_BOX/features/" + made_id).is_empty() and not ed.preview.is_showing())
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview.is_showing())
	var second_id: String = ed.preview_feature_id
	var posts_before: int = rig.calls_to("POST /document/parts/PART_BOX/fillet-features").size()
	await ed.apply_feature()
	print("SMOKE Apply keeps the preview's feature (a PATCH, not a second create), puts it on Undo, and clears the overlay: ", rig.calls_to("POST /document/parts/PART_BOX/fillet-features").size() == posts_before and ed.feature_stack.back() == second_id and not ed.preview.is_showing() and ed.preview_feature_id == "")
	# cancel by changing tool
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview_feature_id != "")
	var third_id: String = ed.preview_feature_id
	table.manager.activate("chamfer")
	await rig.settle(func() -> bool: return ed.preview_feature_id == "" or ed.preview_feature_id != third_id)
	await rig.frames(3)
	print("SMOKE choosing another tool deletes the unapplied preview feature: ", not rig.calls_to("DELETE /document/parts/PART_BOX/features/" + third_id).is_empty() and (ed.preview_feature_id == "" or ed.preview_feature_id != third_id))
	# Apply while a preview request is still in flight must wait for it (else the preview makes a SECOND feature afterwards: a real backend answers later than the fake)
	table.manager.deactivate()
	await rig.frames(3)
	table.manager.activate("fillet")
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	var posts_now: int = rig.calls_to("POST /document/parts/PART_BOX/fillet-features").size()
	ed._preview_running = true
	call_deferred("_apply_in_background", ed)
	await rig.frames(4)
	print("SMOKE Apply waits while a preview is in flight (nothing is sent yet): ", rig.calls_to("POST /document/parts/PART_BOX/fillet-features").size() == posts_now)
	ed._preview_running = false
	await rig.settle(func() -> bool: return _applied)
	print("SMOKE ...then it goes ahead: exactly one new fillet is made: ", rig.calls_to("POST /document/parts/PART_BOX/fillet-features").size() == posts_now + 1)
	# preview off
	table.manager.deactivate()
	await rig.frames(3)
	ed.preview_enabled = false
	fake.calls.clear()
	table.manager.activate("fillet")
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	ed.schedule_preview()
	await rig.frames(5)
	print("SMOKE with preview off nothing is created until Apply: ", rig.calls_to("POST /document/parts/PART_BOX/fillet-features").is_empty() and not ed.preview.is_showing())
	ed.preview_enabled = true
	ed.clear_picks()
	table.manager.deactivate()
	await rig.frames(3)

	# --- the coarse path
	ed.tools["coarse_test"] = CoarseTool.new()
	fake.coarse_bodies = [_tetra()]
	fake.calls.clear()
	var mesh_before_coarse = table.table_copy.mesh
	ed.tools["coarse_test"].id = "coarse_test"
	table.active_tool = "coarse_test"
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview.is_showing())
	var coarse_calls: Array = rig.calls_to("coarse-preview")
	print("SMOKE a coarse tool POSTs the coarse-preview route with the create body and quality 0.3, creating nothing: ", coarse_calls.size() == 1 and String(coarse_calls[0][0]).contains("quality=0.3") and coarse_calls[0][1] == {"count": 3} and rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/coarse-test-features").is_empty() and ed.preview_feature_id == "")
	print("SMOKE ...and the coarse result is drawn translucent on the part, whose own mesh is untouched: ", ed.preview.is_showing() and ed.preview.triangles == 4 and table.table_copy.mesh == mesh_before_coarse)
	fake.coarse_bodies = [big]
	ed.schedule_preview()
	await rig.settle(func() -> bool: return not ed.preview.is_showing())
	print("SMOKE a coarse result over the budget is dropped, and the user is told to Apply to see it: ", not ed.preview.is_showing() and table.status().contains("too heavy"))
	table.active_tool = ""
	await ed.cancel_preview()
	quit()
