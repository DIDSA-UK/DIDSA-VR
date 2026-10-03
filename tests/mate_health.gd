extends SceneTree
## "Does a mate still point at the face it was made on?" (scripts/design_table/mate_health.gd), on synthetic parts with the backend's face
## identity: a face's signature (outward normal, offset, area, flatness), when two faces count as the same (a plane faces the same way at the
## same place; area ignored; a different kind or a missing face is not the same), capturing the mate references that land on the edited part,
## and — the case a real run of the design table hit — a boss added to a plate renumbering "top" and "bottom" into the two SIDE faces.
## Run: "$GODOT" --headless --path . --script res://tests/mate_health.gd  (see tests/README.md)

const Health := preload("res://scripts/design_table/mate_health.gd")


func part(faces: Array, kinds: Array, occurrence := "occ1") -> MeshInstance3D:
	## faces: [[tri, tri, ...], ...] one entry per face id, each tri = [a, b, c] (clockwise seen from outside, Godot's front-face winding).
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
	## Two triangles of a square at height z, wound so its outward normal is +Z (facing_up) or -Z.
	var a := Vector3(x0, 0, z)
	var b := Vector3(x0, size, z)
	var c := Vector3(x0 + size, size, z)
	var d := Vector3(x0 + size, 0, z)
	return [[a, b, d], [b, c, d]] if facing_up else [[a, d, b], [d, c, b]]


func wall(x: float, facing_plus_x: bool) -> Array:
	## A square in the YZ plane at x, outward normal +X or -X.
	var a := Vector3(x, 0, 0)
	var b := Vector3(x, 10, 0)
	var c := Vector3(x, 10, 10)
	var d := Vector3(x, 0, 10)
	return [[a, b, d], [b, c, d]] if facing_plus_x else [[a, d, b], [d, c, b]]


func _initialize() -> void:
	# --- signature
	var plate := part([square(0, false), square(10, true)], ["plane", "plane"])
	var bottom := Health.signature(plate, "B", 0)
	var top := Health.signature(plate, "B", 1)
	print("SMOKE a face's signature has its outward normal, offset and area: ", bottom["n"].is_equal_approx(Vector3(0, 0, -1)) and top["n"].is_equal_approx(Vector3(0, 0, 1)) and absf(top["offset"] - 10.0) < 0.001 and absf(top["area"] - 100.0) < 0.001)
	print("SMOKE ...and how flat it is: ", absf(top["flatness"] - 1.0) < 0.0001 and top["kind"] == "plane")
	print("SMOKE a face that doesn't exist has no signature: ", Health.signature(plate, "B", 7).is_empty() and Health.signature(plate, "NOPE", 0).is_empty())

	# --- same
	print("SMOKE the same face is the same: ", Health.same(top, Health.signature(plate, "B", 1)))
	var raised := part([square(0, false), square(10.1, true)], ["plane", "plane"])
	print("SMOKE a plane moved 0.1 mm is not the same (a mate would be 0.1 mm out): ", not Health.same(top, Health.signature(raised, "B", 1)))
	var nearly := part([square(0, false), square(10.03, true)], ["plane", "plane"])
	print("SMOKE ...but 0.03 mm is within tolerance: ", Health.same(top, Health.signature(nearly, "B", 1)))
	var big := part([square(0, false), square(10, true, 0.0, 20.0)], ["plane", "plane"])
	print("SMOKE a plane that grew keeps being the same plane (a mate needs the plane, not the area): ", Health.same(top, Health.signature(big, "B", 1)))
	var flipped := part([square(0, true), square(10, false)], ["plane", "plane"])
	print("SMOKE a plane facing the other way is not the same: ", not Health.same(top, Health.signature(flipped, "B", 1)))
	var ta := Vector3(0, 0, 10)
	var tb := Vector3(0, 10, 10)
	var tc := Vector3(10, 10, 10.875) # 10 mm run, 0.875 mm rise: a plane tilted 5 degrees
	var td := Vector3(10, 0, 10.875)
	var tilted := part([square(0, false), [[ta, tb, td], [tb, tc, td]]], ["plane", "plane"])
	print("SMOKE a plane tilted 5 degrees is not the same: ", not Health.same(top, Health.signature(tilted, "B", 1)))
	var as_cylinder := part([square(0, false), square(10, true)], ["plane", "cylinder"])
	print("SMOKE a different kind of face is not the same: ", not Health.same(top, Health.signature(as_cylinder, "B", 1)))
	print("SMOKE a face that is gone is not the same: ", not Health.same(top, {}) and not Health.same({}, top))
	var no_kinds_flat := part([square(0, false), square(10, true)], [])
	var no_kinds_flat_after := part([square(0, false), square(10, true, 0.0, 12.0)], [])
	print("SMOKE with an older backend (no kinds) a flat face is still compared as a plane: ", Health.same(Health.signature(no_kinds_flat, "B", 1), Health.signature(no_kinds_flat_after, "B", 1)))
	var round := part([[ [Vector3(0, 0, 0), Vector3(0, 10, 0), Vector3(10, 0, 0)], [Vector3(0, 0, 0), Vector3(0, 0, 10), Vector3(0, 10, 0)], [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(0, 0, 10)] ]], [])
	var round_sig := Health.signature(round, "B", 0)
	print("SMOKE a curved face (its triangles disagree) is not mistaken for a plane: ", round_sig["flatness"] < 0.9)

	# --- the real case: a boss renumbers top/bottom into the two sides
	var mates := [{"id": "m1", "suppressed": false, "references": [
		{"occurrence_id": "occ1", "subshape_ref": {"body_id": "B", "shape_type": "face", "index": 1}},
		{"occurrence_id": "occ2", "subshape_ref": {"body_id": "B", "shape_type": "face", "index": 0}}]}]
	var before_one := part([square(0, false), square(10, true)], ["plane", "plane"], "occ1")
	var before_two := part([square(0, false), square(10, true)], ["plane", "plane"], "occ2")
	var captured := Health.capture([before_one, before_two], mates)
	print("SMOKE capturing records both faces the mate names, one per instance: ", captured.size() == 2 and captured[0]["occurrence_id"] == "occ1" and captured[0]["index"] == 1 and captured[1]["index"] == 0)
	print("SMOKE ...with what each looked like: ", captured[0]["before"]["n"].is_equal_approx(Vector3(0, 0, 1)) and captured[1]["before"]["n"].is_equal_approx(Vector3(0, 0, -1)))
	var after_one := part([wall(0, false), wall(10, true)], ["plane", "plane"], "occ1")
	var after_two := part([wall(0, false), wall(10, true)], ["plane", "plane"], "occ2")
	var moved := Health.drifted(captured, [after_one, after_two])
	print("SMOKE after the faces are renumbered into the two sides, both references have drifted: ", moved.size() == 2)
	print("SMOKE ...and it is one mate that needs attention: ", Health.mate_ids(moved) == ["m1"])
	var same_one := part([square(0, false), square(10, true, 0.0, 14.0)], ["plane", "plane"], "occ1")
	var same_two := part([square(0, false), square(10, true, 0.0, 14.0)], ["plane", "plane"], "occ2")
	print("SMOKE after an edit that leaves those planes alone nothing has drifted: ", Health.drifted(captured, [same_one, same_two]).is_empty())
	var fewer := part([square(0, false)], ["plane"], "occ1")
	print("SMOKE a face index that no longer exists has drifted: ", Health.drifted(captured, [fewer, same_two]).size() == 1)

	# --- what capture leaves out
	var skipped := Health.capture([before_one], [
		{"id": "s", "suppressed": true, "references": [{"occurrence_id": "occ1", "subshape_ref": {"body_id": "B", "shape_type": "face", "index": 1}}]},
		{"id": "e", "suppressed": false, "references": [{"occurrence_id": "occ1", "subshape_ref": {"body_id": "B", "shape_type": "edge", "index": 1}}]},
		{"id": "o", "suppressed": false, "references": [{"occurrence_id": "other", "subshape_ref": {"body_id": "B", "shape_type": "face", "index": 1}}]},
		{"id": "p", "suppressed": false, "references": [{"occurrence_id": "occ1", "subshape_ref": null, "plane_ref": {"fixed_plane": "XY"}}]}])
	print("SMOKE suppressed mates, edge references, other parts and plane refs are left out: ", skipped.is_empty())
	print("SMOKE with no mates there is nothing to capture or to have drifted: ", Health.capture([before_one], []).is_empty() and Health.drifted([], [before_one]).is_empty())
	quit()
