extends SceneTree
## Headless, no network: the Appearance tool's resolution rule (scripts/appearance/appearance_rule.gd) against DIDSA-CAD's
## golden vectors - docs/appearance/vectors.json, written by its reference (backend/app/document/appearance.py). The same
## json gates the Dart copy in the flat app.
##
## The json is COPIED to tests/fixtures/appearance_vectors.json (tests/fixtures/README.md says how to refresh it). When a
## DIDSA-CAD checkout is reachable (env DIDSA_CAD_DIR, else ../DIDSA-CAD) this test also FAILS if the copy differs from the
## source, so a regenerated file cannot be silently missed.
## Run: "$GODOT" --headless --path . --script res://tests/appearance_vectors.gd

const Rule := preload("res://scripts/appearance/appearance_rule.gd")
const FIXTURE := "res://tests/fixtures/appearance_vectors.json"

var failures := 0


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/appearance/vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/appearance/vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc = JSON.parse_string(text)
	if not (doc is Dictionary):
		print("SMOKE FAILED: couldn't read ", FIXTURE)
		quit(1)
		return
	var src := _source_check(text)
	_check(src == "same" or src == "no source", "the fixture copy equals DIDSA-CAD's docs/appearance/vectors.json (%s)" % src)
	_check(Array(doc["fields"]) == Rule.FIELDS, "the record's fields are the reference's, in its order")
	var cases: Array = doc["cases"]
	var models: Dictionary = doc["models"]
	var mismatches: Array = []
	for c in cases:
		var model: Dictionary = models[c["model"]]
		var scene: Array = c["scene_overrides"] if c["scene_overrides"] is Array else []
		var got := Rule.resolve_appearance(model, str(c["root"]), Array(c["path"]), c["body_id"], c["face_index"], scene)
		if not Rule.same(got, c["expected"]):
			mismatches.append("%s: got %s, want %s" % [c["name"], str(got), str(c["expected"])])
	print("SMOKE golden vectors: ", cases.size(), " cases, ", mismatches.size(), " mismatches")
	for m in mismatches:
		print("  ", m)
	_check(cases.size() >= 50 and mismatches.is_empty(), "every golden vector resolves as the reference does")

	# resolve_faces (what the tool paints a whole mesh from) gives resolve_appearance's answer for every face.
	var faces: Array = []
	for body in ["a1", "a2", "b1", "fb", "rb", "rb2", "l1", "p1", "g1"]:
		for i in 9:
			faces.append([body, i])
	var face_mismatches := 0
	for c in cases:
		var model: Dictionary = models[c["model"]]
		var scene: Array = c["scene_overrides"] if c["scene_overrides"] is Array else []
		var by_face := Rule.resolve_faces(model, str(c["root"]), Array(c["path"]), faces, scene)
		for f in faces:
			var want := Rule.resolve_appearance(model, str(c["root"]), Array(c["path"]), f[0], f[1], scene)
			if not Rule.same(by_face[Rule.face_key(f[0], f[1])], want):
				face_mismatches += 1
	_check(face_mismatches == 0, "resolve_faces agrees with resolve_appearance face by face (%d mismatches)" % face_mismatches)

	# The record's checks match the backend's.
	_check(Rule.appearance_errors({"colour": "#A1B2C3", "opacity": 0.5, "metallic": 1, "emission_strength": 10}).is_empty(), "a full appearance is valid")
	_check(Rule.appearance_errors({}) == ["an appearance must set at least one field"], "an empty appearance is refused")
	_check(Rule.appearance_errors({"colour": "red"}) == ["colour must be '#RRGGBB'"], "a colour must be #RRGGBB")
	_check(not Rule.appearance_errors({"opacity": 1.5}).is_empty() and not Rule.appearance_errors({"emission_strength": 11}).is_empty(), "ranges are checked")
	_check(Rule.base_segment("bolt#pattern:p1:3") == "bolt" and Rule.base_segment("bolt") == "bolt", "a pattern copy's segment names its source")

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
