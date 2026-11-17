extends SceneTree
## N1c: mate_health.gd defers to the backend (DIDSA-CAD N1b) for the references it reports, and keeps its own drift check for an older backend.
## Synthetic parts as in tests/mate_health.gd, and mate dictionaries as the backend now sends them: lost_references, moved_references,
## followed_references (paths such as references[0].subshape_ref), reference_reasons and held. Covers: a mate whose index the server changed
## (followed: no drift, Enforce has nothing to suppress), a held mate, a lost mate, a Width (midplane) path, an older backend with none of the
## fields (the local check unchanged), the baseline pruning, the sticky "followed" note, and the pure texts and helpers of mate_reference_state.gd.
## Run: "$GODOT" --headless --path . --script res://tests/mate_health_server.gd  (see tests/README.md)

const Health := preload("res://scripts/design_table/mate_health.gd")
const RefState := preload("res://scripts/mate_reference_state.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")


func part(faces: Array, kinds: Array, occurrence := "occ1") -> MeshInstance3D:
	var verts := PackedVector3Array()
	var face_ids: Array = []
	var body_ids: Array = []
	for fid in faces.size():
		for tri in faces[fid]:
			verts.append_array([tri[0], tri[1], tri[2]])
			face_ids.append(fid)
			body_ids.append("B")
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.set_meta("face_ids", face_ids)
	node.set_meta("body_ids", body_ids)
	node.set_meta("topology", {"B": {"face_kinds": kinds, "edges": {}, "vertices": {}, "vertex_at": {}, "face_edges": [], "edge_kinds": {}}})
	node.set_meta("occurrence_id", occurrence)
	return node


func square(z: float, facing_up: bool, x0 := 0.0, size := 10.0) -> Array:
	var a := Vector3(x0, 0, z)
	var b := Vector3(x0, size, z)
	var c := Vector3(x0 + size, size, z)
	var d := Vector3(x0 + size, 0, z)
	return [[a, b, d], [b, c, d]] if facing_up else [[a, d, b], [d, c, b]]


func wall(x: float, facing_plus_x: bool) -> Array:
	var a := Vector3(x, 0, 0)
	var b := Vector3(x, 10, 0)
	var c := Vector3(x, 10, 10)
	var d := Vector3(x, 0, 10)
	return [[a, b, d], [b, c, d]] if facing_plus_x else [[a, d, b], [d, c, b]]


func sub(index: int) -> Dictionary:
	return {"body_id": "B", "shape_type": "face", "index": index}


func coincident(id: String, top_index: int, bottom_index: int, extra := {}) -> Dictionary:
	## The box's top (occ1) mated to the plate's bottom-facing face (occ2), as MateResponse: the server's fields in `extra`.
	var mate := {"id": id, "type": "coincident", "suppressed": false, "status": "ok", "references": [
		{"occurrence_id": "occ1", "subshape_ref": sub(top_index)},
		{"occurrence_id": "occ2", "subshape_ref": sub(bottom_index)}]}
	mate.merge(extra, true)
	return mate


func _initialize() -> void:
	var kinds2 := ["plane", "plane"]
	var kinds5 := ["plane", "plane", "plane", "plane", "plane"]
	# Before the edit: face 1 is the top, face 0 the bottom. After it (a boss on the top) the top is face 2, the bottom face 4, and 1 / 0 are walls.
	var before_one := part([square(0, false), square(10, true)], kinds2, "occ1")
	var before_two := part([square(0, false), square(10, true)], kinds2, "occ2")
	var after_one := part([wall(0, false), wall(10, true), square(10, true, 0.0, 10.0), square(22, true, 2.0, 6.0), square(0, false)], kinds5, "occ1")
	var after_two := part([wall(0, false), wall(10, true), square(10, true, 0.0, 10.0), square(22, true, 2.0, 6.0), square(0, false)], kinds5, "occ2")
	var old_listing := [coincident("m1", 1, 0)] # an older backend, or the listing before the edit: no server fields at all

	# --- an older backend (no fields): the local drift check is exactly what it was
	var captured_old := Health.capture([before_one, before_two], old_listing)
	print("SMOKE an older backend (no fields): capture records both references, as before N1c: ", captured_old.size() == 2 and captured_old[0]["index"] == 1 and captured_old[1]["index"] == 0)
	print("SMOKE ...and the renumbering is still reported as drift on both: ", Health.drifted(captured_old, [after_one, after_two]).size() == 2)
	print("SMOKE ...pruning a baseline against a listing with no fields keeps every entry: ", Health.prune_baseline(captured_old, old_listing).size() == 2)
	print("SMOKE an older backend flags nothing: no server state, no flagged mates, no summary line: ", not RefState.has_server_state(old_listing[0]) and Health.server_flagged(old_listing).is_empty() and RefState.summary_text(old_listing) == "")
	print("SMOKE ...and its mates get no note on the tablet: ", RefState.note_for(old_listing[0])["kind"] == "")

	# --- a mate whose index the server changed (followed): no drift warning, nothing for Enforce to suppress
	var followed := ["references[0].subshape_ref", "references[1].subshape_ref"]
	var listing_followed := [coincident("m1", 2, 4, {"followed_references": followed, "lost_references": [], "moved_references": [], "held": false,
		"reference_reasons": {"references[0].subshape_ref": "nearest_of_identical_faces"}})]
	print("SMOKE a followed mate carries server state and is flagged: ", RefState.has_server_state(listing_followed[0]) and RefState.is_followed(listing_followed[0]) and Health.server_flagged(listing_followed) == ["m1"])
	var baseline_before_edit := Health.capture([before_one, before_two], old_listing) # recorded at an earlier edit, at the old indices
	print("SMOKE without N1c the old baseline would flag the followed mate (index 1 is a wall now): ", Health.drifted(baseline_before_edit, [after_one, after_two]).size() == 2)
	var pruned := Health.prune_baseline(baseline_before_edit, listing_followed)
	print("SMOKE prune_baseline drops the entries of references the server followed: ", pruned.is_empty())
	print("SMOKE ...so after the edit the mate has not drifted and Enforce has nothing to suppress: ", Health.drifted(pruned, [after_one, after_two]).is_empty() and Health.mate_ids(Health.drifted(pruned, [after_one, after_two])).is_empty())
	var capture_followed := Health.capture([before_one, before_two], listing_followed) # the listing after the edit, the OLD mesh still on screen
	print("SMOKE capture records nothing for a followed reference (its new index names another face on the old mesh): ", capture_followed.is_empty())
	print("SMOKE ...so the new index is never compared with a baseline taken from the wrong face: ", Health.drifted(capture_followed, [after_one, after_two]).is_empty())
	print("SMOKE the followed mate has no remake offer: ", Health.remake_plan(listing_followed, Health.drifted(pruned, [after_one, after_two]), pruned, [after_one, after_two]).is_empty())
	print("SMOKE the design table's line says a mate followed the edit: ", RefState.summary_text(listing_followed) == "1 mate followed the edit onto the renumbered face.")
	print("SMOKE the tablet note is an info line, kind followed: ", RefState.note_for(listing_followed[0])["kind"] == "followed")

	# --- only the reported reference is skipped; the other one keeps the local check
	var one_followed := [coincident("m1", 2, 0, {"followed_references": ["references[0].subshape_ref"], "lost_references": [], "moved_references": [], "held": false, "reference_reasons": {}})]
	var capture_one := Health.capture([before_one, before_two], one_followed)
	print("SMOKE a mate with one followed reference: the other is still captured: ", capture_one.size() == 1 and capture_one[0]["occurrence_id"] == "occ2" and capture_one[0]["path"] == "references[1].subshape_ref")

	# --- a held mate
	var listing_held := [coincident("m2", 2, 0, {"held": true, "moved_references": ["references[0].subshape_ref"], "lost_references": [], "followed_references": [],
		"reference_reasons": {"references[0].subshape_ref": "unique_fingerprint_far"}, "status": "broken"})]
	var held_note := RefState.note_for(listing_held[0])
	print("SMOKE a held mate: held, not lost, and its note says check this mate with the reason: ", RefState.is_held(listing_held[0]) and not RefState.is_lost(listing_held[0]) and held_note["kind"] == "held" and str(held_note["text"]).begins_with("Check this mate") and str(held_note["text"]).contains("the face moved a long way"))
	print("SMOKE capture leaves the held reference to the server, keeps the other: ", Health.capture([before_one, before_two], listing_held).size() == 1)
	var baseline_held := Health.capture([before_one, before_two], [coincident("m2", 1, 0)])
	print("SMOKE prune_baseline drops the held reference's old entry and keeps the other's: ", Health.prune_baseline(baseline_held, listing_held).size() == 1)
	print("SMOKE a held mate is flagged, and the summary says it needs checking: ", Health.server_flagged(listing_held) == ["m2"] and RefState.summary_text(listing_held) == "1 needs checking (Confirm on the Mates page).")
	var listing_held_width := [{"id": "w", "type": "coincident", "suppressed": false, "held": true, "moved_references": ["references[0].midplane.b.face_ref"], "references": [
		{"occurrence_id": "occ1", "midplane": {"a": {"face_ref": sub(0)}, "b": {"face_ref": sub(1)}, "b_occurrence_id": "occ2"}, "subshape_ref": null},
		{"occurrence_id": "occ2", "subshape_ref": sub(1)}]}]
	var capture_width := Health.capture([before_one, before_two], listing_held_width)
	var width_paths: Array = []
	for entry in capture_width:
		width_paths.append(entry["path"])
	print("SMOKE a Width mate: the held midplane.b face is skipped by its backend path, midplane.a and the other reference are kept: ", width_paths == ["references[0].midplane.a.face_ref", "references[1].subshape_ref"])
	print("SMOKE a held mate is not judged for parallel faces (its listed faces are not the ones it sits on): ", Health.unparallel_pairs(listing_held_width, [before_one, before_two]).is_empty())

	# --- a lost mate
	var listing_lost := [coincident("m3", 1, 0, {"held": false, "lost_references": ["references[1].subshape_ref"], "moved_references": [], "followed_references": [],
		"reference_reasons": {"references[1].subshape_ref": "no_match"}, "status": "broken"})]
	var lost_note := RefState.note_for(listing_lost[0])
	print("SMOKE a lost mate: lost, never held, and its note gives the reason: ", RefState.is_lost(listing_lost[0]) and not RefState.is_held(listing_lost[0]) and lost_note["kind"] == "lost" and str(lost_note["text"]).contains("its face is gone"))
	print("SMOKE ...even if a reply said held: true beside a lost reference, lost wins (there is nothing to confirm): ", not RefState.is_held({"held": true, "lost_references": ["references[0].subshape_ref"]}))
	print("SMOKE capture skips the lost reference, keeps the other: ", Health.capture([before_one, before_two], listing_lost).size() == 1 and Health.capture([before_one, before_two], listing_lost)[0]["occurrence_id"] == "occ1")
	print("SMOKE the summary counts it as lost: ", RefState.summary_text(listing_lost) == "1 lost a face.")

	# --- a server that says everything is fine: the local check is still there
	var listing_ok := [coincident("m4", 1, 0, {"held": false, "lost_references": [], "moved_references": [], "followed_references": [], "reference_reasons": {}})]
	print("SMOKE a new backend with nothing to report: server state present, no note, the local check captures both references: ", RefState.has_server_state(listing_ok[0]) and RefState.note_for(listing_ok[0])["kind"] == "" and Health.capture([before_one, before_two], listing_ok).size() == 2 and Health.server_flagged(listing_ok).is_empty())

	# --- the mates a solve left out (N-6)
	print("SMOKE held_mate_ids is read from the JSON of an answer (absent: none): ", RefState.held_mate_ids({"json": {"held_mate_ids": ["m2", "m3"]}}) == ["m2", "m3"] and RefState.held_mate_ids({"json": {"converged": true}}).is_empty() and RefState.held_mate_ids({"json": null}).is_empty())
	print("SMOKE ...and from the X-Held-Mates header, the two merged without repeats: ", RefState.held_mate_ids({"json": {"held_mate_ids": ["m2"]}, "held_mates": ["m2", "m3"]}) == ["m2", "m3"])
	print("SMOKE the header parses `id, id` and ignores blanks: ", RefState.parse_held_header(" a ,b,,a") == ["a", "b"] and RefState.parse_held_header("").is_empty())
	print("SMOKE MatesTool reads the header out of a response's header lines, any case, and none: ", MatesTool.held_header(PackedStringArray(["Content-Type: application/json", "x-held-mates: m2,m3"])) == ["m2", "m3"] and MatesTool.held_header(PackedStringArray(["Content-Type: application/json"])).is_empty() and MatesTool.held_header(PackedStringArray()).is_empty())
	var both := listing_held + listing_lost
	var left := RefState.left_out_text(["m2", "m3"], both)
	print("SMOKE the left-out line names how many and why: ", left == "2 mates left out of the solve: Coincident (check it), Coincident (lost a face)." and RefState.left_out_text([], both) == "")
	print("SMOKE an unknown id still gets a line: ", RefState.left_out_text(["zzz"], []) == "1 mate left out of the solve: a mate (needs checking).")

	# --- a followed reference is reported once: the note is kept until it is shown
	var notes := {}
	var first_listing := [coincident("m1", 2, 4, {"followed_references": ["references[0].subshape_ref"], "reference_reasons": {"references[0].subshape_ref": "nearest_of_identical_faces"}, "held": false, "lost_references": [], "moved_references": []})]
	RefState.merge_followed(first_listing, notes)
	var second_listing := [coincident("m1", 2, 4, {"followed_references": [], "reference_reasons": {}, "held": false, "lost_references": [], "moved_references": []})]
	RefState.merge_followed(second_listing, notes)
	print("SMOKE the next listing is clean, but the kept note brings the followed path back: ", second_listing[0]["followed_references"] == ["references[0].subshape_ref"] and RefState.note_for(second_listing[0])["kind"] == "followed")
	print("SMOKE ...with its reason: ", RefState.reason(second_listing[0], "references[0].subshape_ref") == "nearest_of_identical_faces")
	var other_owner := [coincident("m9", 1, 0, {"followed_references": [], "held": false, "lost_references": [], "moved_references": []})]
	RefState.merge_followed(other_owner, notes)
	print("SMOKE a mate that is gone takes its note with it: ", not notes.has("m1") and other_owner[0]["followed_references"] == [])
	var from_old := [coincident("m1", 1, 0)]
	RefState.merge_followed(from_old, {})
	print("SMOKE an older backend's listing is left exactly as it came: ", not from_old[0].has("followed_references") and not RefState.has_server_state(from_old[0]))
	quit()
