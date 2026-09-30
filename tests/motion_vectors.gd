extends SceneTree
## Headless, no network: the free-motion projector (scripts/motion/*.gd) against
## DIDSA-CAD's golden vectors — docs/motion/vectors.json, tolerance 1e-9, poses
## compared as matrices. The SAME json gates the Dart port (CAD session S6).
##
## The json is COPIED to tests/fixtures/motion_vectors.json (see
## tests/fixtures/motion_vectors.README.md for the CAD commit and how to refresh
## it). When a DIDSA-CAD checkout is reachable (env DIDSA_CAD_DIR, else
## ../DIDSA-CAD) this test also FAILS if the copy differs from the source, so a
## regenerated file cannot be silently missed.
## Run: "$GODOT" --headless --path . --script res://tests/motion_vectors.gd

const Se3 := preload("res://scripts/motion/se3.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const Blender := preload("res://scripts/motion/motion_blender.gd")
const Hysteresis := preload("res://scripts/motion/dof_hysteresis.gd")
const Scheduler := preload("res://scripts/motion/reanchor_scheduler.gd")

const FIXTURE := "res://tests/fixtures/motion_vectors.json"
const CX := 15.0 ## the swing scene's pin-axis offset (generate.py)

var tol := 1e-9
var failures := 0
var checks := 0
var worst := 0.0
var first_failure := ""


func _fail(ctx: String, msg: String) -> void:
	failures += 1
	if first_failure == "":
		first_failure = "%s: %s" % [ctx, msg]


func _num(got, want, ctx: String) -> void:
	checks += 1
	if want == null:
		if got != null:
			_fail(ctx, "expected null, got %s" % str(got))
		return
	if got == null:
		_fail(ctx, "expected %s, got null" % str(want))
		return
	var d := absf(float(got) - float(want))
	worst = maxf(worst, d)
	if d >= tol:
		_fail(ctx, "%s vs %s (diff %s)" % [str(got), str(want), str(d)])


func _pose(got: Dictionary, want: Dictionary, ctx: String) -> void:
	var w := Se3.pose_from_out(want)
	for i in 3:
		_num(got["t"][i], w["t"][i], "%s t[%d]" % [ctx, i])
	for i in 9:
		_num(got["r"][i], w["r"][i], "%s r[%d]" % [ctx, i])


func _rows(got: Array, want: Array, ctx: String) -> void:
	checks += 1
	if got.size() != want.size():
		_fail(ctx, "row count %d vs %d" % [got.size(), want.size()])
		return
	for r in want.size():
		for c in (want[r] as Array).size():
			_num(got[r][c], want[r][c], "%s [%d][%d]" % [ctx, r, c])


func _eq(got, want, ctx: String) -> void:
	checks += 1
	if got != want:
		_fail(ctx, "%s vs %s" % [str(got), str(want)])


func _floats(a: Array) -> Array:
	return a.map(func(x): return float(x))


func _conc_pose(theta_deg: float, z: float) -> Dictionary:
	var th := deg_to_rad(theta_deg)
	return Se3.make_pose([-CX * cos(th), -CX * sin(th), z], Se3.rot_from_rotvec([0.0, 0.0, th]))


func _conc_rows(p: Dictionary) -> Array:
	return [[0.0, 0.0, 1.0, 0.0, 0.0, 0.0], [-p["t"][1], p["t"][0], 0.0, 0.0, 0.0, 1.0]]


func _conc_violation(p: Dictionary) -> float:
	var q := Se3.mat_vec(p["r"], [CX, 0.0, 0.0])
	return sqrt(pow(q[0] + p["t"][0], 2) + pow(q[1] + p["t"][1], 2))


func _steps(seq: Array, lever: float) -> float:
	var m := 0.0
	for k in range(1, seq.size()):
		m = maxf(m, Se3.weighted_dist(seq[k], seq[k - 1], lever))
	return m


func _run_sequence(inp: Dictionary, thetas: Array) -> Dictionary:
	var hand: Array = (inp["hand"] as Array).map(func(h): return Se3.pose_from_json(h))
	var lever := float(inp["lever_arm"])
	var every := int(inp["reanchor_every"])
	var screw: Array = []
	var blended: Array = []
	var additive: Array = []
	var blender := Blender.new(1, float(inp["tau_frames"]))
	var model = null
	var anchors: Array = []
	var viol_s := 0.0
	var viol_a := 0.0
	for f in hand.size():
		var w: Dictionary = hand[f]
		if f % every == 0:
			var new_ref := _conc_pose(float(thetas[f / every]), w["t"][2])
			var next = Projector.from_anchor([new_ref], _conc_rows(new_ref), lever)
			if model != null:
				blender.on_anchor(model.project(w), next.project(w))
			model = next
			anchors.append(new_ref)
		var s: Array = model.project(w)
		var a: Array = model.project(w, Projector.Integrator.ADDITIVE)
		screw.append(s[0])
		additive.append(a[0])
		blended.append(blender.shown(s)[0])
		viol_s = maxf(viol_s, _conc_violation(s[0]))
		viol_a = maxf(viol_a, _conc_violation(a[0]))
	var max_anchor := 0.0
	for k in range(1, anchors.size()):
		max_anchor = maxf(max_anchor, Se3.weighted_dist(anchors[k], anchors[k - 1], lever))
	var max_hand_interval := 0.0
	for k in range(every, hand.size()):
		max_hand_interval = maxf(max_hand_interval, Se3.weighted_dist(hand[k], hand[k - every], lever))
	return {
		"screw": screw, "screw_blended": blended, "additive": additive,
		"summary": {
			"max_anchor_step_per_interval": max_anchor,
			"max_hand_step_per_interval": max_hand_interval,
			"max_frame_step_hand": _steps(hand, lever),
			"max_frame_step_screw": _steps(screw, lever),
			"max_frame_step_screw_blended": _steps(blended, lever),
			"max_frame_step_additive": _steps(additive, lever),
			"max_violation_screw_mm": viol_s,
			"max_violation_additive_mm": viol_a,
		},
	}


func _cases_of(doc: Dictionary, kind: String) -> Array:
	return (doc["cases"] as Array).filter(func(c): return c["kind"] == kind)


func _source_check(text: String) -> String:
	## "same" / "DIFFERENT" / "no source" — the copy vs DIDSA-CAD's docs/motion/vectors.json.
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/motion/vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/motion/vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc = JSON.parse_string(text)
	if not (doc is Dictionary):
		print("SMOKE FAILED: couldn't read ", FIXTURE)
		quit(1)
		return
	tol = float(doc["tolerance"])
	var src := _source_check(text)
	print("SMOKE the fixture copy equals DIDSA-CAD's docs/motion/vectors.json (", src, "): ", src == "same" or src == "no source")
	if src.begins_with("DIFFERENT"):
		failures += 1
	print("SMOKE vectors: ", (doc["cases"] as Array).size(), " cases, tolerance ", tol)

	var handled := ["gram_schmidt", "project", "screw_log", "hysteresis", "blend", "blend_anchor", "scheduler", "accept_anchor", "swing_sequence"]
	var kinds := {}
	for c in doc["cases"]:
		kinds[c["kind"]] = true
	var unhandled := kinds.keys().filter(func(k): return not handled.has(k))
	print("SMOKE every kind in the file has a runner here: ", unhandled.is_empty(), " ", unhandled)
	if not unhandled.is_empty():
		failures += 1

	var consts: Dictionary = doc["constants"]
	_eq(Projector.FOLLOWER_WEIGHT, consts["follower_weight"], "const follower_weight")
	_eq(Projector.GS_DROP_RELATIVE, consts["gram_schmidt_drop_relative"], "const gs_drop_relative")
	_eq(Projector.GS_DROP_ABSOLUTE, consts["gram_schmidt_drop_absolute"], "const gs_drop_absolute")
	_eq(Blender.TAU_FRAMES, consts["tau_frames"], "const tau_frames")
	_eq(Scheduler.RESIDUAL_TOL, consts["residual_tol"], "const residual_tol")
	_eq(Scheduler.JUMP_REJECT_FACTOR, consts["jump_reject_factor"], "const jump_reject_factor")
	_eq(Scheduler.REANCHOR_MS, consts["reanchor_ms"], "const reanchor_ms")
	_eq(Scheduler.REANCHOR_MS_NEAR_SINGULAR, consts["reanchor_ms_near_singular"], "const reanchor_ms_near_singular")
	_eq(Scheduler.SIGMA_GAP_LOW, consts["sigma_gap_low"], "const sigma_gap_low")
	_eq(Hysteresis.GAIN_MIN, consts["gain_min"], "const gain_min")
	_eq(Hysteresis.GAIN_FRAMES, int(consts["gain_frames"]), "const gain_frames")
	print("SMOKE GDScript constants equal the vectors' constants: ", failures == 0)

	var per_kind := {}
	var before := failures

	# --- gram_schmidt
	for c in _cases_of(doc, "gram_schmidt"):
		var i: Dictionary = c["input"]
		var s := Projector.member_scale(int(i["members"]), float(i["lever_arm"]), 0, float(i["follower_weight"]))
		var u := Projector.weighted_gram_schmidt(i["rows"], s)
		_eq(u.size(), int(c["expected"]["kept"]), "%s kept" % c["id"])
		_rows(u, c["expected"]["rows"], c["id"])
	per_kind["gram_schmidt"] = failures - before
	before = failures

	# --- project (screw; additive pinned as well — the integrator is part of the port)
	for c in _cases_of(doc, "project"):
		var i: Dictionary = c["input"]
		var refs: Array = (i["refs"] as Array).map(func(r): return Se3.pose_from_json(r))
		var p = Projector.from_anchor(refs, i["basis"], float(i["lever_arm"]), float(i["follower_weight"]))
		var e: Dictionary = c["expected"]
		_eq(p.dim(), int(e["orthonormal_dim"]), "%s dim" % c["id"])
		var wanted := Se3.pose_from_json(i["wanted"])
		var got: Array = p.project(wanted)
		var add: Array = p.project(wanted, Projector.Integrator.ADDITIVE)
		for m in (e["members"] as Array).size():
			_pose(got[m], e["members"][m], "%s member %d" % [c["id"], m])
			_pose(add[m], e["additive_members"][m], "%s additive member %d" % [c["id"], m])
	per_kind["project"] = failures - before
	before = failures

	# --- screw_log: the twist, and screw_exp(base, twist) lands on the target
	for c in _cases_of(doc, "screw_log"):
		var i: Dictionary = c["input"]
		var base := Se3.pose_from_json(i["base"])
		var target := Se3.pose_from_json(i["target"])
		var d := Se3.screw_log(base, target)
		for k in 6:
			_num(d[k], c["expected"]["twist"][k], "%s twist[%d]" % [c["id"], k])
		var back := Se3.screw_exp(base, d)
		_pose(back, c["expected"]["roundtrip"], "%s roundtrip" % c["id"])
		for k in 3:
			checks += 1
			if absf(back["t"][k] - target["t"][k]) >= 1e-8:
				_fail("%s lands on target" % c["id"], "t[%d] %s vs %s" % [k, str(back["t"][k]), str(target["t"][k])])
	per_kind["screw_log"] = failures - before
	before = failures

	# --- hysteresis
	for c in _cases_of(doc, "hysteresis"):
		var i: Dictionary = c["input"]
		var lever := float(i["lever_arm"])
		var h := Hysteresis.new()
		var frames: Array = i["frames"]
		for f in frames.size():
			var fr: Dictionary = frames[f]
			var w: Dictionary = c["expected"]["frames"][f]
			var ctx := "%s frame %d" % [c["id"], f]
			if fr["anchor"] != null:
				var a: Dictionary = fr["anchor"]
				var ev := h.on_anchor(Projector.from_anchor([Se3.pose_from_json(a["ref"])], a["rows"], lever))
				_eq(ev, w["anchor_event"], "%s anchor_event" % ctx)
			else:
				_eq(null, w["anchor_event"], "%s anchor_event" % ctx)
			var out := h.frame(Se3.pose_from_json(fr["wish"]))
			_num(out["gain"], w["gain"], "%s gain" % ctx)
			_eq(out["event"], w["event"], "%s event" % ctx)
			_eq(h.count, int(w["count"]), "%s count" % ctx)
			_eq(h.dim(), int(w["dim"]), "%s dim" % ctx)
			_pose(out["poses"][0], w["projected"], ctx)
	per_kind["hysteresis"] = failures - before
	before = failures

	# --- blend + blend_anchor
	for c in _cases_of(doc, "blend"):
		var i: Dictionary = c["input"]
		var b := Blender.new((i["offsets"] as Array).size(), float(i["tau_frames"]))
		b.offsets = (i["offsets"] as Array).map(func(o): return _floats(o))
		var proj: Array = i["projected"]
		for f in proj.size():
			var got := b.shown((proj[f] as Array).map(func(p): return Se3.pose_from_json(p)))
			for m in got.size():
				_pose(got[m], c["expected"]["shown"][f][m], "%s frame %d member %d" % [c["id"], f, m])
	for c in _cases_of(doc, "blend_anchor"):
		var i: Dictionary = c["input"]
		var b := Blender.new(1, float(i["tau_frames"]))
		var olds: Array = (i["old_projected"] as Array).map(func(p): return Se3.pose_from_json(p))
		var news: Array = (i["new_projected"] as Array).map(func(p): return Se3.pose_from_json(p))
		var af := int(i["anchor_frame"])
		for f in olds.size():
			var shown: Dictionary
			if f < af:
				shown = b.shown([olds[f]])[0]
			else:
				if f == af:
					b.on_anchor([olds[f]], [news[f]])
				shown = b.shown([news[f]])[0]
			_pose(shown, c["expected"]["shown"][f], "%s frame %d" % [c["id"], f])
	per_kind["blend"] = failures - before
	before = failures

	# --- scheduler (pure decision)
	for c in _cases_of(doc, "scheduler"):
		var i: Dictionary = c["input"]
		var d := Scheduler.needs_reanchor(float(i["now_ms"]), float(i["anchor_ms"]), float(i["travel"]), i["max_step"], i["sigma_gap"], bool(i["in_flight"]))
		_eq(d["reanchor"], c["expected"]["reanchor"], "%s reanchor" % c["id"])
		_eq(d["reason"], c["expected"]["reason"], "%s reason" % c["id"])
	per_kind["scheduler"] = failures - before
	before = failures

	# --- accept_anchor
	for c in _cases_of(doc, "accept_anchor"):
		var i: Dictionary = c["input"]
		var own = null if i["own_projection"] == null else Se3.pose_from_json(i["own_projection"])
		var d := Scheduler.accept_anchor(bool(i["converged"]), i["residual_inf"], Se3.pose_from_json(i["grabbed_transform"]), own, float(i["lever_arm"]))
		_eq(d["accept"], c["expected"]["accept"], "%s accept" % c["id"])
		_eq(d["reason"], c["expected"]["reason"], "%s reason" % c["id"])
		_num(d["client_jump"], c["expected"]["client_jump"], "%s client_jump" % c["id"])
	per_kind["accept_anchor"] = failures - before
	before = failures

	# --- swing_sequence (per-frame poses + summary numbers); both anchor series are DATA in the vectors
	for c in _cases_of(doc, "swing_sequence"):
		var i: Dictionary = c["input"]
		var runs := {
			"nearest_anchors": _run_sequence(i, i["nearest_anchor_theta_deg"]),
			"backend_anchors": _run_sequence(i, i["backend_anchor_theta_deg"]),
		}
		for name in runs:
			var want: Dictionary = c["expected"][name]
			for series in ["screw", "screw_blended", "additive"]:
				var g: Array = runs[name][series]
				var w: Array = want[series]
				_eq(g.size(), w.size(), "%s %s length" % [name, series])
				for f in w.size():
					_pose(g[f], w[f], "%s %s frame %d" % [name, series, f])
			for k in (want["summary"] as Dictionary):
				_num(runs[name]["summary"][k], want["summary"][k], "%s summary.%s" % [name, k])
	per_kind["swing_sequence"] = failures - before

	for k in per_kind:
		print("SMOKE golden vectors — ", k, ": ", per_kind[k] == 0, " (", per_kind[k], " mismatches)")
	print("calibration — ", checks, " numeric/equality checks, worst numeric difference ", worst)
	if failures > 0:
		print("SMOKE FAILED: ", failures, " mismatches; first: ", first_failure)
		quit(1)
		return
	print("SMOKE PASSED: every golden vector to ", tol)
	quit()
