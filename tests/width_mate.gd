extends SceneTree
## Width mate (docs/width-mate-plan.md in DIDSA-CAD): mates_tool.gd's four-pick state machine, payload and driven part, the highlight
## colours per pair, and mate_health.gd over a mid-plane reference (the faces it names, remaking on the equivalent face, "faces no
## longer parallel"). Pure logic against manually-tagged stand-ins; the backend half is DIDSA-CAD's tests/test_width_mate*.py.
## Run: "$GODOT" --headless --path . --script res://tests/width_mate.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const Health := preload("res://scripts/design_table/mate_health.gd")


func _tagged_part(owner_part_id: String, occurrence_id: String, body_id: String, face_ids: Array, name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", owner_part_id)
	part.set_meta("occurrence_id", occurrence_id)
	part.set_meta("face_ids", face_ids)
	var bodies := []
	for _i in face_ids.size():
		bodies.append(body_id)
	part.set_meta("body_ids", bodies)
	return part


func _wall(x: float, facing_plus_x: bool) -> Array:
	var a := Vector3(x, 0, 0)
	var b := Vector3(x, 10, 0)
	var c := Vector3(x, 10, 10)
	var d := Vector3(x, 0, 10)
	return [[a, b, d], [b, c, d]] if facing_plus_x else [[a, d, b], [d, c, b]]


func _mesh_part(faces: Array, occurrence: String) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var face_ids: Array = []
	var body_ids: Array = []
	for fid in faces.size():
		for tri in faces[fid]:
			verts.append_array([tri[0], tri[1], tri[2]])
			face_ids.append(fid)
			body_ids.append("B")
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.set_meta("face_ids", face_ids)
	node.set_meta("body_ids", body_ids)
	node.set_meta("topology", {"B": {"face_kinds": ["plane", "plane"], "edges": {}, "vertices": {}, "vertex_at": {}, "face_edges": [], "edge_kinds": {}}})
	node.set_meta("occurrence_id", occurrence)
	return node


func _initialize() -> void:
	var tool := MatesTool.new()
	tool.set_active(true)
	print("SMOKE Width is one of the mate types: ", MatesTool.MATE_TYPES.has("width") and MatesTool.WIDTH_TYPE == "width")
	tool.mate_type = "width"
	print("SMOKE a Width mate needs four picks: ", tool.is_width() and tool.pick_target() == 4)
	print("SMOKE the status counts N of 4 from the first pick: ", tool.status_text().begins_with("Width 1 of 4"))

	var bar_l := _tagged_part("root", "barL", "bl", [0, 1, 2], "BarL")
	var bar_r := _tagged_part("root", "barR", "br", [0, 1, 2], "BarR")
	var plate := _tagged_part("root", "plate", "pl", [0, 1, 2, 3], "Plate")
	var plate_b := _tagged_part("root", "plateB", "pb", [0, 1], "PlateB")
	var elsewhere := _tagged_part("other-root", "occ-x", "bx", [0], "Elsewhere")

	# --- 3 parts: the gap is two loose bars, the part to centre one plate
	tool.try_pick(bar_l, 1)
	print("SMOKE first gap face recorded, status asks for the second: ", tool.picked_labels() == ["BarL"] and tool.status_text().begins_with("Width 2 of 4"))
	tool.try_pick(bar_l, 1)
	print("SMOKE the same face twice is refused: ", tool.picked_labels().size() == 1 and tool.status_text() == "That face is already picked.")
	tool.try_pick(elsewhere, 0)
	print("SMOKE a part from another assembly is refused: ", tool.picked_labels().size() == 1 and tool.status_text().begins_with("All the parts must belong"))
	tool.try_pick(bar_r, 2)
	print("SMOKE the second gap face may be on another part: ", tool.picked_labels() == ["BarL", "BarR"] and tool.status_text().begins_with("Width 3 of 4"))
	tool.try_pick(bar_r, 0)
	print("SMOKE the part to centre cannot be a part of the gap: ", tool.picked_labels().size() == 2 and tool.status_text().begins_with("The part to centre must be a different part"))
	tool.try_pick(plate, 0)
	tool.try_pick(plate, 3)
	print("SMOKE four faces on three parts are ready: ", tool.picked_labels() == ["BarL", "BarR", "Plate", "Plate"] and tool.can_create())
	tool.try_pick(plate, 1)
	print("SMOKE a fifth pick is ignored: ", tool.picked_labels().size() == 4)

	var refs: Array = MatesTool.width_references(tool._picks)
	print("SMOKE two mid-plane references, the gap first: ", refs.size() == 2 and refs[0]["occurrence_id"] == "barL" and refs[1]["occurrence_id"] == "plate")
	print("SMOKE a pair on two parts names the second part, a pair on one part does not: ", refs[0]["midplane"].get("b_occurrence_id") == "barR" and not refs[1]["midplane"].has("b_occurrence_id"))
	print("SMOKE each side names its faces as plane refs: ", refs[0]["midplane"]["a"] == {"face_ref": {"body_id": "bl", "shape_type": "face", "index": 1}} and refs[1]["midplane"]["b"] == {"face_ref": {"body_id": "pl", "shape_type": "face", "index": 3}})
	print("SMOKE no reference carries a subshape_ref: ", not refs[0].has("subshape_ref") and not refs[1].has("subshape_ref"))

	var payload: Dictionary = tool.build_create_payload()
	print("SMOKE centred is a plain coincident mate with no value: ", payload["type"] == "coincident" and not payload.has("value") and payload["references"].size() == 2)
	tool.width_offset = 4.0
	payload = tool.build_create_payload()
	print("SMOKE with an offset it is a distance mate carrying the offset: ", payload["type"] == "distance" and payload["value"] == 4.0)
	tool.mate_alignment = "anti_aligned"
	tool.mate_secondary_flip = 1
	payload = tool.build_create_payload()
	print("SMOKE a picked branch is sent like any mate: ", payload["alignment"] == "anti_aligned" and payload["secondary_flip"] == true)
	tool.width_offset = 0.0
	print("SMOKE the wire type helper: ", MatesTool.width_wire_type(0.0) == "coincident" and MatesTool.width_wire_type(2.5) == "distance")

	# --- the part that moves: the part(s) to centre before the gap's, skipping grounded ones
	print("SMOKE the part to centre is driven: ", tool._driven_for_picks() == "plate")
	tool.occurrences = {"plate": {"fixed": true}}
	print("SMOKE a grounded part to centre falls back to the gap: ", tool._driven_for_picks() == "barL")
	tool.occurrences = {}

	# --- highlight colours: one per pair
	var entries := tool.picked_entities()
	var slots := []
	for e in entries:
		slots.append(int(e["colour_slot"]))
	print("SMOKE the four faces light in two colours, one per pair: ", slots == [0, 0, 1, 1])

	# --- Undo pick and switching type
	tool.back_pick()
	print("SMOKE Undo pick takes back the last face: ", tool.picked_labels().size() == 3 and not tool.can_create())
	tool.mate_type = "coincident"
	print("SMOKE leaving Width starts the picks over: ", tool.picked_labels().is_empty() and tool.pick_target() == 2)
	var cross_ok := true
	tool.try_pick(bar_l, 1)
	tool.mate_type = "width"
	cross_ok = cross_ok and tool.picked_labels().is_empty()
	print("SMOKE entering Width starts the picks over: ", cross_ok)
	tool.mate_type = "coincident"
	tool.try_pick(bar_l, 1)
	tool.try_pick(plate, 0)
	var two_payload: Dictionary = tool.build_create_payload()
	print("SMOKE the two-pick types are untouched: ", two_payload["type"] == "coincident" and two_payload["references"][0].has("subshape_ref") and not two_payload["references"][0].has("midplane") and tool.can_create())

	# --- 4 parts: the part to centre is two parts as well; and a face only (no edges or corners)
	tool.clear_picks()
	tool.mate_type = "width"
	tool.try_pick(bar_l, 1)
	tool.try_pick(bar_r, 2)
	tool.try_pick(plate, 0)
	tool.try_pick(plate_b, 1)
	var four: Array = MatesTool.width_references(tool._picks)
	print("SMOKE a tab of two parts is ready and names its second part: ", tool.can_create() and four[1]["midplane"]["b_occurrence_id"] == "plateB" and four[0]["midplane"]["b_occurrence_id"] == "barR")
	print("SMOKE 4 parts: the first of the tab's parts is driven: ", tool._driven_for_picks() == "plate")
	tool.clear_picks()
	tool.try_pick(bar_l, 1, {"kind": "edge", "body_id": "bl", "index": 3, "face_index": 1, "key": "bl:e3"})
	print("SMOKE an edge or corner is refused for a Width mate: ", tool.picked_labels().is_empty() and tool.status_text() == "A Width mate is made from faces.")
	tool.free()

	# --- the progress text
	var texts := []
	for n in 5:
		texts.append(MatesTool.width_progress_text(n))
	print("SMOKE the progress text names every step: ", texts[0].contains("1 of 4") and texts[1].contains("2 of 4") and texts[2].contains("3 of 4") and texts[3].contains("4 of 4") and texts[4].contains("all four"))

	# --- mate_health over a mid-plane reference
	var left := _mesh_part([_wall(0, false), _wall(60, true)], "barL") # faces 0 (-x at 0) and 1 (+x at 60)
	var right := _mesh_part([_wall(0, false), _wall(60, true)], "barR")
	var width_mate := {"id": "w1", "type": "coincident", "references": [
		{"occurrence_id": "barL", "midplane": {"a": {"face_ref": {"body_id": "B", "shape_type": "face", "index": 1}}, "b": {"face_ref": {"body_id": "B", "shape_type": "face", "index": 0}}, "b_occurrence_id": "barR"}},
		{"occurrence_id": "plate", "midplane": {"a": {"face_ref": {"body_id": "P", "shape_type": "face", "index": 0}}, "b": {"face_ref": {"body_id": "P", "shape_type": "face", "index": 1}}}},
	]}
	var faces: Array = Health.face_refs(width_mate["references"][0])
	print("SMOKE a mid-plane reference names two faces, the second on its own part: ", faces.size() == 2 and faces[0]["occurrence_id"] == "barL" and faces[1]["occurrence_id"] == "barR")
	print("SMOKE a plain reference still names its one face: ", Health.face_refs({"occurrence_id": "o", "subshape_ref": {"body_id": "B", "shape_type": "face", "index": 2}}).size() == 1)
	var captured: Array = Health.capture([left, right], [width_mate])
	print("SMOKE capture records both faces of the gap, on both bars: ", captured.size() == 2 and captured[0]["occurrence_id"] == "barL" and captured[1]["occurrence_id"] == "barR")
	var renumbered := _mesh_part([_wall(60, true), _wall(0, false)], "barR") # the two faces swapped places in the numbering
	var drift: Array = Health.drifted(captured, [left, renumbered])
	print("SMOKE an edit that renumbers a gap face is reported as drift: ", drift.size() == 1 and drift[0]["mate_id"] == "w1" and drift[0]["occurrence_id"] == "barR")
	var plan: Array = Health.remake_plan([width_mate], drift, captured, [left, renumbered])
	var new_b: Dictionary = plan[0]["references"][0]["midplane"]["b"]["face_ref"] if plan.size() == 1 else {}
	print("SMOKE it can be remade on the equivalent face, inside the mid-plane: ", plan.size() == 1 and int(new_b.get("index", -1)) == 1 and int(plan[0]["references"][0]["midplane"]["a"]["face_ref"]["index"]) == 1)
	print("SMOKE the stored mate was not edited by planning the remake: ", int(width_mate["references"][0]["midplane"]["b"]["face_ref"]["index"]) == 0)

	# --- faces no longer parallel: a state of its own
	var pair_mate := {"id": "w2", "type": "coincident", "references": [
		{"occurrence_id": "barL", "midplane": {"a": {"face_ref": {"body_id": "B", "shape_type": "face", "index": 0}}, "b": {"face_ref": {"body_id": "B", "shape_type": "face", "index": 1}}}},
		{"occurrence_id": "plate", "subshape_ref": {"body_id": "P", "shape_type": "face", "index": 0}},
	]}
	print("SMOKE two parallel faces are not reported: ", Health.unparallel_pairs([pair_mate], [left]).is_empty())
	var tilted := _mesh_part([_wall(0, false), [[Vector3(60, 0, 0), Vector3(70, 10, 0), Vector3(60, 10, 10)]]], "barL") # the second face is turned about 55 degrees
	var broken: Array = Health.unparallel_pairs([pair_mate], [tilted])
	print("SMOKE faces that stopped being parallel are reported, per mate and reference: ", broken.size() == 1 and broken[0]["mate_id"] == "w2" and broken[0]["reference"] == 0)
	print("SMOKE ...and a lost face is not a parallel report: ", Health.unparallel_pairs([{"id": "w3", "references": [{"occurrence_id": "barL", "midplane": {"a": {"face_ref": {"body_id": "B", "shape_type": "face", "index": 0}}, "b": {"face_ref": {"body_id": "B", "shape_type": "face", "index": 9}}}}]}], [left]).is_empty())
	for n in [left, right, renumbered, tilted, bar_l, bar_r, plate, plate_b, elsewhere]:
		n.free()
	quit()
