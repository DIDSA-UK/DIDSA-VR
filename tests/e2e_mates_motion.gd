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


func _grip_drag(part: MeshInstance3D, delta_local_mm: Vector3, frames: int = 40) -> void:
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
	while mt.has_drag(part) and mt._drag[part]["solved"] == null and Time.get_ticks_msec() < deadline:
		await physics_frame
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
	await _grip_drag(B, Vector3(30, 50, 0), 60)
	var drag_requests: int = mt.stat_requests - requests_before
	print("calibration — requests used by the whole drag (incl. release + save): ", drag_requests)
	print("SMOKE the drag used the one-request motion model (the backend has mate-motion): ", mt._motion_supported)
	print("SMOKE ...and a whole 60-frame drag cost only a handful of requests (was 2 per round trip, continuously): ", drag_requests <= 12)
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

	# --- an older backend without mate-motion: falls back to the per-round-trip loop and still constrains
	mt._motion_supported = false
	var fb_start := B.position
	await _grip_drag(B, Vector3(-20, 30, 0), 40)
	var fb_measure := await _measure()
	print("SMOKE fallback (no mate-motion): the part still follows the free directions and stays on the mate plane: ", absf(B.position.x - (fb_start.x - 20.0)) < 1.0 and absf(B.position.y - fb_start.y) < 0.5 and absf(float(fb_measure.get("normal_distance", 99.0))) < 0.01)
	mt._motion_supported = true

	# cleanup
	for m in mt.mates.duplicate():
		await mt.delete_mate(owner_id, str(m.get("id", "")))
	print("SMOKE PASSED: enforced mates against a real backend")
	quit()
