extends SceneTree
## Headless, no network: the local nearest-point retraction (scripts/motion/local_retraction.gd, DIDSA-CAD spec §4b) against
## DIDSA-CAD's golden vectors, kind `local_retract` (tests/fixtures/motion_vectors.json, tolerance 1e-9, poses as matrices), plus the
## analytic Jacobian against central differences and the model-parsing rules. The SAME cases gate the Dart port and the backend.
## A raw local answer that is not converged TIGHTLY (residual > 1e-9) is a sensitive function of the linear solve's rounding:
## only `accepted` and the shown poses are pinned there (spec §15).
## Run: "$GODOT" --headless --path . --script res://tests/local_retraction.gd

const Se3 := preload("res://scripts/motion/se3.gd")
const Local := preload("res://scripts/motion/local_retraction.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const FIXTURE := "res://tests/fixtures/motion_vectors.json"

var failures := 0
var checks := 0
var worst := 0.0
var first_failure := ""


func _fail(ctx: String, msg: String) -> void:
	failures += 1
	if first_failure == "":
		first_failure = "%s: %s" % [ctx, msg]


func _num(got: float, want: float, ctx: String, tol: float) -> void:
	checks += 1
	var d := absf(got - want)
	worst = maxf(worst, d)
	if d >= tol:
		_fail(ctx, "%s vs %s (diff %s)" % [str(got), str(want), str(d)])


func _pose(got: Dictionary, want: Dictionary, ctx: String, tol: float) -> void:
	var w := Se3.pose_from_out(want)
	for i in 3:
		_num(got["t"][i], w["t"][i], "%s t[%d]" % [ctx, i], tol)
	for i in 9:
		_num(got["r"][i], w["r"][i], "%s r[%d]" % [ctx, i], tol)


func _poses_in(list: Array) -> Array:
	return list.map(func(p): return Se3.pose_from_json(p))


func _initialize() -> void:
	var doc = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var tol := float(doc["tolerance"])
	var c: Dictionary = doc["constants"]
	var cases: Array = (doc["cases"] as Array).filter(func(x): return x["kind"] == "local_retract")

	_num(Local.LOCAL_FOLLOWER, float(c["local_follower"]), "const local_follower", 0.0 + 1e-300)
	_num(Local.ITERATIONS, float(c["local_iters"]), "const local_iters", 0.5)
	_num(Local.ITERATIONS_MAX, float(c["local_iters_max"]), "const local_iters_max", 0.5)
	_num(Local.POLISH, float(c["local_polish"]), "const local_polish", 0.5)
	_num(Local.TRUST, float(c["local_trust"]), "const local_trust", 1e-300)
	_num(Local.ROTATION_CAP, float(c["local_rot_cap"]), "const local_rot_cap", 1e-300)
	_num(Local.LAMBDA_ABS, float(c["local_lam_abs"]), "const local_lam_abs", 1e-300)
	_num(Local.ACCEPT_RESIDUAL, float(c["local_accept_residual"]), "const local_accept_residual", 1e-300)
	_num(Local.ACCEPT_DISTANCE, float(c["local_accept_distance"]), "const local_accept_distance", 1e-300)
	_num(Local.PAIR_MODEL_VERSION, float(c["local_pair_model_version"]), "const local_pair_model_version", 0.5)
	_num(Local.MODEL_VERSION, float(c["local_model_version"]), "const local_model_version", 0.5)
	if c.has("local_coupler_model_version"):
		_num(Local.COUPLER_MODEL_VERSION, float(c["local_coupler_model_version"]), "const local_coupler_model_version", 0.5)
	print("SMOKE GDScript local-retraction constants equal the vectors' constants: ", failures == 0)
	var width_cases := cases.filter(func(x): return str(x["id"]).begins_with("local-width-"))
	print("SMOKE local_retract cases in the fixture: ", cases.size(), " (>= 12: ", cases.size() >= 12, "); local-width-*: ", width_cases.size(), " (>= 17: ", width_cases.size() >= 17, ")")
	if cases.size() < 12 or width_cases.size() < 17:
		failures += 1

	var per_case_ok := 0
	for cs in cases:
		var before := failures
		var inp: Dictionary = cs["input"]
		var exp: Dictionary = cs["expected"]
		var id: String = cs["id"]
		var model = Local.try_parse(inp["model"], 8) # the GDScript production limit is 3; the vectors include 5 and 8 members
		if model == null:
			_fail(id, "model did not parse")
			continue
		var poses := _poses_in(inp["poses"])
		var wishes := _poses_in(inp["wishes"])
		var fallback := _poses_in(inp["fallback_poses"])
		var r: Dictionary = model.frame(poses, wishes, fallback, float(inp["lever_arm"]))
		if bool(r["accepted"]) != bool(exp["accepted"]):
			_fail(id, "accepted %s vs %s" % [str(r["accepted"]), str(exp["accepted"])])
		for i in poses.size():
			if float(exp["residual_inf"]) <= 1e-9:
				_pose(r["local_poses"][i], exp["local_poses"][i], "%s local[%d]" % [id, i], tol)
			_pose(r["poses"][i], exp["poses"][i], "%s shown[%d]" % [id, i], tol)
		if float(exp["residual_inf"]) <= 1e-9:
			_num(r["residual_inf"], float(exp["residual_inf"]), id + " residual", tol)
			_num(r["fallback_distance"], float(exp["fallback_distance"]), id + " distance", tol)
		elif float(exp["residual_inf"]) > Local.ACCEPT_RESIDUAL and r["residual_inf"] <= Local.ACCEPT_RESIDUAL:
			_fail(id, "expected to stay non-converged")
		if failures == before:
			per_case_ok += 1
	print("SMOKE golden local_retract cases: ", per_case_ok, "/", cases.size(), " ", per_case_ok == cases.size())

	# analytic Jacobian = central differences (at the start and at the answer) on every case
	var jac_bad := 0
	var jac_worst := 0.0
	for cs in cases:
		var inp: Dictionary = cs["input"]
		var model = Local.try_parse(inp["model"], 8)
		var start := _poses_in(inp["poses"])
		var w := Local.local_scale(model.members, float(inp["lever_arm"]))
		var answer: Array = model.retract(start, _poses_in(inp["wishes"]), w)
		for poses in [start, answer]:
			var jac: Array = model.jacobian(poses)
			for col in model.n:
				var h := 1e-6
				var e := PackedFloat64Array()
				e.resize(model.n)
				e[col] = h
				var plus: Array = model._step(poses, e)
				e[col] = -h
				var minus: Array = model._step(poses, e)
				var rp: PackedFloat64Array = model.residual(plus)
				var rm: PackedFloat64Array = model.residual(minus)
				for row in rp.size():
					var fd := (rp[row] - rm[row]) / (2.0 * h)
					var d := absf(jac[row][col] - fd)
					jac_worst = maxf(jac_worst, d / (1.0 + absf(fd)))
					if d > 1e-6 * (1.0 + absf(fd)):
						jac_bad += 1
	print("SMOKE analytic Jacobian = central differences on every case: ", jac_bad == 0, " (worst relative ", jac_worst, ")")
	if jac_bad > 0:
		failures += 1

	# model parsing: null / another version / unknown type / missing field / out-of-range member / too many members
	var base: Dictionary = (cases[0]["input"]["model"] as Dictionary).duplicate(true)
	var ok_parse := Local.try_parse(base) != null
	var bad_version: Dictionary = base.duplicate(true)
	bad_version["version"] = Local.COUPLER_MODEL_VERSION + 1
	var old_version: Dictionary = base.duplicate(true)
	old_version["version"] = 1 # the pre-branch model (sign-agnostic residuals) is not evaluated
	var bad_type: Dictionary = base.duplicate(true)
	bad_type["mates"][0]["type"] = "weld"
	var missing: Dictionary = base.duplicate(true)
	missing["mates"][0]["a"].erase("axis_origin")
	var bad_member: Dictionary = base.duplicate(true)
	bad_member["mates"][0]["a"]["member"] = 5
	var parse_rules: bool = ok_parse and Local.try_parse(null) == null and Local.try_parse(bad_version) == null and Local.try_parse(old_version) == null and Local.try_parse(bad_type) == null \
		and Local.try_parse(missing) == null and Local.try_parse(bad_member) == null and Local.try_parse(base, 0) == null
	print("SMOKE model parsing rules (valid parses; null/version/type/missing field/member/too many -> null): ", parse_rules)
	if not parse_rules:
		failures += 1

	# version 4 (a side with a `pair`) -- mirrors client/test/local_retraction_test.dart
	var pair_base: Dictionary = (cases.filter(func(x): return x["id"] == "local-width-free-bars-slide-bar")[0]["input"]["model"] as Dictionary).duplicate(true)
	var pm = Local.try_parse(pair_base)
	var pair_side := _pair_side(pair_base)
	var v3_pair: Dictionary = pair_base.duplicate(true)
	v3_pair["version"] = Local.MODEL_VERSION
	var no_plane: Dictionary = pair_base.duplicate(true)
	_pair_side(no_plane)["pair"].erase("plane")
	var bad_pair_member: Dictionary = pair_base.duplicate(true)
	_pair_side(bad_pair_member)["pair"]["member"] = 9
	var v4_plain: Dictionary = base.duplicate(true)
	v4_plain["version"] = Local.PAIR_MODEL_VERSION
	var pair_ok: bool = pm != null and pm.rows == 1 + 3 + 3 and not pair_side.is_empty() \
		and Local.try_parse(v3_pair) == null and Local.try_parse(no_plane) == null and Local.try_parse(bad_pair_member) == null \
		and Local.try_parse(v4_plain) != null
	print("SMOKE version 4 parsing (pair parses with 7 rows; v3+pair, missing plane, bad pair member -> null; v4 without a pair is ordinary): ", pair_ok)
	if not pair_ok:
		failures += 1
	var versions_ok := true
	for cs in cases:
		var mdl: Dictionary = cs["input"]["model"]
		var has_pair := false
		for m in mdl["mates"]:
			if m["a"].has("pair") or m["b"].has("pair"):
				has_pair = true
		var has_coupler := false
		for m in mdl["mates"]:
			if ["gear", "rack_pinion", "screw"].has(m["type"]):
				has_coupler = true
		if int(mdl["version"]) != (5 if has_coupler else (4 if has_pair else 3)):
			versions_ok = false
	print("SMOKE every golden model is version 5 with a coupler, else 4 exactly when a side has a pair: ", versions_ok)
	if not versions_ok:
		failures += 1

	_pair_cost(cases)

	# the production limit: the 5- and 8-member vector models are refused at MAX_MEMBERS (stay on the projector)
	var big = (cases.filter(func(x): return str(x["id"]).begins_with("local-row8"))[0]["input"]["model"])
	var limit_ok: bool = Local.try_parse(big) == null and Local.try_parse(big, 8) != null
	print("SMOKE 8-member model refused at the GDScript limit (", Local.MAX_MEMBERS, "), parsed with an explicit limit of 8: ", limit_ok)
	if not limit_ok:
		failures += 1

	if failures > 0:
		print("SMOKE FAILED: ", failures, " mismatches; first: ", first_failure)
		quit(1)
		return
	print("SMOKE PASSED: every local_retract vector to ", tol, " (", checks, " checks, worst diff ", worst, ")")
	quit(0)


func _pair_side(model: Dictionary) -> Dictionary:
	var m: Dictionary = model["mates"][0]
	return m["a"] if m["a"].has("pair") else m["b"]


## Per-frame cost, a pair scene against its plain twin (same members, the pair removed, version 3). Prints; asserts only a loose
## ceiling so a slow CI box does not flake. Headless on whatever machine runs it: a ratio, not a headset number.
func _pair_cost(cases: Array) -> void:
	for id in ["local-width-free-bars-slide-bar", "local-width-4part-anti-aligned-slide-bar"]:
		var inp: Dictionary = cases.filter(func(x): return x["id"] == id)[0]["input"]
		var spec: Dictionary = inp["model"]
		var plain: Dictionary = spec.duplicate(true)
		plain["version"] = Local.MODEL_VERSION
		for m in plain["mates"]:
			m["a"].erase("pair")
			m["b"].erase("pair")
		var poses := _poses_in(inp["poses"])
		var wishes := _poses_in(inp["wishes"])
		var lever := float(inp["lever_arm"])
		var us := {}
		var rows := {}
		for key in ["plain", "pair"]:
			var model = Local.try_parse(plain if key == "plain" else spec, 8)
			rows[key] = model.rows
			for _i in 5:
				model.frame(poses, wishes, poses, lever)
			var t0 := Time.get_ticks_usec()
			var reps := 100
			for _i in reps:
				model.frame(poses, wishes, poses, lever)
			us[key] = float(Time.get_ticks_usec() - t0) / reps
		print("SMOKE BENCH pair vs plain twin ", id, ": plain ", rows["plain"], " rows ", snappedf(us["plain"], 0.1), " us/frame, pair ", rows["pair"], " rows ", snappedf(us["pair"], 0.1), " us/frame (", snappedf(us["pair"] / us["plain"], 0.01), "x)")
		var cost_ok: bool = us["pair"] < 200000.0
		print("SMOKE pair frame under 200 ms (loose ceiling): ", cost_ok)
		if not cost_ok:
			failures += 1
