extends SceneTree
## The sketch origin (DIDSA-CAD docs/view-override-edit-alone-sketch-origin-plan.md, 3a) as the design table draws it. A flat-app sketch can have its
## origin moved (a Body corner, a Sketch Point, a circular edge's centre): the backend says where in `resolved_origin` on the sketch-feature row, and the
## table must draw from there, not from the plane's own origin. Covers: SketchMath.with_origin (moved, absent key = an older backend, null = lost, axes
## and normal untouched); a sketch opened on a face asks for "origin": "auto" and its plane starts at the resolved corner; one on a reference plane or a
## made plane sends no origin and keeps the plane's; a finished sketch's row with an origin is placed by it when reopened and when its curves are loaded
## for a Loft / Sweep / Pattern pick; and a .didsa file's sketch feature keeps its `origin` through native_compose.gd. Fake backend, headless.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_origin.gd  (see tests/README.md)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const Session := preload("res://scripts/design_table/sketch_session.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const DIR := "user://sketch_origin_test"


func _initialize() -> void:
	# --- SketchMath.with_origin
	var plane := SketchMath.fixed_basis("XZ")
	var moved := SketchMath.with_origin(plane, {"resolved_origin": [10.0, 20.0, 30.0]})
	print("SMOKE with_origin moves the origin to resolved_origin: ", moved["origin"].is_equal_approx(Vector3(10, 20, 30)))
	print("SMOKE ...and leaves the axes and the normal the plane's (XZ's x is -X): ", moved["x"].is_equal_approx(Vector3(-1, 0, 0)) and moved["y"].is_equal_approx(Vector3(0, 0, 1)) and moved["n"].is_equal_approx(Vector3(0, 1, 0)))
	print("SMOKE ...without touching the basis it was given: ", plane["origin"].is_equal_approx(Vector3.ZERO))
	print("SMOKE a row with no resolved_origin key (an older backend, or a sketch from before the origin) keeps the plane's origin: ", SketchMath.with_origin(plane, {"id": "f", "sketch_id": "s"}) == plane)
	print("SMOKE ...and a resolved_origin of null (a lost reference: the backend fell back to the plane's origin) keeps it too: ", SketchMath.with_origin(plane, {"resolved_origin": null}) == plane)
	print("SMOKE ...a malformed one is ignored, and an empty basis stays empty: ", SketchMath.with_origin(plane, {"resolved_origin": [1, 2]}) == plane and SketchMath.with_origin({}, {"resolved_origin": [1, 2, 3]}).is_empty())
	print("SMOKE the sheet is measured from the moved origin (XZ's x runs toward -X, so a point one unit toward -X of it is sheet (1, 0)): ", SketchMath.to_sheet(Vector3(9, 20, 30), moved).is_equal_approx(Vector2(1, 0)) and SketchMath.to_sheet(Vector3(10, 20, 30), moved).is_equal_approx(Vector2.ZERO))

	# --- opening a sketch
	var fake := Fake.new()
	fake.auto_origin = [10.0, 0.0, 10.0]
	var s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	var ok: bool = await s.open_sketch({"face": {"body_id": "B", "index": 4}})
	var sketch_call: Array = fake.calls.filter(func(c): return c[0] == "POST /document/parts/P/features/sketch")[0]
	print("SMOKE a sketch on a face asks for the default origin ('origin': 'auto'): ", ok and sketch_call[1] == {"plane_feature_id": "plane1", "origin": "auto"})
	print("SMOKE ...and its plane starts at the origin the backend resolved (not the face plane's own origin, (0, 0, 10)): ", s.plane["origin"].is_equal_approx(Vector3(10, 0, 10)))
	print("SMOKE ...with the face plane's axes: ", s.plane["x"].is_equal_approx(Vector3(1, 0, 0)) and s.plane["y"].is_equal_approx(Vector3(0, 1, 0)))
	print("SMOKE ...so the sketch's local (0, 0) is that corner: ", SketchMath.from_sheet(Vector2.ZERO, s.plane).is_equal_approx(Vector3(10, 0, 10)))

	fake = Fake.new() # a backend with no corner to give (a face with a curved edge, say): resolved_origin null
	s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	ok = await s.open_sketch({"face": {"body_id": "B", "index": 4}})
	print("SMOKE a face the backend gives no origin for keeps the plane's own origin: ", ok and s.plane["origin"].is_equal_approx(Vector3(0, 0, 10)))

	fake = Fake.new()
	fake.auto_origin = [10.0, 0.0, 10.0]
	s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	ok = await s.open_sketch({"fixed": "XY"})
	print("SMOKE a sketch on a reference plane sends no origin, and keeps the plane's: ", ok and fake.calls[0][1] == {"plane": "XY"} and s.plane["origin"].is_equal_approx(Vector3.ZERO))
	fake.calls.clear()
	var made = Session.new(Callable(fake, "handle"))
	made.owner_part_id = "P"
	ok = await made.open_sketch({"plane_feature_id": "PL", "plane": {"origin": Vector3(0, 0, 5), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}})
	var made_call: Array = fake.calls.filter(func(c): return c[0] == "POST /document/parts/P/features/sketch")[0]
	print("SMOKE ...and so does one on a plane the table made (the plane's origin, as before): ", ok and made_call[1] == {"plane_feature_id": "PL"} and made.plane["origin"].is_equal_approx(Vector3(0, 0, 5)))

	# --- reopening a sketch with a moved origin
	var row := {"id": "feat9", "sketch_id": "sk1", "plane_feature_id": null, "resolved_origin": [4.0, 5.0, 0.0]}
	fake = Fake.new()
	s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	ok = await s.reopen(row, SketchMath.with_origin(SketchMath.fixed_basis("XY"), row))
	print("SMOKE reopening a finished sketch whose row carries an origin draws from it: ", ok and s.plane["origin"].is_equal_approx(Vector3(4, 5, 0)) and s.feature_id == "feat9")

	# --- the .didsa file
	DirAccess.make_dir_recursive_absolute(DIR)
	var origin_value := {"point_ref": {"vertex_ref": {"body_id": "b1", "shape_type": "vertex", "index": 3}, "sketch_point_ref": null}, "circle_centre_ref": null}
	var point_value := {"point_ref": {"vertex_ref": null, "sketch_point_ref": {"sketch_id": "sk0", "entity_type": "point", "entity_id": "p7"}}, "circle_centre_ref": null}
	var centre_value := {"point_ref": null, "circle_centre_ref": {"body_id": "b1", "shape_type": "edge", "index": 9}}
	var root_part := {"id": "root", "name": "root", "occurrences": [{"id": "o1", "external_ref": "Child.didsa", "resolved_part_id": null, "name_override": null,
		"transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}, "suppressed": false, "hidden": false, "fixed": false, "color": null}], "mates": [], "features": []}
	var child_part := {"id": "child", "name": "child", "occurrences": [], "mates": [], "features": [
		{"type": "sketch", "id": "f1", "sketch_id": "sk1", "plane_feature_id": null, "origin": origin_value},
		{"type": "sketch", "id": "f2", "sketch_id": "sk2", "plane_feature_id": null, "origin": point_value},
		{"type": "sketch", "id": "f3", "sketch_id": "sk3", "plane_feature_id": "pl", "origin": centre_value},
		{"type": "sketch", "id": "f4", "sketch_id": "sk4", "plane_feature_id": null}]}
	_write("Root.didsa", {"schema_version": 1, "document": {"id": "d-root", "root_part_id": "root", "parts": [root_part]}, "sketches": []})
	_write("Child.didsa", {"schema_version": 1, "document": {"id": "d-child", "root_part_id": "child", "parts": [child_part]}, "sketches": []})
	var composed := NativeCompose.compose(DIR.path_join("Root.didsa"))
	var payload = JSON.parse_string(composed["text"]) if composed["ok"] else {}
	var features: Array = []
	for part in (payload["document"]["parts"] if payload is Dictionary else []):
		if part["id"] == "child":
			features = part["features"]
	# (compared after one JSON round trip each, so 3 and 3.0 are the same number; the composer keeps the text's own number types, see above)
	print("SMOKE a composed assembly keeps a sketch feature's origin as written (a vertex_ref): ", features.size() == 4 and _same(features[0].get("origin"), origin_value))
	print("SMOKE ...a sketch_point_ref origin: ", features.size() == 4 and _same(features[1].get("origin"), point_value))
	print("SMOKE ...a circle_centre_ref origin: ", features.size() == 4 and _same(features[2].get("origin"), centre_value))
	print("SMOKE ...the indices stay integers in the text (the backend refuses 3.0 for an integer field): ", composed["text"].contains('"index":3') and composed["text"].contains('"index":9') and not composed["text"].contains('"index":3.0'))
	print("SMOKE ...and a sketch with no origin gets none added: ", features.size() == 4 and not features[3].has("origin"))
	print("SMOKE ...the refs are Part-local, so nothing in them was renamed: ", composed["text"].contains('"entity_id":"p7"') and composed["text"].contains('"body_id":"b1"'))
	_clean()
	quit()


func _same(a, b) -> bool:
	return JSON.stringify(JSON.parse_string(JSON.stringify(a)), "", true) == JSON.stringify(JSON.parse_string(JSON.stringify(b)), "", true)


func _write(name: String, payload: Dictionary) -> void:
	var f := FileAccess.open(DIR.path_join(name), FileAccess.WRITE)
	f.store_string(NativeCompose.to_json(payload))
	f.close()


func _clean() -> void:
	var d := DirAccess.open(DIR)
	if d != null:
		for file in d.get_files():
			d.remove(file)
	DirAccess.remove_absolute(DIR)
