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


func follow_cases_limit(cases: Array) -> Dictionary:
	return cases.filter(func(x): return x["id"] == "local-follow-limit-stops-at-min")[0]["input"]


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
	if c.has("local_follow_model_version"):
		_num(Local.FOLLOW_MODEL_VERSION, float(c["local_follow_model_version"]), "const local_follow_model_version", 0.5)
	if c.has("local_rigid_model_version"):
		_num(Local.RIGID_MODEL_VERSION, float(c["local_rigid_model_version"]), "const local_rigid_model_version", 0.5)
	if c.has("local_limit_model_version"):
		_num(Local.LIMIT_MODEL_VERSION, float(c["local_limit_model_version"]), "const local_limit_model_version", 0.5)
		_num(Local.LIMIT_ROUNDS, float(c["local_limit_rounds"]), "const local_limit_rounds", 0.5)
		_num(Local.LIMIT_TOL, float(c["local_limit_tol"]), "const local_limit_tol", 1e-300)
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
		# version 8: every follower with its lead at the shown / the raw local answer (the same pins as the leads')
		if exp.has("followers"):
			if not model.has_sets():
				_fail(id, "a model with rigid_sets reports has_sets()")
			var want_ids: Array = (exp["followers"] as Dictionary).keys()
			want_ids.sort()
			var got_ids: Array = (r["followers"] as Dictionary).keys()
			got_ids.sort()
			var model_ids: Array = model.follower_ids()
			model_ids.sort()
			if got_ids != want_ids or model_ids != want_ids:
				_fail(id, "follower ids %s / %s vs %s" % [str(got_ids), str(model_ids), str(want_ids)])
			else:
				for fid in want_ids:
					_pose(r["followers"][fid], exp["followers"][fid], "%s follower %s shown" % [id, fid], tol)
					if float(exp["residual_inf"]) <= 1e-9:
						_pose(r["local_followers"][fid], exp["local_followers"][fid], "%s follower %s local" % [id, fid], tol)
		elif model.has_sets() or r.has("followers"):
			_fail(id, "no rigid sets expected")
		if exp.has("held_limits"):
			var held: Array = model.held_limits().keys()
			held.sort()
			if held != exp["held_limits"]:
				_fail(id, "held limits %s vs %s" % [str(held), str(exp["held_limits"])])
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
	var base_rows: int = Local.try_parse(base).rows
	# a row cap below the model's own count refuses it; a larger one (the limit read of a big group) takes it
	print("SMOKE try_parse honours its row cap: ", Local.try_parse(base, 8, base_rows - 1) == null and Local.try_parse(base, 8, base_rows) != null, " rows ", base_rows)
	var bad_version: Dictionary = base.duplicate(true)
	bad_version["version"] = Local.RIGID_MODEL_VERSION + 1 # (was FOLLOW_MODEL_VERSION + 1 before version 8 existed)
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
		var has_limit := false
		for m in mdl["mates"]:
			if ["limit_distance", "limit_angle"].has(m["type"]):
				has_limit = true
		var has_follow := false
		for m in mdl["mates"]:
			if m["a"].has("follow") or m["b"].has("follow"):
				has_follow = true
		if int(mdl["version"]) != (8 if mdl.has("rigid_sets") else 7 if has_follow else (6 if has_limit else (5 if has_coupler else (4 if has_pair else 3)))):
			versions_ok = false
	print("SMOKE every golden model is version 8 with rigid sets, 7 with a follower side, 6 with a limit, 5 with a coupler, else 4 exactly when a side has a pair: ", versions_ok)
	if not versions_ok:
		failures += 1

	_limit_rules(cases)
	_rigid_rules(cases)
	_reduced_models()
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


## Version 6 (limit mates) - mirrors client/test/local_retraction_test.dart: parsing rules, and the held set rebuilt every frame (stopped at the minimum, then
## released the next frame the hand pulls back).
func _limit_rules(cases: Array) -> void:
	var slider: Dictionary = cases.filter(func(x): return x["id"] == "local-limit-distance-stops-at-min")[0]["input"]
	var base: Dictionary = (slider["model"] as Dictionary).duplicate(true)
	var limit_mate := func(model: Dictionary) -> Dictionary:
		for m in model["mates"]:
			if str(m["type"]).begins_with("limit_"):
				return m
		return {}
	var v5: Dictionary = base.duplicate(true)
	v5["version"] = Local.COUPLER_MODEL_VERSION
	var no_id: Dictionary = base.duplicate(true)
	limit_mate.call(no_id).erase("id")
	var no_range: Dictionary = base.duplicate(true)
	limit_mate.call(no_range)["min"] = null
	limit_mate.call(no_range)["max"] = null
	var no_plane: Dictionary = base.duplicate(true)
	for side in ["a", "b"]:
		limit_mate.call(no_plane)[side].erase("plane")
	var angle: Dictionary = (cases.filter(func(x): return x["id"] == "local-limit-angle-inside")[0]["input"]["model"] as Dictionary).duplicate(true)
	var no_hinge: Dictionary = angle.duplicate(true)
	limit_mate.call(no_hinge)["b"].erase("hinge_direction")
	var rules_ok: bool = Local.try_parse(base) != null and Local.try_parse(angle) != null and Local.try_parse(v5) == null and Local.try_parse(no_id) == null \
		and Local.try_parse(no_range) == null and Local.try_parse(no_plane) == null and Local.try_parse(no_hinge) == null
	print("SMOKE limit model parsing (v6 parses; as v5, no id, no range, no plane, no hinge -> null): ", rules_ok)
	if not rules_ok:
		failures += 1
	var model = Local.try_parse(base)
	var lever := float(slider["lever_arm"])
	var start := _poses_in(slider["poses"])
	var w := Local.local_scale(1, lever)
	var far := Se3.make_pose([start[0]["t"][0] + 40.0, start[0]["t"][1], start[0]["t"][2]], start[0]["r"])
	var stopped: Array = model.retract(start, [far], w)
	var held_a: Array = model.held_limits().keys()
	var back := Se3.make_pose([stopped[0]["t"][0] - 4.0, stopped[0]["t"][1], stopped[0]["t"][2]], stopped[0]["r"])
	var freed: Array = model.retract(stopped, [back], w)
	var held_b: Array = model.held_limits().keys()
	var held_ok: bool = held_a == ["gap"] and absf(float(stopped[0]["t"][0]) - (float(start[0]["t"][0]) + 15.0)) < 1e-5 and held_b.is_empty() \
		and absf(float(freed[0]["t"][0]) - (float(stopped[0]["t"][0]) - 4.0)) < 1e-5
	print("SMOKE limit held at the stop, released the next frame the hand pulls back: ", held_ok)
	if not held_ok:
		failures += 1

	# version 7 (follower sides: a pattern copy that follows its source) -- mirrors client/test/local_retraction_test.dart. Without it a version-7 model
	# would make try_parse return null and switch off the limit stops of any group that holds a copy mate.
	var follow_ids := ["local-follow-linear-slide-and-spin", "local-follow-circular-orient-slide-and-spin", "local-follow-circular-keep-rotation-slide-and-spin", "local-follow-limit-stops-at-min"]
	var v7_parse := true
	for fid in follow_ids:
		var fm: Dictionary = (cases.filter(func(x): return x["id"] == fid)[0]["input"]["model"] as Dictionary).duplicate(true)
		v7_parse = v7_parse and int(fm["version"]) == 7 and Local.try_parse(fm) != null
		for older in [Local.MODEL_VERSION, Local.PAIR_MODEL_VERSION, Local.COUPLER_MODEL_VERSION, Local.LIMIT_MODEL_VERSION]:
			var old: Dictionary = fm.duplicate(true)
			old["version"] = older
			v7_parse = v7_parse and Local.try_parse(old) == null # `follow` belongs to version 7 only
	var no_step: Dictionary = (cases.filter(func(x): return x["id"] == follow_ids[0])[0]["input"]["model"] as Dictionary).duplicate(true)
	no_step["mates"][0]["a"]["follow"] = {"keep_rotation": false}
	v7_parse = v7_parse and Local.try_parse(no_step) == null
	print("SMOKE version 7 parsing (follower models parse, also with a limit; follow in v3-6 or without its step -> null): ", v7_parse)
	if not v7_parse:
		failures += 1
	var f_inp: Dictionary = follow_cases_limit(cases)
	var f_model = Local.try_parse(f_inp["model"])
	var f_ok := false
	if f_model != null:
		f_model.retract(_poses_in(f_inp["poses"]), _poses_in(f_inp["wishes"]), Local.local_scale(2, float(f_inp["lever_arm"])), Local.ITERATIONS_MAX)
		f_ok = f_model.held_limits().keys() == ["gap"]
	print("SMOKE a version-7 model that holds a follower still holds its limit stop: ", f_ok)
	if not f_ok:
		failures += 1


## Version 8 (rigid sets) -- mirrors client/test/local_retraction_test.dart "version 8 (rigid sets)": the local-rigid-* models parse (and move their leads only),
## `rigid_sets` outside version 8 is malformed, so are a lead out of range or listed twice, a follower that is a lead or a duplicate, a bad offset; a version-8
## model without sets is ordinary and a lead without followers keeps the diagonal metric bit for bit; a set weighs what its members would.
func _rigid_rules(cases: Array) -> void:
	var ids := ["local-rigid-bolt-turn-3deg-x", "local-rigid-bolt-slide-and-spin", "local-rigid-grab-the-set-turn-5deg-y", "local-rigid-set-on-fixed-bolt-turn-20deg"]
	var model_of := func(id: String) -> Dictionary:
		return (cases.filter(func(x): return x["id"] == id)[0]["input"]["model"] as Dictionary).duplicate(true)
	var parse_ok := true
	for id in ids:
		var spec: Dictionary = model_of.call(id)
		var m = Local.try_parse(spec)
		parse_ok = parse_ok and int(spec["version"]) == Local.RIGID_MODEL_VERSION and m != null and m.has_sets() and m.members == (spec["members"] as Array).size() and m.follower_ids() == ["rib", "cover"]
	print("SMOKE version 8 parsing (local-rigid models parse as version 8, leads only; followers are follower_ids): ", parse_ok)
	if not parse_ok:
		failures += 1

	var first: String = ids[0]
	var no_sets: Dictionary = (cases[0]["input"]["model"] as Dictionary).duplicate(true)
	no_sets["version"] = Local.RIGID_MODEL_VERSION
	var plain_ok: bool = Local.try_parse(no_sets) != null and not Local.try_parse(no_sets).has_sets()
	no_sets["rigid_sets"] = []
	plain_ok = plain_ok and Local.try_parse(no_sets) != null and not Local.try_parse(no_sets).has_sets()
	print("SMOKE a version-8 model without rigid_sets (or with an empty list) is an ordinary model: ", plain_ok)
	if not plain_ok:
		failures += 1

	# rigid_sets outside version 8, whatever the version -- also a version-7 model (a followed pattern copy) that gains one
	var outside := true
	for v in [Local.MODEL_VERSION, Local.PAIR_MODEL_VERSION, Local.COUPLER_MODEL_VERSION, Local.LIMIT_MODEL_VERSION, Local.FOLLOW_MODEL_VERSION]:
		var spec: Dictionary = model_of.call(first)
		spec["version"] = v
		outside = outside and Local.try_parse(spec) == null
	var v7: Dictionary = model_of.call("local-follow-linear-slide-and-spin")
	outside = outside and Local.try_parse(v7) != null
	v7["rigid_sets"] = model_of.call(first)["rigid_sets"]
	outside = outside and Local.try_parse(v7) == null
	print("SMOKE rigid_sets in a model of version 3 to 7 (including a v7 that follows a copy) -> null: ", outside)
	if not outside:
		failures += 1

	var malformed := true
	for bad_lead in [-1, 2, 7]:
		var spec: Dictionary = model_of.call(first)
		spec["rigid_sets"][0]["member"] = bad_lead
		malformed = malformed and Local.try_parse(spec) == null
	var twice: Dictionary = model_of.call(first)
	twice["rigid_sets"].append((twice["rigid_sets"][0] as Dictionary).duplicate(true))
	malformed = malformed and Local.try_parse(twice) == null
	var is_lead: Dictionary = model_of.call(first)
	is_lead["rigid_sets"][0]["followers"][0]["id"] = is_lead["members"][0]
	malformed = malformed and Local.try_parse(is_lead) == null
	var dup: Dictionary = model_of.call(first)
	dup["rigid_sets"][0]["followers"][1]["id"] = "rib"
	malformed = malformed and Local.try_parse(dup) == null
	var no_id: Dictionary = model_of.call(first)
	(no_id["rigid_sets"][0]["followers"][0] as Dictionary).erase("id")
	malformed = malformed and Local.try_parse(no_id) == null
	var bad_t: Dictionary = model_of.call(first)
	bad_t["rigid_sets"][0]["followers"][0]["t"] = [1.0, 2.0]
	malformed = malformed and Local.try_parse(bad_t) == null
	var bad_r: Dictionary = model_of.call(first)
	bad_r["rigid_sets"][0]["followers"][0]["r"] = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
	malformed = malformed and Local.try_parse(bad_r) == null
	var empty: Dictionary = model_of.call(first)
	empty["rigid_sets"][0]["followers"] = []
	malformed = malformed and Local.try_parse(empty) == null
	var no_list: Dictionary = model_of.call(first)
	(no_list["rigid_sets"][0] as Dictionary).erase("followers")
	malformed = malformed and Local.try_parse(no_list) == null
	var bad_side: Dictionary = model_of.call(first)
	bad_side["mates"][0]["a"]["member"] = 2
	malformed = malformed and Local.try_parse(bad_side) == null
	# the member cap counts leads, not followers
	malformed = malformed and Local.try_parse(model_of.call(first), 2) != null and Local.try_parse(model_of.call(first), 1) == null
	print("SMOKE malformed rigid sets -> null (lead out of range / twice, follower = lead / duplicate / no id, bad offset, empty set, bad mate side; the cap counts leads): ", malformed)
	if not malformed:
		failures += 1

	# a lead without followers keeps the diagonal path bit for bit: a version-8 twin of a version-3 model answers identically
	var inp: Dictionary = cases.filter(func(x): return x["id"] == "local-floating-bolt-slide-and-spin")[0]["input"]
	var twin_spec: Dictionary = (inp["model"] as Dictionary).duplicate(true)
	twin_spec["version"] = Local.RIGID_MODEL_VERSION
	var plain = Local.try_parse(inp["model"], 8)
	var twin = Local.try_parse(twin_spec, 8)
	var p0 := _poses_in(inp["poses"])
	var w0 := _poses_in(inp["wishes"])
	var lever := float(inp["lever_arm"])
	var a: Array = plain.retract(p0, w0, Local.local_scale(plain.members, lever))
	var b: Array = twin.retract(p0, w0, Local.local_scale(twin.members, lever))
	var same := true
	for i in a.size():
		same = same and a[i]["t"] == b[i]["t"] and a[i]["r"] == b[i]["r"]
	print("SMOKE a lead without followers keeps the diagonal metric bit for bit (v8 twin of a v3 model): ", same)
	if not same:
		failures += 1

	# the set weighs what its members would: the bare lead all but reaches the wish, the set (followers wishing to stay) stops short of it
	var g_inp: Dictionary = cases.filter(func(x): return x["id"] == "local-rigid-grab-the-set-turn-5deg-y")[0]["input"]
	var bare_spec: Dictionary = (g_inp["model"] as Dictionary).duplicate(true)
	bare_spec.erase("rigid_sets")
	bare_spec["version"] = Local.FOLLOW_MODEL_VERSION
	var gp := _poses_in(g_inp["poses"])
	var gw := _poses_in(g_inp["wishes"])
	var glever := float(g_inp["lever_arm"])
	var with_set = Local.try_parse(g_inp["model"], 8)
	var bare = Local.try_parse(bare_spec, 8)
	var got_set: Array = with_set.retract(gp, gw, Local.local_scale(2, glever))
	var got_bare: Array = bare.retract(gp, gw, Local.local_scale(2, glever))
	var goal := Se3.norm3(Se3.rotvec_from_rot(gw[0]["r"]))
	var turn_set := Se3.norm3(Se3.rotvec_from_rot(got_set[0]["r"]))
	var turn_bare := Se3.norm3(Se3.rotvec_from_rot(got_bare[0]["r"]))
	var weigh_ok: bool = absf(turn_bare - goal) < 5e-4 and turn_set < turn_bare - 1e-5 and turn_set > 0.0
	# ... and the followers stay rigid with their lead whatever it did
	var rigid_ok := true
	var followers: Dictionary = with_set.expand_followers(got_set)
	for f in (g_inp["model"]["rigid_sets"][0]["followers"] as Array):
		var rel := Se3.mat_mul(Se3.mat_transpose(got_set[0]["r"]), followers[f["id"]]["r"])
		var want_r: Array = []
		for row in f["r"]:
			want_r.append_array(row)
		for i in 9:
			rigid_ok = rigid_ok and absf(rel[i] - float(want_r[i])) < 1e-12
		var d := [followers[f["id"]]["t"][0] - got_set[0]["t"][0], followers[f["id"]]["t"][1] - got_set[0]["t"][1], followers[f["id"]]["t"][2] - got_set[0]["t"][2]]
		var local := Se3.mat_vec(Se3.mat_transpose(got_set[0]["r"]), d)
		for i in 3:
			rigid_ok = rigid_ok and absf(local[i] - float(f["t"][i])) < 1e-9
	print("SMOKE a set weighs what its members would (the set stops short of the wish, the bare lead does not): ", weigh_ok, "; followers stay rigid with the lead: ", rigid_ok)
	if not (weigh_ok and rigid_ok):
		failures += 1


## M2: the 22 reduced models (constraint model version 8) of DIDSA-CAD's M0 scaling scenes, `tests/fixtures/m0_reduced_models.json` (a copy of DIDSA-CAD's
## `client/test/data/m0_reduced_models.json`, written by `backend/tests/export_m0_reduced_models.py`): every one parses with the caps lifted, the ones up to 8 leads
## and 80 rows converge in one frame and keep their followers rigid, and the count inside the GDScript production limit (3 members, 64 rows) is what the sizes say.
## (Timing is tests/bench_local_retraction.gd, never a gate.)
func _reduced_models() -> void:
	var all = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/m0_reduced_models.json"))
	var parse_ok: bool = all is Array and (all as Array).size() == 22
	var inside_limit := 0
	var converged := true
	var rigid := true
	var frames := 0
	for e in all:
		var lead_ids: Array = e["model"]["members"]
		var model = Local.try_parse(e["model"], 64, 1024)
		parse_ok = parse_ok and model != null and int(e["model"]["version"]) == Local.RIGID_MODEL_VERSION
		if model == null:
			continue
		if Local.try_parse(e["model"]) != null:
			inside_limit += 1
		if model.members > 8 or model.rows > 80:
			continue # (a frame of the 19-lead bolted chain takes seconds in GDScript)
		var poses := _poses_in(e["poses"])
		var r: Dictionary = model.frame(poses, _poses_in(e["wishes"]), poses, float(e["lever_arm"]))
		frames += 1
		converged = converged and float(r["residual_inf"]) < 1e-6 and lead_ids.size() == model.members
		var followers: Dictionary = model.expand_followers(r["local_poses"])
		for lead in model.members:
			for f in model._followers[lead]:
				var rel := Se3.mat_mul(Se3.mat_transpose(r["local_poses"][lead]["r"]), followers[f["id"]]["r"])
				for i in 9:
					rigid = rigid and absf(rel[i] - float(f["r"][i]) ) < 1e-12
	# chain / frame variants are one lead (16 of the 22); the linkage's fixed variant is 3 leads and 40 rows (inside); its floating variant has 4, the bolted chains 7 to 19
	var count_ok := inside_limit == 17
	print("SMOKE the 22 reduced models parse (caps lifted), converge in one frame (", frames, " of them run) and keep their followers rigid; ", inside_limit, " of 22 are inside 3 members / 64 rows: ", parse_ok and converged and rigid and count_ok)
	if not (parse_ok and converged and rigid and count_ok):
		failures += 1


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
		# (reported, never a gate: a wall-clock ceiling fails on a slow runner and says nothing about the code; see tests/README.md "Timing")
