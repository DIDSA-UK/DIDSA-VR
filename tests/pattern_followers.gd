extends SceneTree
## Pattern copies in VR (DIDSA-CAD docs/pattern-followers-and-dissolve-plan.md, V2 and V3), against an in-memory backend (tests/fake_mates_tool.gd).
## V2: a copy node has no occurrence of its own, so adopting the stored poses after a solve never moved it. `copy_poses_from_instances` (pure) reads the
## copies' world poses out of an `assembly-mesh?geometry=false` answer; `_adopt_backend_poses` then moves every copy node of the scope in the SAME undo
## entry as the solved parts, asks for nothing when the scope has no copy node, and Enforce all settles the copies too.
## V3: a copy can be picked for a mate (by its own segment), is never the driven side, and two copies (or a source and its copy) can't be mated;
## a broken mate (the backend's computed status) reads "Broken" in the tablet's list; copies are named like the flat app.
## Run: "$GODOT" --headless --path . --script res://tests/pattern_followers.gd

const FakeMates := preload("res://tests/fake_mates_tool.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")
const GroupIndex := preload("res://scripts/group_index.gd")
const TabletPages := preload("res://scripts/ui/tablet_pages.gd")


func _instance(path: Array, x: float, y: float = 0.0, z: float = 0.0, angle: float = 0.0) -> Dictionary:
	return {"occurrence_path": path, "part_id": "P", "hidden": false,
		"world_transform": {"translation": [x, y, z], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": angle}}


func _node(holder: Node, owner: String, occ: String, instance_path: String, root_id: String, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = instance_path.replace("/", "_").replace("#", "_").replace(":", "_") if instance_path != "" else "node_" + occ
	n.set_meta("owner_part_id", owner)
	n.set_meta("occurrence_id", occ)
	n.set_meta("instance_path", instance_path)
	n.set_meta("group_root", root_id)
	n.position = at
	n.add_to_group("grabbable_parts")
	holder.add_child(n)
	return n


func _initialize() -> void:
	# --- the pure helper
	var instances := [
		_instance([], 0.0),
		_instance(["A"], 10.0),
		_instance(["A#pattern:P:1"], 310.0, 5.0),
		_instance(["S", "A#pattern:P:2"], 610.0),
		_instance(["S#pattern:Q:1", "inner"], 20.0, 0.0, 0.0, 90.0),
		{"occurrence_path": ["junk"]},
		"not an instance",
	]
	var poses := MatesTool.copy_poses_from_instances(instances, 1.0)
	print("SMOKE only the instances on a copy are returned, keyed by their joined path: ", poses.size() == 3 and poses.has("A#pattern:P:1") and poses.has("S/A#pattern:P:2") and poses.has("S#pattern:Q:1/inner") and not poses.has("A") and not poses.has(""))
	print("SMOKE a top-level copy keeps its world pose (millimetres, as the glb's nodes are): ", (poses["A#pattern:P:1"] as Transform3D).origin.is_equal_approx(Vector3(310.0, 5.0, 0.0)))
	print("SMOKE a nested copy and a part inside a copied sub-assembly are read too (rotation included): ", (poses["S/A#pattern:P:2"] as Transform3D).origin.is_equal_approx(Vector3(610.0, 0.0, 0.0)) and (poses["S#pattern:Q:1/inner"] as Transform3D).basis.is_equal_approx(Basis(Vector3(0, 0, 1), deg_to_rad(90.0))))
	var scaled := MatesTool.copy_poses_from_instances(instances, 0.001)
	print("SMOKE the unit scale converts the translation only: ", (scaled["A#pattern:P:1"] as Transform3D).origin.is_equal_approx(Vector3(0.31, 0.005, 0.0)) and (scaled["S#pattern:Q:1/inner"] as Transform3D).basis.is_equal_approx((poses["S#pattern:Q:1/inner"] as Transform3D).basis))
	print("SMOKE malformed rows and an empty answer are ignored: ", MatesTool.copy_poses_from_instances([]).is_empty() and MatesTool.copy_poses_from_instances([{"occurrence_path": ["A#pattern:P:1"]}]).is_empty())
	print("SMOKE the verified unit for the nodes is the backend's own millimetres (no spawn_scale): ", MatesTool.COPY_UNIT_SCALE == 1.0)

	# --- adopting the stored poses moves the copies in the same undo entry
	var holder := Node3D.new()
	root.add_child(holder)
	var mt = FakeMates.new()
	holder.add_child(mt)
	var stack := preload("res://scripts/command_stack.gd").new()
	mt.command_stack = stack
	await process_frame
	mt.configure_backend("http://fake", "key")
	mt.doc_names = {"R": "Root"}
	mt.doc_occurrences = {"R": [FakeMates.row("A", "PA"), FakeMates.row("B", "PB", false, [100.0, 0.0, 0.0])], "PA": [], "PB": []}
	mt.doc_mates = {"R": [{"id": "m1", "references": [{"occurrence_id": "B"}, {"occurrence_id": "A#pattern:P:1"}]}]}
	var a := _node(holder, "R", "A", "A", "R", Vector3(0, 0, 0))
	var b := _node(holder, "R", "B", "B", "R", Vector3(100, 0, 0))
	var copy := _node(holder, "R", "", "A#pattern:P:1", "R", Vector3(300, 0, 0))
	var other_scope_copy := _node(holder, "R2", "", "X#pattern:P:1", "R2", Vector3(5, 5, 5)) # a copy of another scope: not ours to move
	await mt.refresh_state("R")
	# the backend moved A and B by +50 in z; the copy follows A
	mt.doc_occurrences["R"][0]["transform"]["translation"] = [0.0, 0.0, 50.0]
	mt.doc_occurrences["R"][1]["transform"]["translation"] = [100.0, 0.0, 50.0]
	mt.doc_instances = {"R": [_instance(["A"], 0.0, 0.0, 50.0), _instance(["B"], 100.0, 0.0, 50.0), _instance(["A#pattern:P:1"], 300.0, 0.0, 50.0)]}
	mt.calls.clear()
	var adopted: bool = await mt._adopt_backend_poses("R", "solve B")
	var mesh_calls: Array = mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("assembly-mesh"))
	print("SMOKE the solved parts and the copy node all land where the backend puts them: ", adopted and a.position.is_equal_approx(Vector3(0, 0, 50)) and b.position.is_equal_approx(Vector3(100, 0, 50)) and copy.position.is_equal_approx(Vector3(300, 0, 50)))
	print("SMOKE ...with ONE lean request (geometry=false) to the scope's root, and another scope's copy left alone: ", mesh_calls.size() == 1 and str(mesh_calls[0]["path"]).begins_with("/parts/R/assembly-mesh") and str(mesh_calls[0]["path"]).contains("geometry=false") and other_scope_copy.position.is_equal_approx(Vector3(5, 5, 5)))
	stack.undo()
	print("SMOKE ...and one undo step puts the parts AND the copy back: ", a.position.is_equal_approx(Vector3(0, 0, 0)) and b.position.is_equal_approx(Vector3(100, 0, 0)) and copy.position.is_equal_approx(Vector3(300, 0, 0)))
	stack.redo()
	print("SMOKE ...and redo moves them all again: ", copy.position.is_equal_approx(Vector3(300, 0, 50)) and b.position.is_equal_approx(Vector3(100, 0, 50)))
	# no copy node in the scope: no request at all
	copy.remove_from_group("grabbable_parts")
	mt.calls.clear()
	await mt._adopt_backend_poses("R", "solve B")
	print("SMOKE a scope with no copy node asks for no assembly-mesh: ", mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("assembly-mesh")).is_empty())
	copy.add_to_group("grabbable_parts")

	# --- Enforce all and the relaxed sandbox's return settle the copies too
	copy.position = Vector3(300, 0, 0)
	mt.calls.clear()
	var outcome: Dictionary = await mt.enforce_all("R")
	print("SMOKE Enforce all on a copy mate solves A and B and leaves the copy with its source: ", outcome["ok"] and copy.position.is_equal_approx(Vector3(300, 0, 50)) and mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("#")).is_empty())
	copy.position = Vector3(300, 0, 0)
	mt.set_relaxed(true)
	mt.note_sandbox_mate("R", "B")
	await mt.return_parts()
	print("SMOKE returning from the relaxed sandbox settles the copy as well: ", copy.position.is_equal_approx(Vector3(300, 0, 50)))
	mt.set_relaxed(false)

	# --- V3: picking a copy
	var plain := Node3D.new()
	plain.set_meta("owner_part_id", "R")
	plain.set_meta("occurrence_id", "")
	plain.set_meta("instance_path", "")
	var root_content_ref := MatesTool.copy_occurrence_ref(plain)
	print("SMOKE root content is not a copy (its pick is still refused): ", root_content_ref.is_empty())
	var copy_ref := MatesTool.copy_occurrence_ref(copy)
	print("SMOKE a copy node yields its own segment read in its owner Part: ", copy_ref == {"owner_part_id": "R", "occurrence_id": "A#pattern:P:1"})
	var nested := _node(holder, "PS", "", "S/A#pattern:P:2", "R", Vector3.ZERO)
	print("SMOKE a nested copy yields the last segment, in the Part that owns it: ", MatesTool.copy_occurrence_ref(nested) == {"owner_part_id": "PS", "occurrence_id": "A#pattern:P:2"})
	print("SMOKE an ordinary placed part is not a copy: ", MatesTool.copy_occurrence_ref(a).is_empty())

	var picker = FakeMates.new()
	holder.add_child(picker)
	await process_frame
	picker.configure_backend("", "") # no backend: nothing is requested
	picker.set_active(true)
	picker.occurrences = {"A": {"fixed": false}, "B": {"fixed": false}}
	var root_content := _node(holder, "R", "", "", "R", Vector3.ZERO)
	root_content.name = "RootContent"
	picker.try_pick(root_content, 0)
	print("SMOKE picking true root content is refused with the same message: ", picker.status_text() == "Can't mate the assembly's own root content — pick a placed part.")
	print("SMOKE a copy's occurrence reference is accepted by the pick validation (the face identity is the next check): ", picker._validate_pick(copy_ref, {"body_id": "b", "shape_type": "face", "index": 1}) == "")
	picker._picks.append({"owner_part_id": "R", "occurrence_id": "A#pattern:P:1", "subshape_ref": {"body_id": "b", "shape_type": "face", "index": 1}, "label": "Copy", "part": copy, "face_index": 0, "entity": {}, "kind": "face"})
	var second := {"owner_part_id": "R", "occurrence_id": "B"}
	# a real pick through try_pick: a copy node with face identity, then an ordinary part
	var pick_tool = FakeMates.new()
	holder.add_child(pick_tool)
	await process_frame
	pick_tool.set_active(true)
	pick_tool.occurrences = {"A": {"fixed": false}, "B": {"fixed": false}}
	var face_copy := _node(holder, "R", "", "A#pattern:P:1", "R", Vector3.ZERO)
	face_copy.set_meta("face_ids", [7, 8])
	face_copy.set_meta("body_ids", ["leaf-body", "leaf-body"])
	face_copy.name = "FaceCopy"
	var face_b := _node(holder, "R", "B", "B", "R", Vector3.ZERO)
	face_b.set_meta("face_ids", [3])
	face_b.set_meta("body_ids", ["mover-body"])
	face_b.name = "FaceB"
	pick_tool.try_pick(face_copy, 1)
	pick_tool.try_pick(face_b, 0)
	var picked: Array = pick_tool._picks
	print("SMOKE try_pick accepts a copy: its pick carries the copy's segment and the face the laser hit: ", picked.size() == 2 and picked[0]["occurrence_id"] == "A#pattern:P:1" and picked[0]["owner_part_id"] == "R" and picked[0]["subshape_ref"] == {"body_id": "leaf-body", "shape_type": "face", "index": 8} and not pick_tool.status_text().begins_with("Can't"))
	var pick_body: Dictionary = pick_tool.build_create_payload()
	print("SMOKE ...and builds the MateEntityRef the backend takes (copy first, the driven B second): ", pick_body["references"][0] == {"occurrence_id": "A#pattern:P:1", "subshape_ref": {"body_id": "leaf-body", "shape_type": "face", "index": 8}} and pick_body["references"][1]["occurrence_id"] == "B" and pick_tool._driven_for_picks() == "B")
	print("SMOKE a copy and an ordinary part is a valid pair: ", picker._validate_pick(second, {"body_id": "b", "shape_type": "face", "index": 2}) == "")
	print("SMOKE ...two copies, or a source with its own copy, are refused: ", picker._validate_pick({"owner_part_id": "R", "occurrence_id": "C#pattern:P:3"}, {"body_id": "b", "shape_type": "face", "index": 2}).contains("not to another copy") and picker._validate_pick({"owner_part_id": "R", "occurrence_id": "A"}, {"body_id": "b", "shape_type": "face", "index": 2}).contains("follows its source"))
	print("SMOKE the driven side is never the copy, whichever pick it was: ", picker._choose_driven("A#pattern:P:1", "B") == "B" and picker._choose_driven("B", "A#pattern:P:1") == "B")
	var payload_picks := [picker._picks[0], {"owner_part_id": "R", "occurrence_id": "B", "subshape_ref": {"body_id": "b", "shape_type": "face", "index": 2}, "label": "B", "part": b, "face_index": 0, "entity": {}, "kind": "face"}]
	picker._picks.clear()
	for pick in payload_picks:
		picker._picks.append(pick)
	var body: Dictionary = picker.build_create_payload()
	print("SMOKE the create payload carries the copy's segment in its MateEntityRef and the driven id is B: ", body["references"][0]["occurrence_id"] == "A#pattern:P:1" and body["references"][0]["subshape_ref"] == {"body_id": "b", "shape_type": "face", "index": 1} and picker._driven_for_picks() == "B")

	# --- V3: broken mates in the tablet's list
	var pages := TabletPages.new()
	pages._mates_tool = mt
	mt.mates = [{"id": "ok1", "type": "coincident", "references": [], "status": "ok"},
		{"id": "bad1", "type": "coincident", "references": [], "status": "broken"},
		{"id": "old1", "type": "coincident", "references": []},
		{"id": "sup1", "type": "coincident", "references": [], "status": "broken", "suppressed": true}]
	var rows: Array = pages._mates_rows()
	print("SMOKE a broken mate reads Broken after its name, in the error state, with the reason: ", rows[1]["title"] == "Coincident - Broken" and rows[1]["state"] == "error" and bool(rows[1]["broken"]) and str(rows[1]["subtitle"]).contains("can't be satisfied"))
	print("SMOKE an ok mate, one from an older backend (no status) and a suppressed one are plain: ", rows[0]["title"] == "Coincident" and rows[0]["state"] == "normal" and rows[2]["title"] == "Coincident" and not bool(rows[2]["broken"]) and rows[3]["title"] == "Coincident" and rows[3]["state"] == "normal")
	var panel_script := load("res://scripts/ui/side_panel_ui.gd")
	var panel = panel_script.new()
	print("SMOKE a broken row and a plain row differ in the list's signature (the row is rebuilt when the status changes): ", panel._signature_of("Mates", [rows[0]], "") != panel._signature_of("Mates", [rows[1]], ""))
	panel.free()

	# --- V3: copy names like the flat app
	var patterns := [{"id": "p1", "pattern_type": "linear"}, {"id": "p2", "pattern_type": "circular"}, {"id": "p3", "pattern_type": "linear"}]
	print("SMOKE pattern names count by type in list order (Linear 1, Circular 1, Linear 2): ", GroupIndex.pattern_display_name(patterns, "p1") == "Linear 1" and GroupIndex.pattern_display_name(patterns, "p2") == "Circular 1" and GroupIndex.pattern_display_name(patterns, "p3") == "Linear 2" and GroupIndex.pattern_display_name(patterns, "nope") == "")
	print("SMOKE a copy is labelled <source> [<pattern> #<index + 1>]: ", GroupIndex.copy_label("Short Rail", "rail#pattern:p3:1", patterns) == "Short Rail [Linear 2 #2]" and GroupIndex.copy_label("Short Rail", "rail#pattern:p2:3", patterns) == "Short Rail [Circular 1 #4]")
	print("SMOKE ...and keeps the old label when the pattern list is not at hand: ", GroupIndex.copy_label("Bolt", "bolt#pattern:p1:2", []) == "Bolt (copy 2)" and GroupIndex.copy_label("Bolt", "bolt#pattern:zzz:2", patterns) == "Bolt (copy 2)")
	var tag_node := Node3D.new()
	tag_node.set_meta("instance_path", "rail#pattern:p3:1")
	tag_node.set_meta("owner_part_id", "R")
	tag_node.set_meta("occurrence_id", "")
	holder.add_child(tag_node)
	var entries := [{"owner": "R", "occ": "", "path": [], "parts": [], "names": [], "part": "R", "hidden": false}, {"owner": "R", "occ": "rail", "path": ["rail"], "parts": ["PR"], "names": ["Short Rail"], "part": "PR", "hidden": false}]
	GroupIndex.assign([tag_node], entries, "R", false, {"R": patterns})
	print("SMOKE group_index.assign names a tagged copy from the owning Part's list: ", tag_node.get_meta("group_names", []) == ["Short Rail [Linear 2 #2]"])
	GroupIndex.assign([tag_node], entries, "R", false, {})
	print("SMOKE ...and without a list, the old label: ", tag_node.get_meta("group_names", []) == ["Short Rail (copy 1)"])
	quit()
