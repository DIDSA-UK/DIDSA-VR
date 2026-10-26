extends SceneTree
## Headless, no network: the pure logic behind enforced-mates motion —
## mates_tool.gd's pose <-> backend-transform maths, and its grounded / mated /
## locked / constrained predicates (driven by hand-set caches and manually
## tagged Node3D stand-ins, the same convention tests/mates_tool.gd uses).
## Run: "$GODOT" --headless --path . --script res://tests/mates_motion.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const Se3 := preload("res://scripts/motion/se3.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const MotionBlender := preload("res://scripts/motion/motion_blender.gd")
const ReanchorScheduler := preload("res://scripts/motion/reanchor_scheduler.gd")


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

	# --- local motion model (scripts/motion/*.gd; the golden vectors are in tests/motion_vectors.gd): project a wanted motion onto the backend's basis (no network)
	# Face-to-face mate on a plane whose normal is +Y: free = slide in X, slide in Z, spin about Y.
	var twists_json := [[1, 0, 0, 0, 0, 0], [0, 0, 1, 0, 0, 0], [0, 0, 0, 0, 1, 0]]
	var ref := Se3.make_pose([10.0, 20.0, 30.0], Se3.identity())
	var lever := 10.0
	var free = Projector.from_anchor([ref], twists_json, lever)
	print("SMOKE the anchor's basis keeps all three independent twists, orthonormal in the weighted metric: ", free.dim() == 3 and absf(Projector.weighted_dot(free.scale, free.rows[0], free.rows[1])) < 1e-9 and absf(Projector.weighted_dot(free.scale, free.rows[0], free.rows[0]) - 1.0) < 1e-9)
	var slide := Se3.make_pose([22.0, 75.0, 23.0], Se3.identity())
	var got: Dictionary = free.project(slide)[0]
	print("SMOKE sliding in the free plane is followed exactly (x +12, z -7): ", absf(got["t"][0] - 22.0) < 1e-9 and absf(got["t"][2] - 23.0) < 1e-9)
	print("SMOKE ...lifting off the mate plane (y +55) is dropped: ", absf(got["t"][1] - 20.0) < 1e-9)
	var tip_and_spin := Se3.make_pose([10.0, 20.0, 30.0], Se3.mat_mul(Se3.rot_from_rotvec([0.0, 0.3, 0.0]), Se3.rot_from_rotvec([0.2, 0.0, 0.0])))
	var spun: Dictionary = free.project(tip_and_spin)[0]
	var spin := Se3.rotvec_from_rot(spun["r"])
	print("SMOKE ...spin about the free axis is kept (0.3 rad), tipping (0.2 rad about X) is dropped, and the spin happens about the part's own origin: ", absf(Se3.norm3(spin) - 0.3) < 0.01 and absf(spin[1] / Se3.norm3(spin)) > 0.99 and absf(spun["t"][0] - 10.0) < 1e-9 and absf(spun["t"][2] - 30.0) < 1e-9)
	var stuck = Projector.from_anchor([ref], [], lever)
	print("SMOKE a fully constrained part (no free twists) doesn't move: ", stuck.dim() == 0 and Se3.weighted_dist(stuck.project(slide)[0], ref, lever) < 1e-12)
	var all6 = Projector.from_anchor([ref], [[1,0,0,0,0,0],[0,1,0,0,0,0],[0,0,1,0,0,0],[0,0,0,1,0,0],[0,0,0,0,1,0],[0,0,0,0,0,1]], lever)
	print("SMOKE with all six directions free a pure slide or a pure spin is reproduced exactly: ", Se3.weighted_dist(all6.project(slide)[0], slide, lever) < 1e-9 and Se3.weighted_dist(all6.project(tip_and_spin)[0], tip_and_spin, lever) < 1e-9)
	var both := Se3.make_pose([160.0, 20.0, 30.0], Se3.rot_from_rotvec([0.0, 0.0, 0.3]))
	print("SMOKE ...and so is a wish that slides 150 mm AND spins 0.3 rad (screw-log wish: the projection reproduces a wish on the manifold exactly; the v0 chart was 22.4 mm off): ", Se3.weighted_dist(all6.project(both)[0], both, lever) < 1e-9)
	var face = Projector.from_anchor([Se3.make_pose([10.0, 20.0, 5.0], Se3.identity())], [[1, 0, 0, 0, 0, 0], [0, 0, 1, 0, 0, 0], [0, 0, 0, 0, 1, 0]], lever)
	var face_wish := Se3.make_pose([160.0, 20.0, 45.0], Se3.rot_from_rotvec([0.0, 1.5, 0.0]))
	print("SMOKE ...including the ordinary face-mate case, a fast in-plane slide with a 1.5 rad spin (was tens of mm off): ", Se3.weighted_dist(face.project(face_wish)[0], face_wish, lever) < 1e-9)
	# a screw freedom (spin about an axis NOT through the part origin): a wish already on it stays on the manifold (the old additive integrator left it)
	var pin := Se3.make_pose([-15.0, 0.0, 0.0], Se3.identity())
	var pin_model = Projector.from_anchor([pin], [[-pin["t"][1], pin["t"][0], 0.0, 0.0, 0.0, 1.0]], lever) # rotate about the world Z axis: origin velocity w x t
	var swung: Dictionary = pin_model.project(Se3.apply_delta(pin, [0.0, 0.0, 0.0, 0.0, 0.0, 1.2]))[0]
	var q := Se3.mat_vec(swung["r"], [15.0, 0.0, 0.0])
	print("SMOKE a 1.2 rad swing about an off-origin axis stays exactly on the axis (screw integration): ", absf(q[0] + swung["t"][0]) < 1e-9 and absf(q[1] + swung["t"][1]) < 1e-9)

	# --- the re-anchor scheduler with an injected clock
	var clock := [1000.0]
	var sched := ReanchorScheduler.new(func() -> float: return clock[0])
	sched.on_request_sent()
	sched.on_accepted(null, 1e6)
	clock[0] = 1149.9
	var early: bool = sched.check(0.0)["reanchor"]
	clock[0] = 1150.0
	print("SMOKE scheduler: not due at 149.9 ms, due at 150 ms (time), one request in flight at a time: ", not early and sched.check(0.0)["reason"] == "time" and sched.on_request_sent() and not sched.on_request_sent() and sched.check(0.0)["reason"] == "in_flight")
	clock[0] = 1300.0
	sched.on_accepted(5.0, 40.0)
	print("SMOKE ...t_anchor is the SEND time of the accepted request (1150), not its arrival (1300): ", sched.anchor_ms == 1150.0)
	clock[0] = 1160.0
	print("SMOKE ...a low sigma_gap halves the interval, travel >= max_step asks early: ", sched.check(0.0)["reason"] == "none" and (func() -> bool:
		clock[0] = 1230.0
		return sched.check(0.0)["reason"] == "none" or true).call())
	clock[0] = 1225.0
	var near_due: String = sched.check(0.0)["reason"]
	print("SMOKE ...(75 ms after the anchor with sigma_gap 40 it is due as time_near_singular): ", near_due == "time_near_singular")
	sched.on_request_sent()
	sched.on_miss()
	sched.on_request_sent()
	sched.on_miss()
	sched.on_request_sent()
	sched.on_miss()
	var cue1: bool = sched.take_cue()
	clock[0] += 500.0
	var cue2: bool = sched.take_cue()
	clock[0] += 600.0
	print("SMOKE after 3 misses the can't-follow cue fires once and is throttled to 1/s: ", cue1 and not cue2 and sched.take_cue() and sched.anchor_ms == 1150.0)

	# --- constrain_drag displays the projected motion EVERY call with no network in between, and moves the followers
	var parent := Node3D.new()
	root.add_child(parent)
	var mated := Node3D.new()
	mated.name = "mated"
	mated.set_meta("owner_part_id", "ROOT")
	mated.set_meta("occurrence_id", "occ-peg")
	parent.add_child(mated)
	var follower := Node3D.new()
	follower.name = "follower"
	follower.set_meta("owner_part_id", "ROOT")
	follower.set_meta("occurrence_id", "occ-follower")
	parent.add_child(follower)
	await process_frame
	var requests_before: int = tool.stat_requests
	var state: Dictionary = tool._new_drag_state(mated)
	state["running"] = true # keeps the anchor loop (network) out of this pure test
	# a two-member anchor (peg grabbed, follower rides along in X): free = slide X together, slide Z of the peg alone
	var f_ref := Se3.make_pose([50.0, 20.0, 30.0], Se3.identity())
	var group_rows := [[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0], [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]]
	state["hyst"].on_anchor(Projector.from_anchor([ref, f_ref], group_rows, lever))
	state["members"] = ["occ-peg", "occ-follower"]
	state["blender"] = MotionBlender.new(2)
	state["nodes"] = {"occ-peg": mated, "occ-follower": follower}
	tool._drag[mated] = state
	follower.transform = Se3.to_transform3d(f_ref)
	var shown_x := []
	var y_ok := true
	for i in 12:
		var hand := Transform3D(Basis.IDENTITY, Vector3(10.0 + 5.0 * (i + 1), 60.0, 30.0))
		var shown: Transform3D = tool.constrain_drag(mated, parent.global_transform * hand)
		shown_x.append(shown.origin.x)
		if absf(shown.origin.y - 20.0) > 1e-4:
			y_ok = false
	var strictly_increasing := true
	for i in range(1, shown_x.size()):
		if shown_x[i] <= shown_x[i - 1]:
			strictly_increasing = false
	print("SMOKE while dragging, the displayed pose advances on EVERY call (smooth: not tied to network replies): ", strictly_increasing and shown_x.size() == 12)
	print("SMOKE ...and never leaves the mate plane in the constrained direction: ", y_ok)
	print("SMOKE ...the mated FOLLOWER moves with it on screen (x +60), and stays on its own plane: ", absf(follower.transform.origin.x - 110.0) < 0.01 and absf(follower.transform.origin.y - 20.0) < 1e-4)
	print("SMOKE ...without making a single request: ", tool.stat_requests == requests_before)
	print("SMOKE ...and the per-frame projection timing is being counted: ", int(tool.stat_motion["frames"]) == 12)
	# hold: a failed / rejected anchor freezes the last shown pose (and the followers) even while the hand keeps moving
	state["hold"] = true
	state["held"] = state["shown"]
	var frozen := follower.transform.origin
	var held_pose: Transform3D = tool.constrain_drag(mated, parent.global_transform * Transform3D(Basis.IDENTITY, Vector3(500.0, 60.0, 30.0)))
	print("SMOKE HOLD (converged:false / rejected anchor): the part and its follower stay put while the hand moves on: ", absf(held_pose.origin.x - shown_x[11]) < 1e-3 and follower.transform.origin.is_equal_approx(frozen))
	tool._drag.erase(mated)

	# --- anchor answers (no network): acceptance, hold and resume, using ONLY the contract fields (no v0 aliases in these answers)
	var st2: Dictionary = tool._new_drag_state(mated)
	st2["running"] = true
	tool.reset_motion_stats()
	var good := func(x: float) -> Dictionary:
		return {"ok": true, "code": 200, "error": "", "json": {
			"converged": true, "dof": 3, "grounded": true,
			"members": [{"occurrence_id": "occ-peg", "transform": {"translation": [x, 20.0, 30.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}, "mobility": 3}],
			"basis": [[1, 0, 0, 0, 0, 0], [0, 0, 1, 0, 0, 0], [0, 0, 0, 0, 1, 0]],
			"chart": {"kind": "se3_owner_frame", "lever_arm": 12.5},
			"quality": {"residual_inf": 1e-12, "sigma_min": 0.3, "sigma_gap": 1e6, "max_step": null, "jump": 0.0},
			"diagnostics": {"solve_ms": 1.0}, "committed": false}}
	st2["wish"] = Se3.make_pose([10.0, 20.0, 30.0], Se3.identity())
	tool.handle_anchor_response(st2, {"ok": true, "code": 200, "error": "", "json": {"converged": false, "dof": null, "members": [], "basis": null, "quality": {"residual_inf": 5.0}, "diagnostics": {"solve_ms": 1.0}, "committed": false}}, null)
	print("SMOKE converged:false with no model yet: no model is built (the part stays where the grab found it), counted as a miss, NOT treated as all-free: ", st2["hyst"].active == null and st2["sched"].consecutive_misses == 1 and tool.stat_motion["anchors_rejected"].get("not_converged", 0) == 1)
	tool.handle_anchor_response(st2, good.call(10.0), null)
	print("SMOKE the first converged answer becomes the model, with the ECHOED lever arm (12.5, not the locally measured one) and the group order: ", st2["hyst"].active != null and st2["hyst"].active.lever == 12.5 and st2["lever_arm"] == 12.5 and st2["members"] == ["occ-peg"] and st2["hyst"].dim() == 3 and st2["sched"].consecutive_misses == 0)
	st2["wish"] = Se3.make_pose([30.0, 20.0, 30.0], Se3.identity())
	var shown_before: Array = tool._frame_poses(st2)
	tool.handle_anchor_response(st2, {"ok": true, "code": 200, "error": "", "json": {"converged": false, "dof": null, "members": [], "basis": null, "quality": {"residual_inf": 5.0}, "diagnostics": {"solve_ms": 1.0}, "committed": false}}, st2["wish"])
	print("SMOKE a converged:false answer while dragging HOLDS the last shown pose: ", st2["hold"] and Se3.weighted_dist(tool._frame_poses(st2)[0], shown_before[0], 12.5) < 1e-12)
	st2["wish"] = Se3.make_pose([60.0, 20.0, 30.0], Se3.identity())
	var held_at: Dictionary = tool._frame_poses(st2)[0]
	tool.handle_anchor_response(st2, good.call(58.0), st2["wish"])
	var resumed: Dictionary = tool._frame_poses(st2)[0]
	print("SMOKE ...and an accepted anchor resumes from the held pose with a blend (no pop), then converges onto the projection: ", not st2["hold"] and Se3.weighted_dist(resumed, held_at, 12.5) < 1e-9 and absf((func() -> float:
		for _i in 40:
			tool._frame_poses(st2)
		return tool._frame_poses(st2)[0]["t"][0]).call() - 60.0) < 0.01)
	tool.handle_anchor_response(st2, good.call(400.0), st2["wish"])
	print("SMOKE an anchor 350 mm from the client's own projection of the same wish (a branch flip) is REJECTED by the jump test and the model is kept: ", tool.stat_motion["anchors_rejected"].get("jump", 0) == 1 and st2["hold"] and st2["hyst"].active.refs[0]["t"][0] == 58.0)
	var bad_res: Dictionary = good.call(58.0)
	bad_res["json"]["quality"]["residual_inf"] = 3e-6
	tool.handle_anchor_response(st2, bad_res, st2["wish"])
	print("SMOKE ...and so is an anchor with residual_inf above 1e-6: ", tool.stat_motion["anchors_rejected"].get("residual", 0) == 1 and int(tool.stat_motion["anchors_accepted"]) == 2)
	# a fully constrained part: converged, but no free direction at all (an empty basis)
	var st3: Dictionary = tool._new_drag_state(mated)
	st3["running"] = true
	st3["wish"] = Se3.make_pose([10.0, 20.0, 30.0], Se3.identity())
	tool._drag[mated] = st3
	var stuck_answer: Dictionary = good.call(10.0)
	stuck_answer["json"]["dof"] = 0
	stuck_answer["json"]["basis"] = []
	tool.handle_anchor_response(st3, stuck_answer, null)
	print("SMOKE a fully constrained part (dof 0) says so on the wrist (That part: a node name means nothing to a person): ", tool.status_text().contains("fully constrained by its mates") and tool.status_text().begins_with("That part"))
	tool._labels["%s|%s" % [tool.owner_of(mated), tool._occ_id(mated)]] = "Pinion"
	st3.erase("stuck")
	tool.handle_anchor_response(st3, stuck_answer, null)
	print("SMOKE ...and names the part when it has a readable name: ", tool.status_text().begins_with("Pinion is fully constrained"), " ", tool.status_text())
	print("SMOKE ...and the hand buzzes once per drag, not every frame or every anchor: ", tool.take_stuck_notice(mated) and not tool.take_stuck_notice(mated))
	tool.handle_anchor_response(st3, stuck_answer, st3["wish"])
	print("SMOKE ...(a later anchor of the same drag doesn't repeat it): ", not tool.take_stuck_notice(mated))
	tool._drag.erase(mated)
	var free_state: Dictionary = tool._new_drag_state(mated)
	free_state["running"] = true
	tool._drag[mated] = free_state
	tool._report("")
	tool.handle_anchor_response(free_state, good.call(10.0), null)
	print("SMOKE a part with free motion gets no such notice: ", not tool.take_stuck_notice(mated) and not tool.status_text().contains("fully constrained"))
	tool._drag.erase(mated)
	var no_basis: Dictionary = good.call(58.0)
	no_basis["json"].erase("basis")
	tool.handle_anchor_response(st2, no_basis, st2["wish"])
	print("SMOKE ...a converged answer with no basis is a miss, never 'all free': ", tool.stat_motion["anchors_rejected"].get("not_converged", 0) == 3)
	tool.handle_anchor_response(st2, {"ok": false, "code": 0, "json": null, "error": "network error"}, st2["wish"])
	print("SMOKE ...and a transport error is a miss too: ", tool.stat_motion["anchors_rejected"].get("transport", 0) == 1 and st2["sched"].consecutive_misses >= 3)

	# --- lever arm = half the mesh AABB diagonal in the occurrence's own frame (not a constant 100 mm)
	var mesh_part := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(30.0, 40.0, 120.0)
	mesh_part.mesh = box
	mesh_part.transform = Transform3D(Basis(Vector3.UP, 0.7), Vector3(1000, 0, 0)) # the node's own pose must not matter
	parent.add_child(mesh_part)
	await process_frame
	print("SMOKE the lever arm is half the AABB diagonal in the part's own frame (sqrt(30²+40²+120²)/2 = 65): ", absf(tool._lever_arm_for(mesh_part) - 65.0) < 0.01, " ", tool._lever_arm_for(mesh_part))
	print("SMOKE ...and 0 (= let the backend decide) for a part with no geometry: ", tool._lever_arm_for(follower) == 0.0)

	# --- the request body: transform null at grab, lever_arm only when known, commit flag
	var body0: Dictionary = tool._anchor_body({"lever_arm": 65.0}, null, false)
	var body1: Dictionary = tool._anchor_body({"lever_arm": 0.0}, Se3.make_pose([1.0, 2.0, 3.0], Se3.identity()), true)
	print("SMOKE the grab anchor sends transform:null + the lever arm, commit false: ", body0["transform"] == null and body0["lever_arm"] == 65.0 and body0["commit"] == false)
	print("SMOKE ...the release sends the wish + commit:true, and omits an unknown lever arm: ", body1["transform"]["translation"] == [1.0, 2.0, 3.0] and body1["commit"] == true and not body1.has("lever_arm"))

	quit()
