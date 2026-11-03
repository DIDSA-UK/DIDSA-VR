extends SceneTree
## Pattern copies move with their source DURING a drag (DIDSA-CAD docs/pattern-followers-smoothness-plan.md S3) and after a solve inside a sub-assembly
## (S4), against the in-memory backend (tests/fake_mates_tool.gd), headless.
## S3: `constrain_drag` shows the dragged part and its followers each frame from the last anchor's model; now every copy of a moving member's pattern is
## set to `pattern_copy_pose(pattern, the member's pose this frame, index)` in the same call and what is nested under a copy moves with it. The commit
## (and every solve) stays the authority: it puts the copies where the server says, ONE undo entry covers them with the members, and a refused commit puts
## them back. S4: `_copy_pose_changes(sub)` also reads the root of every loaded scope that has the solved Part below it.
## Run: "$GODOT" --headless --path . --script res://tests/pattern_follow_live.gd

const FakeMates := preload("res://tests/fake_mates_tool.gd")
const Se3 := preload("res://scripts/motion/se3.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const MotionBlender := preload("res://scripts/motion/motion_blender.gd")


func _node(holder: Node, owner: String, occ: String, instance_path: String, root_id: String, at: Vector3, parts: Array = []) -> Node3D:
	var n := Node3D.new()
	n.name = ("n_" + instance_path.replace("/", "_").replace("#", "_").replace(":", "_")) if instance_path != "" else "node_" + occ
	n.set_meta("owner_part_id", owner)
	n.set_meta("occurrence_id", occ)
	n.set_meta("instance_path", instance_path)
	n.set_meta("group_root", root_id)
	n.set_meta("group_parts", parts)
	n.position = at
	n.add_to_group("grabbable_parts")
	holder.add_child(n)
	return n


func _instance(path: Array, x: float, y: float = 0.0, z: float = 0.0) -> Dictionary:
	return {"occurrence_path": path, "part_id": "P", "hidden": false,
		"world_transform": {"translation": [x, y, z], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}}


func _pattern(extra: Dictionary = {}) -> Dictionary:
	var p := {"id": "P", "source_occurrence_ids": ["A"], "pattern_type": "linear", "direction": [1.0, 0.0, 0.0], "count": 3, "spacing": 300.0, "reverse": false,
		"direction_2": [0.0, 1.0, 0.0], "count_2": 1, "spacing_2": 0.0, "reverse_2": false, "axis": null, "count_angular": 1, "angle_total": 360.0,
		"reverse_angular": false, "skip_indices": [], "orient_with_rotation": true, "suppressed": false}
	p.merge(extra, true)
	return p


## A drag of A (grabbed) with B riding along in x, seeded as tests/mates_motion.gd does (no network for the anchor).
func _start_drag(mt, a: Node3D, b: Node3D) -> Dictionary:
	var state: Dictionary = mt._new_drag_state(a)
	state["running"] = true
	var ref_a := Se3.make_pose([0.0, 0.0, 0.0], Se3.identity())
	var ref_b := Se3.make_pose([100.0, 0.0, 0.0], Se3.identity())
	# free: A and B slide in x together, A slides in y alone
	state["hyst"].on_anchor(Projector.from_anchor([ref_a, ref_b], [[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]], 50.0))
	state["members"] = ["A", "B"]
	state["blender"] = MotionBlender.new(2)
	state["nodes"] = {"A": a, "B": b}
	state["starts"] = {"B": b.transform}
	mt._drag[a] = state
	return state


func _initialize() -> void:
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
	mt.doc_patterns = {"R": [_pattern()]}
	var a := _node(holder, "R", "A", "A", "R", Vector3(0, 0, 0))
	var b := _node(holder, "R", "B", "B", "R", Vector3(100, 0, 0))
	var copy1 := _node(holder, "R", "", "A#pattern:P:1", "R", Vector3(300, 0, 0))
	var copy2 := _node(holder, "R", "", "A#pattern:P:2", "R", Vector3(600, 0, 0))
	var inner := _node(holder, "R", "", "A#pattern:P:1/inner", "R", Vector3(305, 2, 0))
	var elsewhere := _node(holder, "R2", "", "X#pattern:P:1", "R2", Vector3(5, 5, 5)) # another scope's copy: not ours to move
	await mt.refresh_state("R")

	# --- S3: the copies follow the source frame by frame
	var state := _start_drag(mt, a, b)
	var requests_before: int = mt.stat_requests
	var no_patterns_yet: Transform3D = mt.constrain_drag(a, Transform3D(Basis.IDENTITY, Vector3(10.0, 0.0, 0.0)))
	print("SMOKE before the scope's patterns are read, the drag moves the part and its follower but no copy: ", no_patterns_yet.origin.is_equal_approx(Vector3(10, 0, 0)) and b.position.is_equal_approx(Vector3(110, 0, 0)) and copy1.position.is_equal_approx(Vector3(300, 0, 0)))
	await mt._ensure_patterns("R")
	print("SMOKE the patterns are read once per scope (one GET) and cached: ", mt._pattern_cache.has("R") and (mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("component-patterns")).size() == 1))
	await mt._ensure_patterns("R")
	print("SMOKE ...a second ask makes no request: ", mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("component-patterns")).size() == 1)
	mt.calls.clear()
	var shown_x: Array = []
	var follow_ok := true
	var nested_ok := true
	var other_ok := true
	for i in 10:
		var hand := Transform3D(Basis.IDENTITY, Vector3(20.0 + 15.0 * i, 6.0, 0.0))
		var shown: Transform3D = mt.constrain_drag(a, hand)
		shown_x.append(shown.origin.x)
		# copy i = the step (300 i along x) after the part's live pose, every frame
		follow_ok = follow_ok and copy1.position.is_equal_approx(shown.origin + Vector3(300, 0, 0)) and copy2.position.is_equal_approx(shown.origin + Vector3(600, 0, 0))
		nested_ok = nested_ok and inner.position.is_equal_approx(copy1.position + Vector3(5, 2, 0))
		other_ok = other_ok and elsewhere.position.is_equal_approx(Vector3(5, 5, 5))
	print("SMOKE every frame of the drag puts each copy at the pattern step after the part's live pose: ", follow_ok and shown_x[9] > shown_x[0] + 100.0)
	print("SMOKE ...what is nested under a copy keeps its place relative to it: ", nested_ok)
	print("SMOKE ...another scope's copy is left alone, and the follower still rides along: ", other_ok and b.position.x > 100.0 + 100.0)
	print("SMOKE ...all without a request (the copies are computed locally): ", mt.calls.is_empty() and mt.stat_requests == requests_before)
	var live_a: Vector3 = a.position
	print("SMOKE the pre-grab poses of the copies (and the nested part) are kept for the undo entry: ", (state["copy_starts"] as Dictionary).size() == 3 and (state["copy_starts"][copy1] as Transform3D).origin.is_equal_approx(Vector3(300, 0, 0)) and (state["copy_starts"][inner] as Transform3D).origin.is_equal_approx(Vector3(305, 2, 0)))

	# --- the commit stays the authority: the server's poses land, ONE undo entry covers members and copies, undo restores the pre-grab poses
	state["active"] = false
	state["wish"] = Se3.from_transform3d(Transform3D(Basis.IDENTITY, Vector3(150.0, 6.0, 0.0)))
	var committed_pose := {"translation": [150.0, 6.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}
	mt.doc_mate_motion = {"R|A": {"converged": true, "committed": true, "members": [
		{"occurrence_id": "A", "transform": committed_pose},
		{"occurrence_id": "B", "transform": {"translation": [250.0, 0.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}}]}}
	mt.doc_instances = {"R": [_instance(["A"], 150.0, 6.0), _instance(["A#pattern:P:1"], 450.0, 6.0), _instance(["A#pattern:P:2"], 750.0, 6.0), _instance(["A#pattern:P:1", "inner"], 455.0, 8.0)]}
	var undo_before: int = stack.history_labels().size()
	await mt._finish_drag(a, state)
	print("SMOKE the commit puts the part, its follower AND every copy where the server says: ", a.position.is_equal_approx(Vector3(150, 6, 0)) and b.position.is_equal_approx(Vector3(250, 0, 0)) and copy1.position.is_equal_approx(Vector3(450, 6, 0)) and copy2.position.is_equal_approx(Vector3(750, 6, 0)) and inner.position.is_equal_approx(Vector3(455, 8, 0)))
	print("SMOKE ...with ONE lean request for the copies (geometry=false, the scope's root): ", mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("assembly-mesh")).size() == 1)
	print("SMOKE ...and the drag is exactly ONE undo entry: ", stack.history_labels().size() == undo_before + 1)
	stack.undo()
	print("SMOKE ...and ONE undo step puts the part, the follower and the copies back to where the grab found them (not to the live pose): ", a.position.is_equal_approx(Vector3(0, 0, 0)) and b.position.is_equal_approx(Vector3(100, 0, 0)) and copy1.position.is_equal_approx(Vector3(300, 0, 0)) and copy2.position.is_equal_approx(Vector3(600, 0, 0)) and inner.position.is_equal_approx(Vector3(305, 2, 0)))
	stack.redo()
	print("SMOKE ...and redo moves them all again: ", copy1.position.is_equal_approx(Vector3(450, 6, 0)) and a.position.is_equal_approx(Vector3(150, 6, 0)))

	# --- a refused commit puts the copies back with everything else
	a.position = Vector3(0, 0, 0)
	b.position = Vector3(100, 0, 0)
	copy1.position = Vector3(300, 0, 0)
	copy2.position = Vector3(600, 0, 0)
	inner.position = Vector3(305, 2, 0)
	var state2 := _start_drag(mt, a, b)
	var live2: Transform3D = mt.constrain_drag(a, Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 0.0)))
	a.transform = live2 # (the controller puts the grabbed node where constrain_drag says)
	var moved_live: bool = copy1.position.is_equal_approx(live2.origin + Vector3(300, 0, 0)) and not copy1.position.is_equal_approx(Vector3(300, 0, 0))
	state2["active"] = false
	state2["wish"] = Se3.from_transform3d(Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 0.0)))
	mt.doc_mate_motion = {}
	await mt._finish_drag(a, state2)
	print("SMOKE a refused commit (422) puts the part, the follower and every copy back where the grab found them: ", moved_live and a.position.is_equal_approx(Vector3(0, 0, 0)) and b.position.is_equal_approx(Vector3(100, 0, 0)) and copy1.position.is_equal_approx(Vector3(300, 0, 0)) and copy2.position.is_equal_approx(Vector3(600, 0, 0)) and inner.position.is_equal_approx(Vector3(305, 2, 0)))

	# --- a suppressed pattern, and a skipped copy, stay put
	a.position = Vector3(0, 0, 0)
	b.position = Vector3(100, 0, 0)
	mt._pattern_cache["R"] = [_pattern({"suppressed": true})]
	var state3 := _start_drag(mt, a, b)
	mt.constrain_drag(a, Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 0.0)))
	print("SMOKE a suppressed pattern's copies stay where they are: ", copy1.position.is_equal_approx(Vector3(300, 0, 0)) and copy2.position.is_equal_approx(Vector3(600, 0, 0)))
	mt._drag.erase(a)
	mt._pattern_cache["R"] = [_pattern({"skip_indices": [2]})]
	var state4 := _start_drag(mt, a, b)
	var live4: Transform3D = mt.constrain_drag(a, Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 0.0)))
	print("SMOKE a skipped copy stays where it is while the others follow: ", copy2.position.is_equal_approx(Vector3(600, 0, 0)) and copy1.position.is_equal_approx(live4.origin + Vector3(300, 0, 0)))
	mt._drag.erase(a)

	# --- a Circular pattern that orients turns the copy with the step; one that does not keeps the source's rotation (here the source does not turn)
	a.position = Vector3(0, 0, 0)
	b.position = Vector3(100, 0, 0)
	var circ := _pattern({"pattern_type": "circular", "count_angular": 4, "angle_total": 360.0, "axis": {"origin": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0]}})
	mt._pattern_cache["R"] = [circ]
	var state5 := _start_drag(mt, a, b)
	var live5: Transform3D = mt.constrain_drag(a, Transform3D(Basis.IDENTITY, Vector3(200.0, 0.0, 0.0)))
	var quarter := Basis(Vector3(0, 0, 1), deg_to_rad(90.0))
	print("SMOKE a Circular pattern: copy 1 stands a quarter turn round the axis and is turned with it: ", copy1.position.is_equal_approx(Vector3(0, live5.origin.x, 0)) and copy1.basis.is_equal_approx(quarter))
	mt._drag.erase(a)
	circ["orient_with_rotation"] = false
	mt._pattern_cache["R"] = [circ]
	a.position = Vector3(0, 0, 0)
	var state6 := _start_drag(mt, a, b)
	var live6: Transform3D = mt.constrain_drag(a, Transform3D(Basis.IDENTITY, Vector3(200.0, 0.0, 0.0)))
	print("SMOKE ...with orient_with_rotation false the copy is placed the same but keeps the source's rotation: ", copy1.position.is_equal_approx(Vector3(0, live6.origin.x, 0)) and copy1.basis.is_equal_approx(Basis.IDENTITY))
	mt._drag.erase(a)

	# --- S4: a solve inside a sub-assembly refreshes the copies standing under another root
	# The world root R holds sub-assembly S (occurrence "sub"); S's own part "x" is patterned inside S: the world's glb shows x's copy under R (group_root R,
	# group_parts [S]); an open room of S shows its own (group_root S). Solving S (owner S) moves x: both copies must follow, one request per root.
	var world_copy := _node(holder, "S", "", "sub/x#pattern:Q:1", "R", Vector3(40, 0, 0), ["S"])
	var room_copy := _node(holder, "S", "", "x#pattern:Q:1", "S", Vector3(40, 0, 0), [])
	room_copy.set_meta("room_id", 7)
	var unrelated := _node(holder, "T", "", "y#pattern:Q:1", "R", Vector3(1, 1, 1), ["T"]) # under R too, but a different sub-assembly
	mt.doc_instances = {
		"R": [_instance(["sub", "x#pattern:Q:1"], 90.0, 0.0, 0.0), _instance(["sub", "y#pattern:Q:1"], 500.0, 0.0, 0.0)],
		"S": [_instance(["x#pattern:Q:1"], 70.0, 0.0, 0.0)],
	}
	mt.calls.clear()
	var s4_changes: Array = await mt._copy_pose_changes("S")
	var mesh_roots: Array = mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("assembly-mesh")).map(func(c: Dictionary) -> String: return str(c["path"]).split("?")[0])
	mesh_roots.sort()
	print("SMOKE after a solve of the sub-assembly S the copy under the WORLD root moves (group_parts has S): ", world_copy.position.is_equal_approx(Vector3(90, 0, 0)))
	print("SMOKE ...and so does the open room's own copy (its root IS S): ", room_copy.position.is_equal_approx(Vector3(70, 0, 0)))
	print("SMOKE ...one geometry=false request per distinct root (R and S), a copy of an unrelated sub-assembly is left alone: ", mesh_roots == ["/parts/R/assembly-mesh", "/parts/S/assembly-mesh"] and unrelated.position.is_equal_approx(Vector3(1, 1, 1)) and s4_changes.size() == 2)
	mt.calls.clear()
	var again: Array = await mt._copy_pose_changes("S")
	print("SMOKE ...and nothing changes the second time (already there): ", again.is_empty())
	var only_unrelated: Array = await mt._copy_pose_changes("Z")
	print("SMOKE a Part no copy node's scope contains asks for nothing: ", only_unrelated.is_empty() and mt.calls.filter(func(c: Dictionary) -> bool: return str(c["path"]).contains("assembly-mesh")).size() == 2)
	quit()
