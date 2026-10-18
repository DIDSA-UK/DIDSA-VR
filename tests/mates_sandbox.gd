extends SceneTree
## Relax all mates as a SANDBOX (owner's design, 18 Oct 2026; mates_tool.gd set_relaxed), against an in-memory backend
## (tests/fake_mates_tool.gd): turning Relax on remembers every part's pose; while relaxed anything moves (a grounded part too, a mated
## sub-assembly as a group) and nothing is saved (no PATCH, and no "unsaved changes"); turning it off glides every remembered part back to
## exactly where it was (no solve from the scattered layout) as one undo step (undo puts the arrangement back and relaxes again; redo returns
## again), then solves what the mates made or edited meanwhile drive, from the home poses; a part that appeared meanwhile keeps its place
## and its moves save; a deleted one is just gone; Enforce all while relaxed returns first; a reload while relaxed adopts the new parts'
## stored poses as their homes; the optional ghosts and lines show only for parts away from home; the snapshot is keyed by occurrence path.
## Run: "$GODOT" --headless --path . --script res://tests/mates_sandbox.gd

const FakeMates := preload("res://tests/fake_mates_tool.gd")
const CommandStack := preload("res://scripts/command_stack.gd")


func _part(holder: Node, owner: String, occ: String, path: Array, at: Vector3, label: String) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = label
	n.mesh = BoxMesh.new()
	n.set_meta("owner_part_id", owner)
	n.set_meta("occurrence_id", occ)
	if not path.is_empty():
		n.set_meta("group_path", path)
		n.set_meta("group_parts", path.map(func(p) -> String: return "P" + str(p)))
		n.set_meta("group_root", "R")
	n.add_to_group("grabbable_parts")
	holder.add_child(n)
	n.position = at
	return n


func _patches(mt) -> int:
	return mt.calls.filter(func(c: Dictionary) -> bool: return c["method"] == HTTPClient.METHOD_PATCH).size()


func _initialize() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var mt = FakeMates.new()
	holder.add_child(mt)
	var stack := CommandStack.new()
	mt.setup(stack)
	await process_frame
	mt.configure_backend("http://fake", "key")
	mt.return_glide_s = 0.0
	mt.doc_occurrences = {"R": [FakeMates.row("BASE", "PB", true), FakeMates.row("ARM", "PA", false, [100.0, 0.0, 0.0]), FakeMates.row("LID", "PL", false, [0.0, 200.0, 0.0])], "PB": [], "PA": [], "PL": []}
	mt.doc_mates = {"R": [{"id": "m1", "references": [{"occurrence_id": "ARM"}, {"occurrence_id": "BASE"}]}]}
	var base := _part(holder, "R", "BASE", ["BASE"], Vector3(0, 0, 0), "Base")
	var arm := _part(holder, "R", "ARM", ["ARM"], Vector3(100, 0, 0), "Arm")
	var lid := _part(holder, "R", "LID", ["LID"], Vector3(0, 200, 0), "Lid")
	await mt.refresh_state("R")
	var controller := XRController3D.new()
	controller.tracker = &"right_hand"
	controller.set_script(load("res://scripts/controller.gd"))
	holder.add_child(controller)
	await process_frame
	controller.mates_tool = mt
	controller.command_stack = stack
	var sandbox_events: Array = []
	mt.sandbox_changed.connect(func(on: bool) -> void: sandbox_events.append(on))

	print("SMOKE before: the grounded, mated base is locked and the arm is steered by its mate: ", mt.is_locked(base) and mt.is_constrained(arm))
	mt.set_relaxed(true)
	print("SMOKE Relax on: every part is remembered, mates stop steering, the grounded base moves too, and the wrist says moves are temporary: ", mt.is_sandboxed(base) and mt.is_sandboxed(arm) and mt.is_sandboxed(lid) and not mt.is_locked(base) and not mt.is_constrained(arm) and mt.status_text().contains("nothing is saved") and sandbox_events == [true])

	# --- moves while relaxed: on screen only
	mt.calls.clear()
	var arm_home := arm.transform
	var base_home := base.transform
	var before := arm.global_transform
	arm.position = Vector3(400, 50, -20)
	arm.rotate_y(0.7)
	controller._push_move_command(arm, before)
	before = base.global_transform
	base.position = Vector3(-300, 0, 0)
	controller._push_move_command(base, before)
	print("SMOKE moving parts while relaxed sends nothing to the backend: ", _patches(mt) == 0)
	print("SMOKE ...each move is still an undo step, but none makes the document 'unsaved': ", stack.can_undo() and stack._undo_stack.all(func(e: Dictionary) -> bool: return not bool(e["persists"])))
	var GroupSet := load("res://scripts/group_set.gd")
	var grp = GroupSet.new(arm, {"members": [arm], "depth": 1, "prefix": ["ARM"], "label": "Arm"})
	print("SMOKE ...a mated sub-assembly can be taken as a group too: ", controller._group_refusal(grp) == "")

	# --- the optional cues
	mt.sandbox_ghosts = true
	mt.update_cues()
	print("SMOKE with ghosts on, a ghost stands at home for each part away from it (not for the lid, which hasn't moved): ", mt.cue_count() == {"ghosts": 2, "lines": 0})
	var ghost: Node3D = mt._cues[arm]["ghost"]
	print("SMOKE ...exactly where the arm goes back to: ", ghost.global_transform.is_equal_approx(holder.global_transform * arm_home))
	mt.sandbox_lines = true
	mt.update_cues()
	print("SMOKE with lines on too, each gets a line home: ", mt.cue_count() == {"ghosts": 2, "lines": 2})
	mt.sandbox_ghosts = false
	mt.update_cues()
	print("SMOKE either can be off on its own (lines only): ", mt.cue_count() == {"ghosts": 0, "lines": 2})
	mt.sandbox_lines = false
	mt._process(0.2)
	print("SMOKE both off: none (both are off by default): ", mt.cue_count() == {"ghosts": 0, "lines": 0})

	# --- the snapshot, keyed for a scene
	var snap: Dictionary = mt.sandbox_snapshot()
	print("SMOKE the snapshot is keyed by occurrence path (the shape a saved scene would use): ", snap.has("R|ARM") and snap.has("R|BASE") and snap.has("R|LID") and FakeMates.json_to_pose(snap["R|ARM"]).is_equal_approx(arm_home))

	# --- a part that appears meanwhile, one that goes, a mate made meanwhile
	var added := _part(holder, "R", "NEW", ["NEW"], Vector3(0, 0, 500), "Added")
	mt.doc_occurrences["R"].append(FakeMates.row("NEW", "PN", false, [0.0, 0.0, 500.0]))
	mt._current_owner_part_id = "R"
	mt.occurrences["NEW"] = {"fixed": false}
	added.position = Vector3(10, 0, 600)
	mt.calls.clear()
	mt.persist_pose(added)
	await process_frame
	print("SMOKE a part that appeared while relaxed is not in the sandbox: its moves save: ", not mt.is_sandboxed(added) and _patches(mt) == 1)
	lid.free()
	mt.note_sandbox_mate("R", "ARM")
	mt.note_sandbox_mate("R", "ARM")
	print("SMOKE a mate made or edited while relaxed queues its driven part once, to solve after the return: ", mt._sandbox_solve.size() == 1)

	# --- Return parts
	mt.calls.clear()
	var undo_depth: int = stack._undo_stack.size()
	var outcome: Dictionary = await mt.return_parts()
	print("SMOKE Return parts puts every remembered part back exactly (rotation too): ", arm.transform.is_equal_approx(arm_home) and base.transform.is_equal_approx(base_home) and outcome["moved"] == 2)
	print("SMOKE ...relaxes no more, and says so: ", not mt.relaxed and mt.is_locked(base) and mt.is_constrained(arm) and sandbox_events == [true, false])
	print("SMOKE ...the added part stays where it was put, and the deleted one is just gone: ", added.position.is_equal_approx(Vector3(10, 0, 600)))
	var solves: Array = mt.solves()
	var first_patch := -1
	for i in mt.calls.size():
		if mt.calls[i]["method"] == HTTPClient.METHOD_PATCH:
			first_patch = i
			break
	print("SMOKE ...then the mate made meanwhile is solved, from the home pose (PATCHed first), and nothing else is: ", solves == ["/parts/R/occurrences/ARM/solve"] and first_patch >= 0 and str(mt.calls[first_patch]["path"]) == "/parts/R/occurrences/ARM" and mt._sandbox_solve.is_empty())
	print("SMOKE ...with no solve of anything else (the scattered layout is never solved from): ", solves.size() == 1)
	print("SMOKE ...and it is ONE undo step: ", stack._undo_stack.size() == undo_depth + 1 and stack.undo_label() == "return parts")

	# --- undo / redo of the return
	stack.undo()
	print("SMOKE undo puts the arrangement back and relaxes again: ", mt.relaxed and arm.position.is_equal_approx(Vector3(400, 50, -20)) and base.position.is_equal_approx(Vector3(-300, 0, 0)) and mt.is_sandboxed(arm))
	stack.redo()
	await process_frame
	print("SMOKE redo returns them again: ", not mt.relaxed and arm.transform.is_equal_approx(arm_home) and base.transform.is_equal_approx(base_home))

	# --- Enforce all while relaxed returns first
	mt.set_relaxed(true)
	arm.position = Vector3(900, 0, 0)
	var enforce: Dictionary = await mt.enforce_all("R")
	print("SMOKE Enforce all while relaxed returns the parts first, then solves from home: ", not mt.relaxed and arm.transform.is_equal_approx(arm_home) and enforce["ok"])

	# --- a reload while relaxed
	mt.set_relaxed(true)
	var reloaded := _part(holder, "R", "LID", ["LID"], Vector3(0, 200, 0), "LidReloaded")
	await mt.refresh_state("R")
	print("SMOKE parts that (re)load while relaxed take their stored poses as home: ", mt.is_sandboxed(reloaded) and mt._home[reloaded].is_equal_approx(reloaded.transform))
	reloaded.position = Vector3(5, 5, 5)
	await mt.set_relaxed(false)
	print("SMOKE ...and go back there: ", reloaded.position.is_equal_approx(Vector3(0, 200, 0)))

	# --- the glide
	mt.return_glide_s = 0.2
	mt.set_relaxed(true)
	arm.position = Vector3(700, 0, 0)
	var started := Time.get_ticks_msec()
	await mt.set_relaxed(false)
	print("SMOKE with a glide, the parts move home over its time and end exactly there: ", Time.get_ticks_msec() - started >= 150 and arm.transform.is_equal_approx(arm_home))
	quit()
