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
	print("SMOKE GDScript local-retraction constants equal the vectors' constants: ", failures == 0)
	print("SMOKE local_retract cases in the fixture: ", cases.size(), " (>= 12: ", cases.size() >= 12, ")")
	if cases.size() < 12:
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
	bad_version["version"] = 2
	var bad_type: Dictionary = base.duplicate(true)
	bad_type["mates"][0]["type"] = "gear"
	var missing: Dictionary = base.duplicate(true)
	missing["mates"][0]["a"].erase("axis_origin")
	var bad_member: Dictionary = base.duplicate(true)
	bad_member["mates"][0]["a"]["member"] = 5
	var parse_rules: bool = ok_parse and Local.try_parse(null) == null and Local.try_parse(bad_version) == null and Local.try_parse(bad_type) == null \
		and Local.try_parse(missing) == null and Local.try_parse(bad_member) == null and Local.try_parse(base, 0) == null
	print("SMOKE model parsing rules (valid parses; null/version/type/missing field/member/too many -> null): ", parse_rules)
	if not parse_rules:
		failures += 1

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
