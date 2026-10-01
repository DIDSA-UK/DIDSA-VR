extends SceneTree
## Talks to a real backend (LOCAL ONLY, same caveat as e2e_mates.gd — needs
## secrets.cfg pointing at a running backend, never a shared one). The check
## tests/e2e_mates.gd never made: after a mate is created / enforced, is it
## actually SATISFIED — measured by the backend's own POST .../measure (not by
## trusting our own maths) — including when parts were moved in VR first, which
## is exactly what broke in real-headset testing ("enforce moves one part but
## they don't line up"; VR moves were never saved, so the backend solved
## against stale poses).
##
## Covers: moved parts are saved to the backend (incl. a grounded one); a mate
## on moved parts lands satisfied at the parts' CURRENT poses, with the free
## in-plane directions left where they were put (no flying off); a grounded +
## mated part is locked while enforced and unlocks on Relax/Float; a live
## constrained drag keeps the mate satisfied while following the hand in the
## free directions; undo puts the part back AND on the backend; Fix/Float.
## Constrained-drag S5 additions (DIDSA-CAD docs/constrained-drag-implementation-plan.md):
## the drag runs on the group contract (members/basis/chart/quality, no v0
## alias fields, no PATCH+solve fallback); GROUP FOLLOW — float the plate and
## dragging the peg moves the plate on screen, both stored by ONE commit:true
## request and ONE undo entry; a conflicting mate makes the backend answer
## converged:false, which stores nothing (commit atomicity) and makes a real
## grip-drag hold and restore the pre-grab pose; requests per 60-frame drag.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_mates_motion.gd
## Requires secrets.cfg -> a running backend, and assembly.didsa (tracked).

var main
var mt
var A: MeshInstance3D # the grounded plate
var B: MeshInstance3D # the floating peg
var fa := -1
var fb := -1
var owner_id := ""


func _biggest_planar_face(part: MeshInstance3D) -> int:
	var face_ids: Array = part.get_meta("face_ids")
	var arrays := part.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var best := -1
	var best_area := 0.0
	var seen := {}
	for f in face_ids:
		seen[f] = true
	for f in seen:
		var normals := []
		var area := 0.0
		for t in idx.size() / 3:
			if face_ids[t] != f:
				continue
			var a := verts[idx[t * 3]]
			var b := verts[idx[t * 3 + 1]]
			var d := verts[idx[t * 3 + 2]]
			var cr := (b - a).cross(d - a)
			normals.append(cr.normalized())
			area += cr.length() * 0.5
		var planar := true
		for n in normals:
			if n.dot(normals[0]) < 0.999:
				planar = false
		if planar and area > best_area:
			best_area = area
			best = int(f)
	return best


func _tri_of_face(part: MeshInstance3D, face_id: int) -> int:
	return (part.get_meta("face_ids") as Array).find(face_id)


func _measure() -> Dictionary:
	## The backend's own verdict on the two mated faces at ITS stored poses.
	var refs := []
	for pair in [[A, fa], [B, fb]]:
		var ref: Dictionary = mt.MeshIdentity.occurrence_ref_for(pair[0])
		var sub: Dictionary = mt.MeshIdentity.subshape_ref_for_hit(pair[0], _tri_of_face(pair[0], pair[1]))
		refs.append({"occurrence_id": ref["occurrence_id"], "subshape_ref": sub})
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_POST, "/parts/%s/measure" % owner_id, {"refs": refs})
	return result["json"] if result["ok"] else {}


func _backend_translation(part: MeshInstance3D) -> Vector3:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_id, null)
	var occ_id: String = mt.MeshIdentity.occurrence_ref_for(part)["occurrence_id"]
	for occ in result["json"]:
		if occ["id"] == occ_id:
			var t: Array = occ["transform"]["translation"]
			return Vector3(t[0], t[1], t[2])
	return Vector3(INF, INF, INF)


func _grip_drag(part: MeshInstance3D, delta_local_mm: Vector3, frames: int = 40, probe: Callable = Callable(), wait_model: bool = true) -> void:
	## A REAL grip-drag through controller.gd (grab, per-physics-frame follow,
	## release) — not a direct node move — so the wiring under test is the one a
	## hand uses: it must save the pose (unmated), or steer it through the live
	## solver (mated), and record the undo step.
	var hand: XRController3D = main.get_node("XROrigin3D/RightController")
	hand.set_steadiness(0)
	var scale: float = main.assembly_root.global_transform.basis.get_scale().x
	hand.global_position = part.global_transform * part.get_aabb().get_center()
	await physics_frame
	hand._try_grab()
	if hand.held_node != part:
		return # refused (locked) or not reachable: the caller checks
	var step: Vector3 = main.assembly_root.global_transform.basis * (delta_local_mm / float(frames))
	for i in frames:
		hand.global_position += step
		await physics_frame
	# constrained parts need their round trips to answer before release
	var deadline := Time.get_ticks_msec() + 4000
	while wait_model and mt.has_drag(part) and not mt.drag_model_ready(part) and Time.get_ticks_msec() < deadline:
		await physics_frame
	if probe.is_valid():
		probe.call()
	hand._try_release()
	var end := Time.get_ticks_msec() + 6000
	while mt.has_drag(part) and Time.get_ticks_msec() < end:
		await process_frame
	await _settle_writes()


func _settle_writes() -> void:
	# wait for every queued pose write to reach the backend
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		var busy := false
		for occ in mt._persist:
			if mt._persist[occ]["running"] or mt._persist[occ]["pose"] != null:
				busy = true
		if not busy:
			return
		await process_frame


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.use_new_tablet = false # drives the OLD wrist tablet's internals (the new one is the default; see tests/tablet_v2.gd)
	main.secrets_file_path = "res://secrets.cfg"
	root.add_child(main)
	var started := Time.get_ticks_msec()
	while not main.status_text.begins_with("Loaded ") and Time.get_ticks_msec() - started < 60000:
		await process_frame
	if not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: model didn't load — ", main.status_text)
		quit(1)
		return
	mt = main._mates_tool
	owner_id = main.current_root_part_id()
	await mt.refresh_state(owner_id)

	var parts: Array = []
	for n in main.get_tree().get_nodes_in_group("grabbable_parts"):
		if mt.is_managed(n):
			parts.append(n)
	if parts.size() < 2:
		print("SMOKE FAILED: need two placed occurrences")
		quit(1)
		return
	A = parts[0] if mt.is_fixed(parts[0]) else parts[1]
	B = parts[1] if A == parts[0] else parts[0]
	print("SMOKE the first-placed part is grounded and the second floats: ", mt.is_fixed(A) and not mt.is_fixed(B))
	fa = _biggest_planar_face(A)
	fb = _biggest_planar_face(B)

	# --- 1. moves are saved: move BOTH in VR (the grounded one too) before any mate exists
	print("SMOKE an unmated grounded part is free to move (not locked): ", not mt.is_locked(A))
	var a_start := A.position
	await _grip_drag(A, Vector3(30, 25, 0)) # plate: lifted 25 mm along the mate's constrained direction, and slid sideways
	await _grip_drag(B, Vector3(80, 0, 40))
	print("SMOKE a real grip-drag moved the plate (controller path): ", (A.position - (a_start + Vector3(30, 25, 0))).length() < 0.5)
	var a_saved := await _backend_translation(A)
	var b_saved := await _backend_translation(B)
	print("calibration — saved: A ", a_saved, " (VR ", A.position, ")  B ", b_saved, " (VR ", B.position, ")")
	print("SMOKE the grounded part's grip-drag was SAVED to the backend on release: ", a_saved.distance_to(A.position) < 0.01)
	print("SMOKE the floating part's grip-drag was saved to the backend on release: ", b_saved.distance_to(B.position) < 0.01)
	await mt.refresh_state(owner_id)
	print("SMOKE ...and the grounded part is STILL grounded afterwards: ", mt.is_fixed(A))

	# --- 2. a mate on moved parts lands satisfied, in place
	mt.set_active(true)
	mt.try_pick(A, _tri_of_face(A, fa))
	mt.try_pick(B, _tri_of_face(B, fb))
	mt.mate_type = "coincident"
	var b_before := B.position
	var created: Dictionary = await mt.create_mate()
	print("SMOKE create_mate succeeded: ", created["ok"], " ", created["error"])
	await _settle_writes()
	var m1 := await _measure()
	print("calibration — after create: backend measure normal_distance = ", m1.get("normal_distance"), " faces_parallel = ", m1.get("faces_parallel"), "; B was ", b_before, " now ", B.position)
	print("SMOKE the mate is satisfied by the backend's own measure (faces coplanar + parallel): ", absf(float(m1.get("normal_distance", 99.0))) < 0.01 and bool(m1.get("faces_parallel", false)))
	print("SMOKE the free in-plane position stayed where it was put (no flying off): ", absf(B.position.x - b_before.x) < 0.5 and absf(B.position.z - b_before.z) < 0.5)
	print("SMOKE the driven part landed on the plate's CURRENT (lifted) plane, not where the plate used to be: ", absf(B.position.y - (20.0 + 25.0)) < 0.5)
	var b_after_create := await _backend_translation(B)
	print("SMOKE VR and backend agree on the solved pose: ", b_after_create.is_equal_approx(B.position))

	# --- 3. Enforce all with a part moved off in VR again
	B.transform.origin += Vector3(0, 55, 0) # lift it clear of the mate plane
	mt.persist_pose(B)
	await _settle_writes()
	await mt.enforce_all(owner_id)
	await _settle_writes()
	var m2 := await _measure()
	print("SMOKE Enforce all pulls a part that was moved off back onto its mate: ", absf(float(m2.get("normal_distance", 99.0))) < 0.01)
	print("SMOKE ...reporting success on the tablet: ", "Enforced" in mt.status_text())

	# --- 3b. spin about the mate's normal is a FREE direction: it must survive an enforced solve
	# (needs the backend's spin-preserving solver seed — DIDSA-CAD's assembly_solver.py, same session)
	var before_basis := B.transform.basis
	B.transform.basis = Basis(Vector3.UP, deg_to_rad(30.0)) * before_basis # spin 30 degrees about the plane normal (world Y here)
	mt.persist_pose(B)
	await _settle_writes()
	await mt.enforce_all(owner_id)
	await _settle_writes()
	var relative := B.transform.basis * before_basis.inverse()
	var spin_axis_angle := relative.get_rotation_quaternion()
	print("calibration — spin kept after solve: ", snappedf(rad_to_deg(spin_axis_angle.get_angle()), 0.1), " deg about ", spin_axis_angle.get_axis().snapped(Vector3.ONE * 0.01))
	print("SMOKE a part spun about its mate's normal KEEPS the spin through an enforced solve (free direction, not reset): ", absf(rad_to_deg(spin_axis_angle.get_angle()) - 30.0) < 1.0 and absf(spin_axis_angle.get_axis().dot(Vector3.UP)) > 0.99)
	var m2b := await _measure()
	print("SMOKE ...and the mate is still satisfied: ", absf(float(m2b.get("normal_distance", 99.0))) < 0.01)
	B.transform.basis = before_basis
	mt.persist_pose(B)
	await _settle_writes()

	# --- 4. locking
	print("SMOKE the grounded, mated part is locked while mates are enforced: ", mt.is_locked(A))
	print("SMOKE the floating, mated part is constrained: ", mt.is_constrained(B))
	mt.set_relaxed(true)
	print("SMOKE Relax all frees both: ", not mt.is_locked(A) and not mt.is_constrained(B))
	mt.set_relaxed(false)

	# --- 5. a real grip-drag of the constrained part: hand pulls it up 50 and sideways 30
	var start_pos := B.position
	var requests_before: int = mt.stat_requests
	mt.reset_motion_stats()
	var drag_started := Time.get_ticks_msec()
	await _grip_drag(B, Vector3(30, 50, 0), 60)
	var drag_requests: int = mt.stat_requests - requests_before
	print("calibration — requests used by the whole 60-frame drag (grab anchor + re-anchors + 1 commit): ", drag_requests, " in ", Time.get_ticks_msec() - drag_started, " ms; motion stats ", mt.stat_motion)
	print("SMOKE the drag ran on the group contract: one grab anchor, re-anchors on the 150 ms cadence, exactly ONE commit:true request on release: ", int(mt.stat_motion["anchor_requests"]) >= 1 and int(mt.stat_motion["commit_requests"]) == 1 and int(mt.stat_motion["anchors_accepted"]) >= 1)
	print("SMOKE ...and the whole drag cost only a handful of requests (was 2 per round trip, continuously; no separate save): ", drag_requests <= 12, " (", drag_requests, ")")
	print("SMOKE ...per-frame projection is timed and stayed cheap (mean < 2 ms): ", int(mt.stat_motion["frames"]) > 0 and float(mt.stat_motion["projection_us_total"]) / float(mt.stat_motion["frames"]) < 2000.0)
	var mt_src := FileAccess.get_file_as_string("res://scripts/mates_tool.gd")
	print("SMOKE the legacy paths are gone and the v0 alias fields are never read (no free_twists, no top-level transform from mate-motion, no PATCH+solve fallback): ", not (".get(\"free_twists\"" in mt_src) and not ('json.get("transform"' in mt_src) and not ("func _sync_with_solve" in mt_src) and not ("var _motion_supported" in mt_src))
	var ended := B.position
	print("calibration — hand moved it by (30, 50, 0) from ", start_pos, "; it ended at ", ended)
	print("SMOKE while dragging, the part follows the hand in the mate's FREE directions: ", absf(ended.x - (start_pos.x + 30.0)) < 1.0 and absf(ended.z - start_pos.z) < 1.0)
	print("SMOKE ...but is NOT dragged off the mate plane (the constrained direction): ", absf(ended.y - start_pos.y) < 0.5)
	var m3 := await _measure()
	print("SMOKE after release the mate is still satisfied on the backend: ", absf(float(m3.get("normal_distance", 99.0))) < 0.01)
	var b_released := await _backend_translation(B)
	print("SMOKE ...and VR and backend agree where it ended up: ", b_released.is_equal_approx(B.position))

	# the grounded, mated plate refuses a grip
	var hand: XRController3D = main.get_node("XROrigin3D/RightController")
	hand.global_position = A.global_transform * A.get_aabb().get_center()
	await physics_frame
	hand._try_grab()
	print("SMOKE gripping the grounded, mated plate is refused, with a message: ", hand.held_node == null and "grounded" in mt.status_text())
	hand._try_release()

	# --- 6. undo puts it back, in VR and on the backend
	main.command_stack.undo()
	await _settle_writes()
	var b_undone := await _backend_translation(B)
	print("SMOKE undo returns the part to where the drag started: ", B.position.distance_to(start_pos) < 0.01)
	print("SMOKE ...and that's saved to the backend too: ", b_undone.is_equal_approx(B.position))

	# --- 7. Fix / Float
	await mt.toggle_fixed(B)
	print("SMOKE Fix grounds the selected part: ", mt.is_fixed(B))
	await mt.toggle_fixed(B)
	print("SMOKE Float frees it again: ", not mt.is_fixed(B))

	# --- group follow (S5): float the plate; A and B are now one free group. Dragging B moves A ON SCREEN, both stored by ONE commit, ONE undo entry
	await mt.toggle_fixed(A)
	print("SMOKE the plate is floating now (so the pair is an ungrounded group): ", not mt.is_fixed(A) and mt.is_constrained(A) and mt.is_constrained(B))
	var a0 := A.position
	var b0 := B.position
	var commits_before := int(mt.stat_motion["commit_requests"])
	var probe_a := [Vector3(INF, INF, INF)]
	await _grip_drag(B, Vector3(30, 50, 0), 60, func() -> void: probe_a[0] = A.position)
	print("calibration — group drag: A ", a0, " -> (mid-drag ", probe_a[0], ") -> ", A.position, "; B ", b0, " -> ", B.position)
	# The plate follows only as the mate REQUIRES: the hand's +50 off the mate plane (Y) drags it along (B cannot leave the plate's face), the in-plane +30 (X) is a free slide of B over the plate and leaves the plate where it is.
	print("SMOKE while dragging B the FOLLOWER (plate) moved on screen with it (+50 along the mate normal, before release), but not in the free in-plane direction: ", (probe_a[0] - (a0 + Vector3(0, 50, 0))).length() < 3.0)
	print("SMOKE after release B followed the hand (30, 50, 0) and its follower A moved only by what the mate required, (0, 50, 0): ", (B.position - (b0 + Vector3(30, 50, 0))).length() < 1.0 and (A.position - (a0 + Vector3(0, 50, 0))).length() < 1.0)
	print("SMOKE ...stored by exactly ONE commit:true request: ", int(mt.stat_motion["commit_requests"]) - commits_before == 1)
	await _settle_writes()
	var m4 := await _measure()
	print("SMOKE ...the mate is still satisfied on the backend after the group commit: ", absf(float(m4.get("normal_distance", 99.0))) < 0.01 and bool(m4.get("faces_parallel", false)))
	var a_backend := await _backend_translation(A)
	var b_backend := await _backend_translation(B)
	print("SMOKE ...and VR and backend agree on BOTH poses: ", a_backend.is_equal_approx(A.position) and b_backend.is_equal_approx(B.position))
	main.command_stack.undo()
	await _settle_writes()
	print("SMOKE ONE undo puts BOTH members back (VR): ", A.position.distance_to(a0) < 0.01 and B.position.distance_to(b0) < 0.01)
	a_backend = await _backend_translation(A)
	b_backend = await _backend_translation(B)
	print("SMOKE ...and on the backend too: ", a_backend.is_equal_approx(A.position) and b_backend.is_equal_approx(B.position))
	await mt.toggle_fixed(A) # ground the plate again
	print("SMOKE the plate is grounded again: ", mt.is_fixed(A))

	# --- commit atomicity + converged:false hold: a conflicting second mate (distance 25 on the same faces) cannot be satisfied
	mt.set_active(true)
	mt.try_pick(A, _tri_of_face(A, fa))
	mt.try_pick(B, _tri_of_face(B, fb))
	mt.mate_type = "distance"
	mt.mate_value = 25.0
	var conflict: Dictionary = await mt.create_mate()
	print("calibration — conflicting mate created: ", conflict, " / tablet says: ", mt.status_text())
	await _settle_writes()
	var a_before := await _backend_translation(A)
	var b_before2 := await _backend_translation(B)
	var b_occ: String = mt.MeshIdentity.occurrence_ref_for(B)["occurrence_id"]
	var direct: Dictionary = await mt._api_request(HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/mate-motion" % [owner_id, b_occ], {"transform": null, "commit": true})
	var dj = direct["json"]
	print("SMOKE the backend answers converged:false for the unsatisfiable mates, with NO basis, dof or members (clients must hold, not read it as free): ", direct["ok"] and dj is Dictionary and not bool(dj.get("converged", true)) and dj.get("basis") == null and (dj.get("members") as Array).is_empty())
	print("SMOKE ...and a commit:true with converged:false stores NOTHING (atomic, all-or-nothing): ", not bool(dj.get("committed", true)) and (await _backend_translation(A)).is_equal_approx(a_before) and (await _backend_translation(B)).is_equal_approx(b_before2))
	var undo_label_before: String = main.command_stack.undo_label()
	var pre_grab := B.position
	await _grip_drag(B, Vector3(25, 40, 0), 40, Callable(), false)
	await _settle_writes()
	print("SMOKE a real grip-drag under unsatisfiable mates HOLDS at the pre-grab pose (no anchor is ever accepted), and release restores it: ", B.position.distance_to(pre_grab) < 0.01 and A.position.distance_to(a_before) < 0.01)
	print("SMOKE ...nothing was stored on the backend and no undo entry was recorded: ", (await _backend_translation(B)).is_equal_approx(b_before2) and main.command_stack.undo_label() == undo_label_before)
	print("SMOKE ...and the tablet says nothing was changed: ", "nothing was changed" in mt.status_text())
	print("calibration — motion stats after the held drag: ", mt.stat_motion)

	# cleanup
	for m in mt.mates.duplicate():
		await mt.delete_mate(owner_id, str(m.get("id", "")))
	print("SMOKE PASSED: enforced mates against a real backend")
	quit()
