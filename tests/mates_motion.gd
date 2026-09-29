extends SceneTree
## Headless, no network: the pure logic behind enforced-mates motion —
## mates_tool.gd's pose <-> backend-transform maths, and its grounded / mated /
## locked / constrained predicates (driven by hand-set caches and manually
## tagged Node3D stand-ins, the same convention tests/mates_tool.gd uses).
## Run: "$GODOT" --headless --path . --script res://tests/mates_motion.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")


func _part(name: String, owner_id: String, occ: String) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.set_meta("owner_part_id", owner_id)
	n.set_meta("occurrence_id", occ)
	root.add_child(n)
	return n


func _initialize() -> void:
	var tool := MatesTool.new()
	root.add_child(tool)
	await process_frame

	# --- pose <-> backend transform round trips
	var poses: Array[Transform3D] = [
		Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(180.0)), Vector3(0, 20, 0)),
		Transform3D(Basis(Vector3(1, 2, 3).normalized(), deg_to_rad(37.0)), Vector3(12.5, -3.0, 44.0)),
		Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)),
		Transform3D(Basis(Vector3(0, 1, 0), deg_to_rad(270.0)), Vector3.ZERO),
	]
	var round_trip_ok := true
	for p in poses:
		var back := MatesTool.json_to_pose(MatesTool.pose_to_json(p))
		if not (back.origin.is_equal_approx(p.origin) and back.basis.is_equal_approx(p.basis)):
			round_trip_ok = false
	print("SMOKE pose -> backend JSON -> pose round-trips for 0, 37, 180 and 270 degree rotations: ", round_trip_ok)
	var ident := MatesTool.pose_to_json(Transform3D.IDENTITY)
	print("SMOKE an identity pose serialises with a usable non-zero axis (the backend validates it): ", Vector3(ident["rotation_axis"][0], ident["rotation_axis"][1], ident["rotation_axis"][2]).length() > 0.5 and ident["rotation_angle_degrees"] == 0.0)

	# --- predicates
	var plate := _part("plate", "ROOT", "occ-plate") # grounded
	var peg := _part("peg", "ROOT", "occ-peg") # floating
	var loose := _part("loose", "ROOT", "occ-loose") # floating, unmated
	var rootc := _part("rootc", "ROOT", "") # the assembly's own content
	var other := _part("other", "SOMEONE-ELSE", "occ-x") # nested/other owner
	tool.backend_url = "http://unused"
	tool.api_key = "unused"
	tool._current_owner_part_id = "ROOT"
	tool.occurrences = {"occ-plate": {"fixed": true}, "occ-peg": {"fixed": false}, "occ-loose": {"fixed": false}}
	tool.mates = [{"references": [{"occurrence_id": "occ-plate"}, {"occurrence_id": "occ-peg"}]}]
	tool._rebuild_mated_ids()

	print("SMOKE top-level occurrences of the loaded root are managed; root content and other owners aren't: ", tool.is_managed(plate) and not tool.is_managed(rootc) and not tool.is_managed(other))
	print("SMOKE grounded + mated + enforced = locked: ", tool.is_locked(plate))
	print("SMOKE ...and a grounded part is never 'constrained' (it doesn't move): ", not tool.is_constrained(plate))
	print("SMOKE floating + mated + enforced = constrained (live-solved), not locked: ", tool.is_constrained(peg) and not tool.is_locked(peg))
	print("SMOKE an unmated part is neither locked nor constrained (free to move; its pose is just saved): ", not tool.is_locked(loose) and not tool.is_constrained(loose))
	tool.relaxed = true
	print("SMOKE Relax all mates: nothing is locked or constrained: ", not tool.is_locked(plate) and not tool.is_constrained(peg))
	tool.relaxed = false
	tool.occurrences["occ-plate"]["fixed"] = false
	print("SMOKE Floating the grounded part unlocks it: ", not tool.is_locked(plate) and tool.is_constrained(plate))
	tool.occurrences["occ-plate"]["fixed"] = true
	tool.backend_url = ""
	print("SMOKE with no backend configured nothing is managed at all (local .glb behaviour unchanged): ", not tool.is_managed(plate) and not tool.is_locked(plate))
	tool.backend_url = "http://unused"

	# --- which side is driven: the second pick, unless it's grounded and the first isn't
	print("SMOKE driven side defaults to the second pick: ", tool._choose_driven("occ-peg", "occ-loose") == "occ-loose")
	print("SMOKE ...but a grounded second pick is never driven (the backend 422s it): ", tool._choose_driven("occ-peg", "occ-plate") == "occ-peg")
	print("SMOKE ...and if both are grounded the second stays (solve reports it): ", tool._choose_driven("occ-plate", "occ-plate") == "occ-plate")

	# --- error text
	print("SMOKE a fixed-occurrence 422 reads as a plain sentence: ", "grounded" in tool._friendly_error({"json": {"detail": {"type": "occurrence_is_fixed"}}, "error": ""}))
	print("SMOKE a non-convergence 422 says the mates conflict: ", "can't all be satisfied" in tool._friendly_error({"json": {"detail": {"type": "mate_solve_did_not_converge"}}, "error": ""}))

	# --- the grounded-part refusal message is throttled
	var notices := [0]
	tool.picks_changed.connect(func() -> void: notices[0] += 1)
	tool.notify_locked(plate)
	tool.notify_locked(plate)
	tool.notify_locked(plate)
	print("SMOKE the locked message shows once (not every physics frame): ", notices[0] == 1 and "grounded" in tool.status_text())

	quit()
