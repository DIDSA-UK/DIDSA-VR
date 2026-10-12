extends SceneTree
## Phase 7.3's other ways to make a plane, fake backend, through the real editor: the method chips (Offset, Middle, On corner, To edge, 3 corners), the new corner-picking state,
## how many edges / corners the laser may hold, the numbered plane picks of a midplane, what each method sends (the backend's exact field names), the picks following each
## other (plane then corner, edge then corner), the Selected list, the Build row's wording, and that another tool gets its unlimited picks back.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_plane_types.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")


func vertex(i: int) -> Dictionary:
	return {"kind": "vertex", "body_id": "body_box", "index": i, "key": "vertex:body_box:%d" % i}


func edge(i: int) -> Dictionary:
	return {"kind": "edge", "body_id": "body_box", "index": i, "key": "edge:body_box:%d" % i}


func pick_vertex(ed, i: int) -> void:
	ed._hover_face = vertex(i)
	ed._toggle_vertex()


func pick_edge(ed, i: int) -> void:
	ed._hover_face = edge(i)
	ed._toggle_edge()


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	ed.preview_enabled = false
	table.manager.activate("create_plane")
	await rig.frames(3)
	var tool = ed.tools["create_plane"]
	print("SMOKE Plane opens on Offset with plane picking, as before: ", str(ed.options["pl_method"]) == "offset" and ed.state == "pick_plane" and ed.edge_limit == 0 and ed.vertex_limit == 0)

	# --- Middle: two planes
	await ed.on_option("pl_m_midplane")
	await rig.frames(2)
	print("SMOKE Middle keeps plane picking and lists the chips, a count of planes and a greyed Make plane: ", ed.state == "pick_plane" and table.props.option_ids() == ["pl_m_offset", "pl_m_midplane", "pl_m_vertex", "pl_m_edge", "pl_m_points", "pl_info", "apply"] and table.props.option_button("apply").disabled and table.props.option_button("pl_info").text == "Planes: 0 of 2")
	ed._hover_plane = "XY"
	await ed._pick_plane()
	print("SMOKE ...one plane is not enough and the count says so: ", ed.plane_base == {"fixed": "XY"} and not tool.can_apply(ed) and not tool.request(ed)["ok"] and table.props.option_button("pl_info").text == "Planes: 1 of 2")
	ed._hover_face = {}
	ed._hover_plane = "plane:P7"
	rig.fake.feature_rows["PART_BOX"] = [{"id": "P7", "type": "create_plane", "plane_type": "offset_face", "offset": 30.0, "face_refs": [{"fixed_plane": "XY"}], "origin": [0, 0, 30], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]}]
	await table.build.reload()
	ed.sync_plane_markers()
	await ed._pick_plane()
	var req: Dictionary = tool.request(ed)
	print("SMOKE ...the second pick makes it ready, and it sends midplane with both plane refs: ", tool.can_apply(ed) and req["ok"] and req["body"] == {"plane_type": "midplane", "face_refs": [{"fixed_plane": "XY"}, {"plane_feature_id": "P7"}]}, " ", req["body"])
	print("SMOKE ...the Selected list names both: ", ed.selection_summary().any(func(l): return str(l).begins_with("Plane: XY plane, ")))
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	print("SMOKE ...a third pick replaces the second: ", ed.plane_base == {"fixed": "XY"} and ed.plane_base2 == {"fixed": "XZ"})

	# --- On corner: a plane, then a corner
	await ed.on_option("pl_m_vertex")
	await rig.frames(2)
	print("SMOKE Switching method forgets the old picks and allows one corner: ", ed.plane_base.is_empty() and ed.plane_base2.is_empty() and ed.vertex_limit == 1 and ed.edge_limit == 0 and ed.state == "pick_plane")
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	print("SMOKE ...picking the plane moves the laser on to corners: ", ed.state == "pick_vertices" and table.status().contains("corner"))
	pick_vertex(ed, 4)
	pick_vertex(ed, 6)
	print("SMOKE ...a second corner replaces the first (one is allowed): ", ed.vertices.size() == 1 and ed.vertices[0]["index"] == 6)
	req = tool.request(ed)
	print("SMOKE ...Make plane sends parallel_to_face_through_vertex with the plane and the corner: ", req["ok"] and req["body"] == {"plane_type": "parallel_to_face_through_vertex", "face_refs": [{"fixed_plane": "XZ"}], "vertex_ref": {"body_id": "body_box", "shape_type": "vertex", "index": 6}}, " ", req["body"])
	await rig.frames(2)
	print("SMOKE ...the panel's pick chips show what is being picked and the counts: ", table.props.option_button("pl_pick_vertex").button_pressed and not table.props.option_button("pl_pick_plane").button_pressed and table.props.option_button("pl_pick_plane").text == "Plane (1)" and table.props.option_button("pl_pick_vertex").text == "Corner (1)")
	await ed.on_option("pl_pick_plane")
	print("SMOKE ...Plane switches the laser back to planes: ", ed.state == "pick_plane")
	print("SMOKE ...the Selected list says Corners: ", ed.selection_summary().has("Corners: 1"))

	# --- To edge: an edge, then a corner
	await ed.on_option("pl_m_edge")
	print("SMOKE To edge picks edges first, one at most: ", ed.state == "pick_edges" and ed.edge_limit == 1 and ed.vertex_limit == 1 and ed.vertices.is_empty())
	pick_edge(ed, 2)
	print("SMOKE ...picking the edge moves on to corners: ", ed.state == "pick_vertices" and ed.edges.size() == 1)
	pick_vertex(ed, 5)
	req = tool.request(ed)
	print("SMOKE ...Make plane sends normal_to_edge_through_vertex: ", req["ok"] and req["body"] == {"plane_type": "normal_to_edge_through_vertex", "edge_ref": {"body_id": "body_box", "shape_type": "edge", "index": 2}, "vertex_ref": {"body_id": "body_box", "shape_type": "vertex", "index": 5}}, " ", req["body"])
	await ed.on_option("pl_pick_edge")
	pick_edge(ed, 3)
	print("SMOKE ...a second edge replaces the first: ", ed.edges.size() == 1 and ed.edges[0]["index"] == 3)

	# --- 3 corners
	await ed.on_option("pl_m_points")
	print("SMOKE 3 corners picks corners only, three at most: ", ed.state == "pick_vertices" and ed.vertex_limit == 3)
	pick_vertex(ed, 1)
	pick_vertex(ed, 2)
	print("SMOKE ...two corners are not enough, with a reason: ", not tool.can_apply(ed) and not tool.request(ed)["ok"] and str(tool.request(ed)["error"]).contains("three corners"))
	pick_vertex(ed, 3)
	pick_vertex(ed, 2) # again: takes it away
	pick_vertex(ed, 2)
	pick_vertex(ed, 7)
	print("SMOKE ...a picked corner picked again is taken away, and a fourth drops the oldest: ", ed.vertices.map(func(v): return v["index"]) == [3, 2, 7], " ", ed.vertices.map(func(v): return v["index"]))
	req = tool.request(ed)
	print("SMOKE ...Make plane sends three_points with each corner as a vertex_ref: ", req["ok"] and req["body"]["plane_type"] == "three_points" and (req["body"]["point_refs"] as Array).size() == 3 and req["body"]["point_refs"][0] == {"vertex_ref": {"body_id": "body_box", "shape_type": "vertex", "index": 3}}, " ", req["body"])

	# --- Apply goes through the editor like any plane (route, undo, rebuilt Build tree)
	ed.plane_base = {}
	await ed.apply_feature()
	var made: Array = rig.calls_to("POST /document/parts/PART_BOX/create-plane-features")
	print("SMOKE Apply posts the typed body once and puts it on Undo's stack: ", made.size() == 1 and made[0][1]["plane_type"] == "three_points" and ed.feature_stack.size() == 1)

	# --- Another tool gets unlimited picks back
	table.manager.activate("fillet")
	await rig.frames(3)
	print("SMOKE Choosing another tool lifts the limits and forgets the corners: ", ed.edge_limit == 0 and ed.vertex_limit == 0 and ed.vertices.is_empty() and ed.plane_base2.is_empty())
	print("SMOKE The Build row names how the plane was made: ", BuildTree.summary([{"type": "create_plane", "plane_type": "midplane"}], 0) == "halfway between two" and BuildTree.summary([{"type": "create_plane", "plane_type": "offset_face"}], 0) == "offset" and BuildTree.summary([{"type": "create_plane", "plane_type": "three_points"}], 0) == "through three corners")
	print("SMOKE The request builders refuse what the backend would, with a reason: ", not PartFeatures.create_plane_typed("midplane", [{"fixed": "XY"}], [], [])["ok"] and not PartFeatures.create_plane_typed("vertex", [{}], [], [vertex(1)])["ok"] and not PartFeatures.create_plane_typed("edge", [], [], [vertex(1)])["ok"] and not PartFeatures.create_plane_typed("nonsense", [], [], [])["ok"])
	quit()
