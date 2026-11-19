extends SceneTree
## Headless, no network: the sketch drag projector (scripts/motion/sketch_projector.gd, parity plan S9) against DIDSA-CAD's
## golden vectors - docs/motion/sketch-vectors.json, written by its reference (client/test/support/sketch_vectors.dart from
## client/lib/sketch/projector/sketch_projector.dart). The json is COPIED to tests/fixtures/sketch_vectors.json; when a DIDSA-CAD
## checkout is reachable (env DIDSA_CAD_DIR, else ../DIDSA-CAD) this test also fails if the copy differs.
## Replay (DIDSA-CAD docs/motion/sketch-projector-spec.md section 10): frame k starts from input.start with the FILE's earlier
## expected points laid over it (prev); points = prev + the frame's wish, reference = prev. unsupported, converged, rows,
## variable_points and the ids of points must match exactly; each coordinate within the case's tolerance (1e-5 x the start's
## diagonal). exit / walks / iterations are informational (a count of differences is printed).
## Also prints the timing of scene-chain-20-curled (ms per frame, against the 90 Hz budget of 11.1 ms).
## Run: "$GODOT" --headless --path . --script res://tests/sketch_projector_vectors.gd

const SketchProjector := preload("res://scripts/motion/sketch_projector.gd")
const FIXTURE := "res://tests/fixtures/sketch_vectors.json"
const TIMING_CASE := "scene-chain-20-curled"
const FRAME_BUDGET_MS := 1000.0 / 90.0

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/motion/sketch-vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/motion/sketch-vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


## One frame's call, as section 10 says.
static func frame_call(input: Dictionary, prev: Dictionary, wish: Dictionary) -> Dictionary:
	var points := prev.duplicate()
	for id in wish:
		points[id] = wish[id]
	return SketchProjector.project(points, input["constraints"], input["lines"], input["anchors"], input["pinned"],
		input["stiff"], prev, input["provisional"])


## Compares one answer with the file's; returns "" or why not.
static func compare(got: Dictionary, want: Dictionary, tol: float) -> String:
	for key in ["unsupported", "converged"]:
		if bool(got[key]) != bool(want[key]):
			return "%s %s, expected %s" % [key, got[key], want[key]]
	for key in ["variable_points", "rows"]:
		if int(got[key]) != int(want[key]):
			return "%s %d, expected %d" % [key, int(got[key]), int(want[key])]
	var gp: Dictionary = got["points"]
	var wp: Dictionary = want["points"]
	var gk := gp.keys()
	var wk := wp.keys()
	gk.sort()
	wk.sort()
	if gk != wk:
		return "point ids %s, expected %s" % [gk, wk]
	var worst := 0.0
	var where := ""
	for id in wk:
		for c in 2:
			var e := absf(float(gp[id][c]) - float(wp[id][c]))
			if not (e <= worst):
				worst = e
				where = "%s[%d] %.10f vs %.10f" % [id, c, float(gp[id][c]), float(wp[id][c])]
	if not (worst <= tol):
		return "off by %.3g > %.3g at %s" % [worst, tol, where]
	return ""


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc = JSON.parse_string(text)
	if not (doc is Dictionary):
		print("SMOKE FAILED: couldn't read ", FIXTURE)
		quit(1)
		return
	var src := _source_check(text)
	_check(src == "same" or src == "no source", "the fixture copy equals DIDSA-CAD's docs/motion/sketch-vectors.json (%s)" % src)
	_check(int(doc.get("version", 0)) == 1, "the file is version 1")
	var c := doc["constants"] as Dictionary
	_check(is_equal_approx(float(c["follower_stiffness"]), SketchProjector.FOLLOWER) and int(c["nearest_max"]) == SketchProjector.NEAREST_MAX
		and float(c["arrived"]) == SketchProjector.ARRIVED and float(c["min_omega"]) == SketchProjector.MIN_OMEGA
		and float(c["max_boost"]) == SketchProjector.MAX_BOOST and int(c["correctors"]) == SketchProjector.CORRECTORS
		and int(c["max_polish"]) == SketchProjector.MAX_POLISH and float(c["tolerance"]) == SketchProjector.TOLERANCE
		and float(c["trust"]) == SketchProjector.TRUST and float(c["trust_diagonal"]) == SketchProjector.TRUST_DIAGONAL
		and float(c["eps"]) == SketchProjector.EPS and float(c["lambda_relative"]) == SketchProjector.LAMBDA_RELATIVE
		and float(c["lambda_absolute"]) == SketchProjector.LAMBDA_ABSOLUTE and int(c["corrector_halvings"]) == SketchProjector.CORRECTOR_HALVINGS
		and float(c["closer_ratio"]) == SketchProjector.CLOSER_RATIO and float(c["rho_reverse"]) == SketchProjector.RHO_REVERSE
		and float(c["rho_boost_low"]) == SketchProjector.RHO_BOOST_LOW and float(c["rho_boost_high"]) == SketchProjector.RHO_BOOST_HIGH
		and int(c["stall_limit"]) == SketchProjector.STALL_LIMIT, "the file's constants are the projector's")

	var by_kind := {}
	var frames := 0
	var bad: Array = []
	var informational := 0
	var all_usec := 0
	var slowest := ["", 0.0]
	for case in doc["cases"]:
		var input: Dictionary = case["input"]
		var tol := float(case["tolerance"])
		var prev: Dictionary = (input["start"] as Dictionary).duplicate()
		var kind := str(case["kind"])
		if not by_kind.has(kind):
			by_kind[kind] = [0, 0]
		var case_ok := true
		var k := 0
		for frame in case["frames"]:
			var want: Dictionary = frame["expected"]
			var t_call := Time.get_ticks_usec()
			var got := frame_call(input, prev, frame["wish"])
			var took := Time.get_ticks_usec() - t_call
			all_usec += took
			if took / 1000.0 > float(slowest[1]):
				slowest = ["%s frame %d" % [case["id"], k], took / 1000.0]
			var why := compare(got, want, tol)
			frames += 1
			if why != "":
				case_ok = false
				print("  ", case["id"], " frame ", k, ": ", why, " (exit ", got["exit"], " vs ", want["exit"], ")")
			if str(got["exit"]) != str(want["exit"]) or int(got["walks"]) != int(want["walks"]) or int(got["iterations"]) != int(want["iterations"]):
				informational += 1
			for id in want["points"]:
				prev[id] = want["points"][id]
			k += 1
		by_kind[kind][0] += 1
		if case_ok:
			by_kind[kind][1] += 1
		else:
			bad.append(case["id"])
	print("SMOKE sketch vectors: ", (doc["cases"] as Array).size(), " cases, ", frames, " frames; per kind (cases, passed) ", by_kind)
	print("SMOKE timing all vectors: %.2f ms per frame mean over %d frames; slowest %s at %.2f ms (first pass, cold)" % [
		all_usec / 1000.0 / maxi(frames, 1), frames, slowest[0], slowest[1]])
	print("SMOKE informational: frames whose exit / walks / iterations differ from the file's: ", informational)
	_check((doc["cases"] as Array).size() >= 90 and bad.is_empty(), "every vector within its tolerance, every exact field equal (failed: %s)" % [bad])

	# the timing vector: every frame, a few rounds, after one warm-up
	for case in doc["cases"]:
		if str(case["id"]) != TIMING_CASE:
			continue
		var input: Dictionary = case["input"]
		var calls := []
		var prev: Dictionary = (input["start"] as Dictionary).duplicate()
		for frame in case["frames"]:
			calls.append([prev.duplicate(), frame["wish"]])
			for id in frame["expected"]["points"]:
				prev[id] = frame["expected"]["points"][id]
		frame_call(input, calls[0][0], calls[0][1])
		var rounds := 5
		var worst := 0.0
		var t0 := Time.get_ticks_usec()
		for r in rounds:
			for call in calls:
				var t1 := Time.get_ticks_usec()
				frame_call(input, call[0], call[1])
				worst = maxf(worst, (Time.get_ticks_usec() - t1) / 1000.0)
		var mean := (Time.get_ticks_usec() - t0) / 1000.0 / (rounds * calls.size())
		print("SMOKE timing %s: %.2f ms per frame mean, %.2f ms worst (%d frames x %d rounds; 90 Hz budget %.1f ms)" % [
			TIMING_CASE, mean, worst, calls.size(), rounds, FRAME_BUDGET_MS])
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
