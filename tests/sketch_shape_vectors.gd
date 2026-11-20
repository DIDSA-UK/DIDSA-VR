extends SceneTree
## Headless, no network: the shape proposals (scripts/motion/shape_proposals.gd, parity follow-ups F8, written from DIDSA-CAD's docs/motion/sketch-projector-spec.md
## section 13) against DIDSA-CAD's docs/motion/sketch-shape-vectors.json (34 cases, 73 frames; the file's shapes come from the flat app's test fake). The json is COPIED to
## tests/fixtures/sketch_shape_vectors.json; with a DIDSA-CAD checkout reachable (env DIDSA_CAD_DIR, else ../DIDSA-CAD) the test also fails if the copy differs.
## Replay (spec 13.7): P = input.points with the earlier frames' expected.result laid over it; the proposal is computed from P, the grabbed id and the frame's target and
## compared with expected.proposal (same ids, each coordinate within the case's tolerance); plain or hybrid is decided from the constraints and equals expected.hybrid; the
## provisional sizes computed equal the file's; a hybrid frame makes 13.4's call with the file's sizes and its written-back points equal expected.result; a refused case
## (the grab rule's part that needs no rigidity) has no frames.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_shape_vectors.gd

const Shapes := preload("res://scripts/motion/shape_proposals.gd")
const FIXTURE := "res://tests/fixtures/sketch_shape_vectors.json"

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/motion/sketch-shape-vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/motion/sketch-shape-vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


static func _lay(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for id in over:
		out[id] = over[id]
	return out


## "" or why the positions differ (the same ids; each coordinate within tol).
static func same_points(got: Variant, want: Dictionary, tol: float) -> String:
	if not (got is Dictionary):
		return "no answer"
	var gk := (got as Dictionary).keys()
	var wk := want.keys()
	gk.sort()
	wk.sort()
	if gk != wk:
		return "ids %s, expected %s" % [gk, wk]
	for id in wk:
		for c in 2:
			if not (absf(float(got[id][c]) - float(want[id][c])) <= tol):
				return "%s[%d] %.10f vs %.10f (tol %.3g)" % [id, c, float(got[id][c]), float(want[id][c]), tol]
	return ""


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc: Variant = JSON.parse_string(text)
	if not (doc is Dictionary):
		_check(false, "fixture parses")
		quit(1)
		return
	_check(true, "fixture copy vs DIDSA-CAD: %s" % _source_check(text))
	var cases: Array = doc["cases"]
	var n_frames := 0
	var passed := 0
	var hybrid_frames := 0
	var by_kind := {}
	for c: Dictionary in cases:
		var inp: Dictionary = c["input"]
		var records: Dictionary = inp["shapes"]
		var exists := {}
		for lid in inp["lines"]:
			exists[lid] = true
		for sid in records:
			if str(records[sid].get("kind", "")) == "arc":
				exists[sid] = true
		var tol: float = float(c["tolerance"])
		var shape := Shapes.locate(records, inp["points"], exists, str(inp["grabbed"]))
		var refusal := "not a shape point" if shape.is_empty() else Shapes.grab_refusal(shape, inp["constraints"], records)
		var grab_ok := refusal == ""
		var problem := ""
		if grab_ok != bool(c["grab"]):
			problem = "grab %s (%s), the file says %s" % [grab_ok, refusal, c["grab"]]
		var P: Dictionary = (inp["points"] as Dictionary).duplicate(true)
		if problem == "" and grab_ok:
			var k := 0
			for f: Dictionary in c["frames"]:
				k += 1
				n_frames += 1
				var want: Dictionary = f["expected"]
				var T: Array = f["target"]
				var hybrid := Shapes.is_hybrid(shape, inp["constraints"], records)
				if hybrid != bool(want["hybrid"]):
					problem = "frame %d: hybrid %s, the file says %s" % [k, hybrid, want["hybrid"]]
					break
				var got: Dictionary = Shapes.frame(shape, str(inp["grabbed"]), P, T, inp["constraints"], inp["lines"], inp["pinned"], records, hybrid, want["provisional"])
				var why := same_points(got["proposal"], want["proposal"], tol) if want["proposal"] != null else ("" if got["proposal"] == null else "a proposal, the file has none")
				if why != "":
					problem = "frame %d proposal: %s" % [k, why]
					break
				if hybrid:
					hybrid_frames += 1
					var mine := Shapes.provisional_for(shape, inp["constraints"], P, got["proposal"])
					why = same_points(_pairs(mine), _pairs(want["provisional"]), tol)
					if why != "":
						problem = "frame %d provisional sizes: %s" % [k, why]
						break
					if str(got["clamp"]) != str(want["clamp"]):
						problem = "frame %d clamp %s, the file says %s" % [k, got["clamp"], want["clamp"]]
						break
				why = same_points(got["result"], want["result"], tol)
				if why != "":
					problem = "frame %d result: %s" % [k, why]
					break
				P = _lay(P, want["result"]) # the file's numbers, so errors do not accumulate
		if problem == "":
			passed += 1
		var kind := str(c["id"]).split("-")[0]
		if not by_kind.has(kind):
			by_kind[kind] = [0, 0]
		by_kind[kind][0] += 1
		by_kind[kind][1] += 1 if problem == "" else 0
		_check(problem == "", "shape case %s%s" % [c["id"], "" if problem == "" else " (" + problem + ")"])
	_check(passed == cases.size(), "shape vectors: %d cases, %d frames (%d hybrid), %d passed; per family %s" % [cases.size(), n_frames, hybrid_frames, passed, by_kind])
	print("SMOKE ", "PASSED" if failures == 0 else "FAILED")
	quit(0 if failures == 0 else 1)


## A {id: value} dictionary as {id: [value, 0]}, so same_points compares the sizes.
static func _pairs(sizes: Dictionary) -> Dictionary:
	var out := {}
	for id in sizes:
		out[id] = [float(sizes[id]), 0.0]
	return out
