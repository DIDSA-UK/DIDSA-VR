extends SceneTree
## Mates at every level of a multi-level assembly (owner's headset bug report, 17 Oct 2026, Table Assy: a mitred frame side moved with mates
## enforced, then Enforce all said "Couldn't satisfy every mate"). Against an in-memory backend (tests/fake_mates_tool.gd) shaped like that file:
## the root holds a grounded sub-assembly S and a leg L whose mate names a face deep inside S by path (`S/F/A`); S holds the frame F (grounded)
## a top T mated to a face inside F (`F/A`) and an unmated U; F holds the frame sides A (grounded) and B, mated to each other.
## Checks: a path reference marks its TOP-level occurrence mated (never the path itself); every sub-assembly's mates are read, and Enforce all
## solves them deepest first (F's, then S's, then the root's), never a grounded occurrence and never a path; a sub-assembly's failing solve is
## reported with its name; a nested part's node goes back where the stored tree puts it; a mated nested part can't be taken on its own while mates
## are enforced (it can with Relax, and an unmated one always can), through controller.gd's own grip path.
## Run: "$GODOT" --headless --path . --script res://tests/nested_mates.gd

const FakeMates := preload("res://tests/fake_mates_tool.gd")


func _node(holder: Node, owner: String, occ: String, path: Array, parts: Array, root_id: String, label: String) -> Node3D:
	var n := Node3D.new()
	n.name = label
	n.set_meta("owner_part_id", owner)
	n.set_meta("occurrence_id", occ)
	n.set_meta("group_path", path)
	n.set_meta("group_parts", parts)
	n.set_meta("group_root", root_id)
	n.add_to_group("grabbable_parts")
	holder.add_child(n)
	return n


func _initialize() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var mt = FakeMates.new()
	holder.add_child(mt)
	await process_frame
	mt.configure_backend("http://fake", "key")
	mt.doc_names = {"R": "Table Assy", "PS": "Top and frame", "PF": "Frame", "PA": "Frame A", "PB": "Frame B", "PL": "Leg", "PT": "Table Top"}
	mt.doc_occurrences = {
		"R": [FakeMates.row("S", "PS", true), FakeMates.row("L", "PL", false, [30.0, -1030.0, 0.0])],
		"PS": [FakeMates.row("F", "PF", true), FakeMates.row("T", "PT", false, [30.0, 790.0, -1560.0]), FakeMates.row("U", "PU", false, [0.0, 900.0, 0.0])],
		"PF": [FakeMates.row("A", "PA", true), FakeMates.row("B", "PB", false, [0.0, 770.0, 30.0], 90.0)],
		"PA": [], "PB": [], "PL": [], "PT": [], "PU": [],
	}
	mt.doc_mates = {
		"R": [{"id": "m1", "references": [{"occurrence_id": "L"}, {"occurrence_id": "S/F/A"}]}],
		"PS": [{"id": "m2", "references": [{"occurrence_id": "T"}, {"occurrence_id": "F/A"}]}],
		"PF": [{"id": "m3", "references": [{"occurrence_id": "B"}, {"occurrence_id": "A"}]}],
	}
	# B as the file stores it, and a copy of it moved by hand (on screen only)
	var side := _node(holder, "PF", "B", ["S", "F", "B"], ["PS", "PF", "PB"], "R", "FrameB")
	var free_part := _node(holder, "PS", "U", ["S", "U"], ["PS", "PU"], "R", "Lamp")
	var unmated := _node(holder, "PF", "A", ["S", "F", "A"], ["PS", "PF", "PA"], "R", "FrameA")
	await mt.refresh_state("R")

	print("SMOKE a mate reference into a sub-assembly marks its top-level occurrence mated, never the path: ", mt._mated_ids.has("S") and mt._mated_ids.has("L") and not mt._mated_ids.has("S/F/A"))
	print("SMOKE every sub-assembly below the root is read, each after the ones inside it (Frame before Top and frame): ", mt._nested_order.has("PF") and mt._nested_order.has("PS") and mt._nested_order.find("PF") < mt._nested_order.find("PS") and not mt._nested_order.has("R"))
	print("SMOKE ...with its own mates (the frame's two sides are mated in the frame): ", mt._nested_states["PF"]["mated"].has("A") and mt._nested_states["PF"]["mated"].has("B"))

	# --- mid-plane (Width / Symmetric) references, shaped like Table Top with Frame.didsa (the owner's file, 17 Oct): a top centred between two
	# faces of two frame sides, both inside the frame sub-assembly
	var width_mates := [{"id": "w1", "references": [
		{"occurrence_id": "TOP", "subshape_ref": null, "midplane": {"a": {"face_ref": {"index": 2}}, "b": {"face_ref": {"index": 0}}, "b_occurrence_id": null}},
		{"occurrence_id": "FRAME/SIDE1", "subshape_ref": null, "midplane": {"a": {"face_ref": {"index": 0}}, "b": {"face_ref": {"index": 0}}, "b_occurrence_id": "FRAME/SIDE3"}}]}]
	print("SMOKE a mid-plane mate whose two faces are in the same sub-assembly marks the top and that sub-assembly mated: ", FakeMates.mated_tops(width_mates).keys().size() == 2 and FakeMates.mated_tops(width_mates).has("TOP") and FakeMates.mated_tops(width_mates).has("FRAME"))
	width_mates[0]["references"][1]["midplane"]["b_occurrence_id"] = "OTHER/SIDE3"
	print("SMOKE ...and one whose second face is on another top-level occurrence marks that one too (the backend's mate_tops): ", FakeMates.mated_tops(width_mates).has("OTHER") and FakeMates.mated_tops(width_mates).has("FRAME"))

	# --- moving a mated nested part on its own
	print("SMOKE a nested part its sub-assembly's mates move is held while mates are enforced: ", mt.is_nested_locked(side))
	print("SMOKE ...and so is a grounded one they reference; an unmated nested part is not: ", mt.is_nested_locked(unmated) and not mt.is_nested_locked(free_part))
	mt.set_relaxed(true)
	print("SMOKE ...with Relax all mates it is free: ", not mt.is_nested_locked(side))
	mt.set_relaxed(false)
	var controller := XRController3D.new()
	controller.tracker = &"right_hand"
	controller.set_script(load("res://scripts/controller.gd"))
	holder.add_child(controller)
	await process_frame
	controller.mates_tool = mt
	controller._begin_part_hold(side)
	print("SMOKE a grip that would take it on its own is refused (controller.gd) and says why: ", controller.held_node == null and mt.status_text().contains("held by mates inside its sub-assembly"))
	controller._begin_part_hold(free_part)
	print("SMOKE ...an unmated nested part is still taken: ", controller.held_node == free_part)
	controller.held_node = null
	free_part.set_meta("held", false)
	mt.set_relaxed(true)
	controller._begin_part_hold(side)
	print("SMOKE ...and with Relax the mated one is taken too: ", controller.held_node == side)
	controller.held_node = null
	side.set_meta("held", false)
	mt.set_relaxed(false)
	var GroupSet := load("res://scripts/group_set.gd")
	var frame_group = GroupSet.new(side, {"members": [side, unmated], "depth": 2, "prefix": ["S", "F"], "label": "Frame"})
	var top_group = GroupSet.new(side, {"members": [side, unmated, free_part], "depth": 1, "prefix": ["S"], "label": "Top and frame"})
	print("SMOKE a sub-assembly inside another that its parent's mates hold can't be taken as a group either: ", controller._group_refusal(frame_group).contains("held by mates"))
	print("SMOKE ...the top-level one it sits in follows its own rules (grounded here): ", controller._group_refusal(top_group).contains("grounded"))
	mt.set_relaxed(true)
	print("SMOKE ...and with Relax the inner one can go: ", controller._group_refusal(frame_group) == "")
	mt.set_relaxed(false)

	# --- Enforce all
	side.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(400.0, 900.0, -200.0)) # moved by hand: the backend never heard of it
	mt.solve_moves["PF|B"] = {"translation": [0.0, 770.0, 30.0], "rotation_axis": [-1.0, 0.0, 0.0], "rotation_angle_degrees": 90.0}
	mt.calls.clear()
	var outcome: Dictionary = await mt.enforce_all("R")
	var solves: Array = mt.solves()
	print("SMOKE Enforce all satisfies every mate at every level: ", outcome["ok"] and int(outcome["solved"]) == 3)
	print("SMOKE ...solving the frame's mates, then the top's, then the root's, in that order: ", solves == ["/parts/PF/occurrences/B/solve", "/parts/PS/occurrences/T/solve", "/parts/R/occurrences/L/solve"])
	print("SMOKE ...never a path (the old bug: POST .../occurrences/S/F/A/solve) and never a grounded occurrence: ", solves.filter(func(p: String) -> bool: return p.count("/") != 5 or p.contains("/A/") or p.contains("/S/") or p.contains("/F/")).is_empty())
	var stored := FakeMates.json_to_pose(mt.doc_occurrences["R"][0]["transform"]) * FakeMates.json_to_pose(mt.doc_occurrences["PS"][0]["transform"]) * FakeMates.json_to_pose(mt.solve_moves["PF|B"])
	print("SMOKE ...and the frame side moved by hand is back where the stored tree (and its mates) put it: ", side.transform.is_equal_approx(stored))
	print("SMOKE ...the tablet says so: ", mt.status_text().begins_with("Enforced mates on 3 part(s)"))

	# --- a sub-assembly whose mate can't be met
	mt.solve_fails["PF|B"] = {"type": "mate_solve_did_not_converge", "occurrence_id": "B"}
	mt.solve_fails["R|L"] = {"type": "unresolved_mate_occurrence", "occurrence_id": "S/X/A"}
	outcome = await mt.enforce_all("R")
	var problems: Array = outcome["problems"]
	print("SMOKE a failing sub-assembly solve is reported with the sub-assembly's name, and the rest still run: ", not outcome["ok"] and problems.size() == 2 and str(problems[0]).contains("in sub-assembly Frame") and int(outcome["solved"]) == 1)
	print("SMOKE ...a mate naming a part that isn't there says so: ", str(problems[1]).contains("isn't in the assembly") and str(problems[1]).contains("S/X/A"))
	quit()
