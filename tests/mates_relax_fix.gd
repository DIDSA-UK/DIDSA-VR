extends SceneTree
## V-6, "Relax fix" (docs/vr-feedback-2026-11-11-plan.md): only the FIXED flag is relaxed, so a grounded assembly can be carried with every mate kept; temporary.
##   pure: the grounded cluster (every part reachable by mates from a fixed one: couplers and limits place nothing and join nothing)
##   (tests/fake_mates_tool.gd, an in-memory backend, and a real controller): turning it on remembers every part and sends nothing; grabbing a fixed part carries the WHOLE
##   cluster rigidly (relative poses unchanged), a free part and a separate ungrounded pair stay; nothing is PATCHed; a fully-constrained member (the backend's status) carries
##   too while a member with free motion keeps its drag; Return puts every pose back in ONE undo step; a fixed part is no longer refused (V-1) with it on; Relax all while it
##   is on promotes to the full sandbox keeping the homes; it is off by default and not remembered across a reload; a mate made while it is on is solved when parts go home
##   (not atomically).
## NOT covered: how the carry feels in the hand, the real solver's behaviour, the tint / pin marker on fixed parts (not built).
## Run: "$GODOT" --headless --path . --script res://tests/mates_relax_fix.gd  (see tests/README.md)

const FakeMates := preload("res://tests/fake_mates_tool.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")
const CommandStack := preload("res://scripts/command_stack.gd")


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func _mate(id: String, a: String, b: String, type: String = "coincident") -> Dictionary:
	return {"id": id, "type": type, "references": [{"occurrence_id": a}, {"occurrence_id": b}]}


func _part(holder: Node, occ: String, at: Vector3) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = occ
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 0.1, 0.1)
	n.mesh = box
	n.set_meta("owner_part_id", "R")
	n.set_meta("occurrence_id", occ)
	n.set_meta("group_path", [occ])
	n.set_meta("group_parts", ["P" + occ])
	n.set_meta("group_root", "R")
	n.add_to_group("grabbable_parts")
	holder.add_child(n)
	n.position = at
	return n


func _patches(mt) -> int:
	return mt.calls.filter(func(c: Dictionary) -> bool: return c["method"] == HTTPClient.METHOD_PATCH).size()


func _initialize() -> void:
	# --- the pure cluster
	var mates := [_mate("m1", "B", "A"), _mate("m2", "C", "B"), _mate("m3", "F", "E"), _mate("g", "D", "A", "gear")]
	var fixed := {"A": true}
	check("the grounded cluster of the fixed part: A, B (mated to A), C (mated to B)", MatesTool.cluster_of(mates, fixed, "A") == ["A", "B", "C"])
	check("...the same from any member of it", MatesTool.cluster_of(mates, fixed, "C") == ["A", "B", "C"] and MatesTool.cluster_of(mates, fixed, "B") == ["A", "B", "C"])
	check("a part joined only by a gear (a coupler places nothing) is not in it, and an unmated free part has no cluster", MatesTool.cluster_of(mates, fixed, "D").is_empty())
	check("a separate pair with no fixed part has no cluster (an ordinary grab)", MatesTool.cluster_of(mates, fixed, "E").is_empty() and MatesTool.cluster_of(mates, fixed, "F").is_empty())
	check("a fixed part with no mates is a cluster of one", MatesTool.cluster_of([], {"X": true}, "X") == ["X"])
	check("a limit mate joins nothing either", MatesTool.cluster_of([_mate("l", "D", "A", "limit_distance")], fixed, "D").is_empty())

	# --- the tool and the carry
	var holder := Node3D.new()
	root.add_child(holder)
	var mt = FakeMates.new()
	holder.add_child(mt)
	var stack := CommandStack.new()
	mt.setup(stack)
	await process_frame
	mt.configure_backend("http://fake", "key")
	mt.return_glide_s = 0.0
	mt.doc_occurrences = {"R": [FakeMates.row("A", "PA", true), FakeMates.row("B", "PB"), FakeMates.row("C", "PC"), FakeMates.row("D", "PD"), FakeMates.row("E", "PE"), FakeMates.row("F", "PF")]}
	mt.doc_mates = {"R": [_mate("m1", "B", "A"), _mate("m2", "C", "B"), _mate("m3", "F", "E")]}
	var a := _part(holder, "A", Vector3(0, 0, 0))
	var b := _part(holder, "B", Vector3(1, 0, 0))
	var c := _part(holder, "C", Vector3(2, 0, 0))
	var d := _part(holder, "D", Vector3(5, 0, 0))
	var e := _part(holder, "E", Vector3(8, 0, 0))
	var f := _part(holder, "F", Vector3(9, 0, 0))
	await mt.refresh_state("R")
	check("with it off (the default) the fixed, mated part is locked as before and nothing is relaxed", not mt.relaxed_fixed and mt.is_locked(a) and not mt.in_sandbox())
	var controller := XRController3D.new()
	controller.tracker = &"right_hand"
	controller.set_script(load("res://scripts/controller.gd"))
	holder.add_child(controller)
	await process_frame
	controller.mates_tool = mt
	controller.command_stack = stack
	controller.group_deadzone = 0.0
	controller.set_steadiness(0)
	var told: Array[String] = []
	controller.tool_message.connect(func(t: String) -> void: told.append(t))

	mt.calls.clear()
	var home := {}
	for n in [a, b, c, d, e, f]:
		home[n] = n.transform
	mt.set_relaxed_fixed(true)
	await process_frame
	check("Relax fix on: in the sandbox (moves are temporary), mates still enforced, every part remembered, nothing sent to the backend", mt.relaxed_fixed and mt.in_sandbox() and not mt.relaxed and mt.is_sandboxed(a) and mt.is_sandboxed(d) and _patches(mt) == 0)
	check("a fixed part is no longer 'locked' (it is carried instead of refused)", not mt.is_locked(a) and mt.cluster_carry_applies(a))
	check("...a free member with no status known keeps its ordinary drag; an unmated free part and a separate pair have no cluster", not mt.cluster_carry_applies(b) and not mt.cluster_carry_applies(d) and not mt.cluster_carry_applies(e))
	check("the cluster's nodes are A, B and C (not D, E or F)", mt.cluster_nodes(a).size() == 3 and mt.cluster_nodes(a).has(b) and not mt.cluster_nodes(a).has(d))

	# grab A: the whole cluster comes with the hand
	controller.global_position = a.global_position
	controller._try_grab()
	check("grabbing the fixed part carries the whole cluster as one group, with the hand told", controller.held_node == a and controller._held_group != null and controller._held_group.members.size() == 3 and told.size() == 1 and told[0].begins_with("Moving the fixed assembly"))
	var rel_ab: Transform3D = a.global_transform.affine_inverse() * b.global_transform
	var rel_ac: Transform3D = a.global_transform.affine_inverse() * c.global_transform
	controller.global_position += Vector3(0.0, 0.5, 0.2)
	controller.global_transform = Transform3D(Basis(Vector3.UP, 0.6) * controller.global_transform.basis, controller.global_position)
	controller._physics_process(0.016)
	check("moving and turning the hand moves A, B and C rigidly (their relative poses are unchanged)", (a.global_transform.affine_inverse() * b.global_transform).is_equal_approx(rel_ab) and (a.global_transform.affine_inverse() * c.global_transform).is_equal_approx(rel_ac) and a.position.y > 0.4)
	check("...and D, E and F did not move", d.transform.is_equal_approx(home[d]) and e.transform.is_equal_approx(home[e]) and f.transform.is_equal_approx(home[f]))
	controller._try_release()
	await process_frame
	check("letting go sends nothing to the backend (temporary): no PATCH", _patches(mt) == 0)
	check("...and the move is one undo step that does not make the document unsaved", stack.can_undo() and stack._undo_stack.all(func(entry: Dictionary) -> bool: return not bool(entry["persists"])))

	# a member held completely by its mates (the backend's status) is carried too; a part with free motion keeps its drag
	mt._constraint_status = {"B": "fully_constrained", "C": "under_constrained"}
	check("a member the backend says is fully constrained carries the cluster; one with free motion does not", mt.cluster_carry_applies(b) and not mt.cluster_carry_applies(c))
	told.clear()
	controller.global_position = b.global_position
	controller._try_grab()
	check("grabbing the fully-constrained member carries the same cluster, anchored on it", controller.held_node == b and controller._held_group != null and controller._held_group.members.size() == 3)
	controller._try_release()
	await process_frame

	# Return: every pose back, one undo step
	var steps_before: int = stack.history_labels().size()
	await mt.return_parts()
	var back := true
	for n in home:
		if not (n as Node3D).transform.is_equal_approx(home[n]):
			back = false
	check("Return puts every part back exactly where it was", back and not mt.in_sandbox() and not mt.relaxed_fixed)
	check("...as ONE undo step, and undoing it puts the arrangement back and relaxes again", stack.history_labels().size() == steps_before + 1)
	stack.undo()
	await process_frame
	check("undo of Return: the carried arrangement is back and the sandbox is on", mt.in_sandbox() and not a.transform.is_equal_approx(home[a]))
	stack.redo()
	await process_frame
	check("redo returns again", not mt.in_sandbox() and a.transform.is_equal_approx(home[a]))

	# V-1 refusal: a fixed sub-assembly level is not refused while it is on
	mt.set_relaxed_fixed(true)
	await process_frame
	var level := {"depth": 1, "prefix": ["A"], "label": "Frame"}
	check("with Relax fix on a fixed level is not refused (V-1); a mated one still is", controller.refusal_for(level, a).is_empty())
	mt.set_relaxed_fixed(false)
	await process_frame
	check("...with it off the same level is refused as fixed", controller.refusal_for(level, a).get("kind") == "fixed")

	# promotion: Relax all while Relax fix is on keeps the homes
	mt.set_relaxed_fixed(true)
	await process_frame
	a.position += Vector3(0, 1, 0)
	mt.set_relaxed(true)
	await process_frame
	check("Relax all while Relax fix is on promotes to the full sandbox and KEEPS the remembered homes", mt.relaxed and not mt.relaxed_fixed and mt.is_sandboxed(a) and (mt.sandbox_home_of(a) as Transform3D).is_equal_approx(home[a]))
	mt.set_relaxed_fixed(true)
	check("...and Relax fix while all mates are relaxed is a no-op that says so", mt.relaxed and not mt.relaxed_fixed and mt.status_text().contains("already relaxed"))
	await mt.return_parts()
	check("Return from the full sandbox puts everything home", a.transform.is_equal_approx(home[a]) and not mt.in_sandbox())

	# a mate made while it is on is solved at Return, not atomically; it is temporary and not saved across a reload
	mt.set_relaxed_fixed(true)
	await process_frame
	check("a mate made while Relax fix is on is not an atomic create (it is solved when parts go home)", mt.in_sandbox())
	mt.clear_picks()
	var fresh = FakeMates.new()
	holder.add_child(fresh)
	await process_frame
	check("a new tool (a reload) starts with it off: never persisted", not fresh.relaxed_fixed and not fresh.in_sandbox())
	quit(0)
