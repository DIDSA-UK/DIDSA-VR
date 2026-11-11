extends SceneTree
## A sketch's whole frame from the backend (DIDSA-CAD docs/flutter-testing-feedback-2026-11-11-plan.md item 2, V2): `SketchMath.with_frame` takes the
## row's resolved frame (`resolved_frame_origin`, `resolved_x_axis`, `resolved_y_axis`, `resolved_normal`: anchor plane -> alignment to an edge or line ->
## flip / turns -> origin) instead of building it from the plane; a right-handed frame, a MIRRORED (flipped) one (x cross y = -normal: laid out with
## n = x cross y so the sheet is seen from the other side), a row without the frame (an older backend: the plane with its origin moved, as before).
## Through the real editor on the fake backend: a turned, a flipped and an aligned sketch are reopened / placed (they used to be refused) with their
## curves where the frame says; only a flipped or turned row from an older backend (no frame) is still refused ("frame can't be worked out here").
## native_compose.gd keeps a sketch feature's `x_axis_ref` as it was. Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_frame.gd

const Rig := preload("res://tests/helpers/table_rig.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _frame_row(origin: Array, x: Array, y: Array, normal: Array) -> Dictionary:
	return {"resolved_frame_origin": origin, "resolved_x_axis": x, "resolved_y_axis": y, "resolved_normal": normal}


func _table_lands(plane: Dictionary, uv: Vector2) -> bool:
	## A point at (u, v) on the sheet, turned onto the table, lies at (u, 0, -v) from the origin (x to the right, y away): the layout is a rotation.
	var rot: Basis = SketchMath.orient_to_table(plane)
	var at: Vector3 = rot * (SketchMath.from_sheet(uv, plane) - (plane["origin"] as Vector3))
	return at.is_equal_approx(Vector3(uv.x, 0.0, -uv.y))


func _initialize() -> void:
	var c := cos(deg_to_rad(30.0))
	var s := sin(deg_to_rad(30.0))
	# Aligned at 30 degrees on XY, right-handed.
	var aligned := SketchMath.with_frame(SketchMath.fixed_basis("XY"), _frame_row([1, 2, 3], [c, s, 0], [-s, c, 0], [0, 0, 1]))
	_check(aligned["origin"].is_equal_approx(Vector3(1, 2, 3)) and aligned["x"].is_equal_approx(Vector3(c, s, 0)) and aligned["y"].is_equal_approx(Vector3(-s, c, 0)) and aligned["n"].is_equal_approx(Vector3(0, 0, 1)) and not aligned["mirrored"],
		"an aligned sketch's frame is the row's, right-handed")
	_check(SketchMath.from_sheet(Vector2(10, 5), aligned).is_equal_approx(Vector3(1 + 10 * c - 5 * s, 2 + 10 * s + 5 * c, 3)), "a point drawn at (10, 5) is at origin + u*x + v*y in the part")
	_check(_table_lands(aligned, Vector2(10, 5)), "...and it lands at (10, 0, -5) on the table (x right, y away)")
	# Flipped: x negated, so x cross y = -normal: a left-handed frame.
	var flipped := SketchMath.with_frame(SketchMath.fixed_basis("XY"), _frame_row([0, 0, 0], [-1, 0, 0], [0, 1, 0], [0, 0, 1]))
	_check(flipped["mirrored"] and flipped["n"].is_equal_approx(Vector3(0, 0, -1)), "a flipped frame is mirrored; its n is x cross y (the sheet is seen from the other side)")
	_check(SketchMath.from_sheet(Vector2(10, 5), flipped).is_equal_approx(Vector3(-10, 5, 0)) and _table_lands(flipped, Vector2(10, 5)), "...a point at (10, 5) is at (-10, 5, 0) in the part and still lands at (10, 0, -5) on the table")
	# Turned a quarter: x = the plane's y, y = -x.
	var turned := SketchMath.with_frame({}, _frame_row([0, 0, 0], [0, 1, 0], [-1, 0, 0], [0, 0, 1]))
	_check(not turned.is_empty() and not turned["mirrored"] and _table_lands(turned, Vector2(7, -3)), "a turned sketch needs no plane at all: the frame alone places it")
	# An older backend: no frame keys, the plane with its origin moved (or untouched).
	var plain := SketchMath.with_frame(SketchMath.fixed_basis("XY"), {"resolved_origin": [5, 6, 0]})
	_check(plain["origin"].is_equal_approx(Vector3(5, 6, 0)) and plain["x"].is_equal_approx(Vector3(1, 0, 0)) and not plain.has("mirrored"), "a row without the frame falls back to the plane with its origin moved")
	_check(SketchMath.with_frame({}, {}).is_empty() and not SketchMath.has_frame({"resolved_x_axis": [1, 0, 0]}), "...an empty basis and a partial frame stay as they were")
	_check(SketchMath.with_frame(SketchMath.fixed_basis("XY"), _frame_row([0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1])).get("mirrored") == false and SketchMath.with_frame(SketchMath.fixed_basis("XY"), {"resolved_frame_origin": null, "resolved_x_axis": null}).get("origin") == Vector3.ZERO, "null frame keys (the backend could not work it out) fall back too")

	# native_compose keeps x_axis_ref as it was (it passes a sketch feature through untouched).
	var dir := "user://sketch_frame_test"
	DirAccess.make_dir_recursive_absolute(dir)
	var aligned_ref := {"sketch_id": "s1", "entity_type": "line", "entity_id": "l1"}
	var payload := {"schema_version": 1, "document": {"id": "d", "root_part_id": "p", "parts": [{"id": "p", "name": "p", "features": [
		{"type": "sketch", "id": "f2", "sketch_id": "s2", "plane_feature_id": null, "x_axis_ref": aligned_ref},
		{"type": "sketch", "id": "f3", "sketch_id": "s3", "plane_feature_id": null, "x_axis_ref": {"edge_ref": {"body_id": "b", "shape_type": "edge", "index": 4}}}],
		"occurrences": [{"id": "o", "external_ref": "child.didsa", "name_override": null, "transform": null, "suppressed": false, "hidden": false}], "mates": []}]}, "sketches": []}
	var child := {"schema_version": 1, "document": {"id": "dc", "root_part_id": "c", "parts": [{"id": "c", "name": "c", "features": [{"type": "sketch", "id": "g", "sketch_id": "sc", "plane_feature_id": null, "x_axis_ref": aligned_ref}], "occurrences": [], "mates": []}]}, "sketches": []}
	var root_file := FileAccess.open(dir.path_join("root.didsa"), FileAccess.WRITE)
	root_file.store_string(JSON.stringify(payload))
	root_file.close()
	var child_file := FileAccess.open(dir.path_join("child.didsa"), FileAccess.WRITE)
	child_file.store_string(JSON.stringify(child))
	child_file.close()
	var composed := NativeCompose.compose(dir.path_join("root.didsa"))
	var parts: Array = JSON.parse_string(composed["text"])["document"]["parts"]
	var kept_root := false
	var kept_child := false
	for part in parts:
		for f in part["features"]:
			if f["id"] == "f2":
				kept_root = f.get("x_axis_ref", {}).get("entity_id") == "l1"
			if f["id"] == "f3":
				kept_root = kept_root and f.get("x_axis_ref", {}).get("edge_ref", {}).get("index") == 4
			if f["id"] == "g":
				kept_child = f.get("x_axis_ref", {}).get("entity_id") == "l1"
	_check(composed["ok"] and kept_root and kept_child, "native_compose keeps a sketch feature's x_axis_ref (a line and an edge, in the root and in a composed file)")

	# The real editor on the fake backend.
	var rig = Rig.new()
	await rig.boot(self, false)
	var table = rig.table
	var ed = rig.ed
	var fake = rig.fake
	fake.sketch_plane = "XY"
	fake.filtered_mesh_bytes = fake.mesh_bytes
	fake.points = {"pA": Vector2(0, 0), "pB": Vector2(40, 0)}
	fake.entities = [{"type": "line", "id": "lnA", "start_point_id": "pA", "end_point_id": "pB", "construction": false}]
	var base := {"type": "sketch", "plane_feature_id": null, "locked": false, "has_lost_reference": false}
	fake.feature_rows = {"PART_BOX": [
		base.merged({"id": "skAligned", "sketch_id": "s1", "x_axis_ref": aligned_ref}.merged(_frame_row([0, 0, 0], [c, s, 0], [-s, c, 0], [0, 0, 1]))),
		base.merged({"id": "skFlipped", "sketch_id": "s2"}.merged(_frame_row([0, 0, 0], [-1, 0, 0], [0, 1, 0], [0, 0, 1]))),
		base.merged({"id": "skTurned", "sketch_id": "s3"}.merged(_frame_row([0, 0, 0], [0, 1, 0], [-1, 0, 0], [0, 0, 1]))),
		base.merged({"id": "skOld", "sketch_id": "s4"}),
	]}
	table.seat(rig.box)
	table.build.clear()
	await table.build.reload()
	await rig.settle(func() -> bool: return table.build.features.size() == 4)

	var picks_plane: Dictionary = await ed._plane_for_row(table.build.row("skAligned"))
	_check(picks_plane.get("x", Vector3.ZERO).is_equal_approx(Vector3(c, s, 0)), "the plane a pick places an aligned sketch on has the aligned axes (it would have opened with the wrong axes before)")
	var flipped_plane: Dictionary = await ed._plane_for_row(table.build.row("skFlipped"))
	_check(not flipped_plane.is_empty() and bool(flipped_plane["mirrored"]), "...a flipped sketch is placed too (it used to be left out)")

	var ok_aligned: bool = await ed.reopen_sketch("skAligned")
	_check(ok_aligned and ed.session != null and ed.session.plane["x"].is_equal_approx(Vector3(c, s, 0)), "reopening an aligned sketch draws it in the aligned frame")
	_check(ok_aligned and SketchMath.from_sheet(Vector2(40, 0), ed.session.plane).is_equal_approx(Vector3(40 * c, 40 * s, 0)), "...its 40 mm line ends where the frame says, 30 degrees up")
	ed.end_sketch()
	await rig.frames(3)
	var ok_flipped: bool = await ed.reopen_sketch("skFlipped")
	_check(ok_flipped and ed.session != null and bool(ed.session.plane["mirrored"]) and SketchMath.from_sheet(Vector2(40, 0), ed.session.plane).is_equal_approx(Vector3(-40, 0, 0)), "reopening a flipped sketch works and its line ends at -40 in X")
	ed.end_sketch()
	await rig.frames(3)
	var ok_turned: bool = await ed.reopen_sketch("skTurned")
	_check(ok_turned and ed.session != null and SketchMath.from_sheet(Vector2(40, 0), ed.session.plane).is_equal_approx(Vector3(0, 40, 0)), "reopening a turned sketch works and its line runs along the part's Y")
	ed.end_sketch()
	await rig.frames(3)

	# An older backend: a flipped sketch with no frame cannot be placed from the plane alone, so it is still refused, with the new message.
	fake.sketch_flip = true
	var refused: bool = await ed.reopen_sketch("skOld")
	_check(not refused and table.status().contains("frame can't be worked out here"), "a flipped sketch from an older backend (no frame) is still refused: %s" % table.status())
	fake.sketch_flip = false

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
