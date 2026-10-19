extends SceneTree
## Headless, no network: scene composition (scripts/appearance/scene_compose.gd) against DIDSA-CAD's golden vectors -
## docs/scenes/vectors.json, written by its reference (backend/app/document/scene_compose.py). The json is COPIED to
## tests/fixtures/scene_vectors.json; when a DIDSA-CAD checkout is reachable (env DIDSA_CAD_DIR, else ../DIDSA-CAD) this test also
## fails if the copy differs. Poses are compared to the file's tolerance (float32 clients); appearances exactly. Also checks the
## Godot Transform3D conversions both ways.
## Run: "$GODOT" --headless --path . --script res://tests/scene_vectors.gd

const Compose := preload("res://scripts/appearance/scene_compose.gd")
const Rule := preload("res://scripts/appearance/appearance_rule.gd")
const FIXTURE := "res://tests/fixtures/scene_vectors.json"

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/scenes/vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/scenes/vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


func _close(a, b, tol: float) -> bool:
	if a is Dictionary:
		if not (b is Dictionary) or (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k in a:
			if not (b as Dictionary).has(k) or not _close(a[k], b[k], tol):
				return false
		return true
	if a is Array:
		if not (b is Array) or (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _close(a[i], b[i], tol):
				return false
		return true
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) <= tol
	return a == b


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc = JSON.parse_string(text)
	if not (doc is Dictionary):
		print("SMOKE FAILED: couldn't read ", FIXTURE)
		quit(1)
		return
	var src := _source_check(text)
	_check(src == "same" or src == "no source", "the fixture copy equals DIDSA-CAD's docs/scenes/vectors.json (%s)" % src)
	var tol := float(doc["tolerance"])
	var mismatches: Array = []
	for c in doc["cases"]:
		var scene: Dictionary = c["scene"] if c["scene"] is Dictionary else {}
		var got := Compose.compose_scene(doc["nodes"], doc["model"], str(doc["root"]), scene)
		if not _close(got, c["expected"], tol):
			mismatches.append(str(c["name"]))
	print("SMOKE golden vectors: ", (doc["cases"] as Array).size(), " cases, mismatches ", mismatches)
	_check((doc["cases"] as Array).size() >= 6 and mismatches.is_empty(), "every scene vector composes as the reference does (tolerance %s)" % str(tol))

	var t := {"translation": [10.0, -20.0, 30.0], "rotation_axis": [0.0, 0.6, 0.8], "rotation_angle_degrees": 70.0}
	var xf := Compose.to_transform(Compose.pose(t))
	var back := Compose.from_transform(xf)
	_check(Compose.to_transform(Compose.pose(back)).is_equal_approx(xf), "a transform survives Transform3D and back")
	_check((xf * Vector3(1, 0, 0)).is_equal_approx(Basis(Vector3(0, 0.6, 0.8), deg_to_rad(70.0)) * Vector3(1, 0, 0) + Vector3(10, -20, 30)), "the row-major basis matches Godot's rotation (columns transposed in)")
	_check(Compose.parent_path("a/b#pattern:p:1/c") == "a/b#pattern:p:1" and Compose.parent_path("a") == "" and Compose.parent_path("") == null, "parent paths")
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
