extends SceneTree
## Pattern copies in VR (DIDSA-CAD docs/pattern-followers-and-dissolve-plan.md, V2 and V3), against an in-memory backend (tests/fake_mates_tool.gd).
## V2: a copy node has no occurrence of its own, so adopting the stored poses after a solve never moved it. `copy_poses_from_instances` (pure) reads the
## copies' world poses out of an `assembly-mesh?geometry=false` answer; `_adopt_backend_poses` then moves every copy node of the scope in the SAME undo
## entry as the solved parts, asks for nothing when the scope has no copy node, and Enforce all settles the copies too.
## Run: "$GODOT" --headless --path . --script res://tests/pattern_followers.gd

const FakeMates := preload("res://tests/fake_mates_tool.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")


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

	quit()
