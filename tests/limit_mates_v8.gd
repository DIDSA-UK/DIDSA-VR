extends SceneTree
## The VR limit stop on a version-8 model (DIDSA-CAD constraint model with rigid sets), headless, no backend. Since M1 a group that holds BOTH a limit mate and a
## rigid set gets a version-8 model, which `local_retraction.gd`'s `try_parse` returned null for before M2, so `MatesTool._adopt_limit_model` kept no model and
## the stop was off for that group. Now: the model parses (its members are the sets' LEADS), `_adopt_limit_model` keeps it, and `_limit_stop` maps the leads onto the
## drag's members (leads and followers), scales every member's displacement back together (a follower rides rigidly with its lead) and stops exactly at the bound.
## Run: "$GODOT" --headless --path . --script res://tests/limit_mates_v8.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const Se3 := preload("res://scripts/motion/se3.gd")
const Local := preload("res://scripts/motion/local_retraction.gd")
const FIXTURE := "res://tests/fixtures/motion_vectors.json"

const OFFSET_T := [50.0, 0.0, 0.0] ## the follower sits 50 mm along the lead's x


func _v8_model(base: Dictionary) -> Dictionary:
	## The vector's one-member slider model with a `cover` bolted to it, as version 8.
	var m: Dictionary = base.duplicate(true)
	m["version"] = Local.RIGID_MODEL_VERSION
	m["rigid_sets"] = [{"member": 0, "followers": [{"id": "cover", "r": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], "t": OFFSET_T.duplicate()}]}]
	return m


static func _cover_of(lead: Dictionary) -> Dictionary:
	return Se3.make_pose([lead["t"][0] + OFFSET_T[0], lead["t"][1] + OFFSET_T[1], lead["t"][2] + OFFSET_T[2]], lead["r"])


func _initialize() -> void:
	var doc = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var by_id := {}
	for c in doc["cases"]:
		by_id[c["id"]] = c
	var inp: Dictionary = by_id["local-limit-distance-stops-at-min"]["input"]
	var v7: Dictionary = inp["model"]
	var v8 := _v8_model(v7)
	var refs0: Array = (inp["poses"] as Array).map(func(p): return Se3.pose_from_json(p))
	var lead_id: String = v7["members"][0]
	var members := [lead_id, "cover"]
	var refs := [refs0[0], _cover_of(refs0[0])]

	# before M2 this was null: the version-8 model parsed to nothing, so the limit stop was off for a group with a limit and a set
	var model = Local.try_parse(v8, 8, 1024)
	print("SMOKE a version-8 model that holds a limit AND a rigid set parses (before M2: null): ", model != null and model.has_limits() and model.has_sets() and model.member_ids == [lead_id] and model.follower_ids() == ["cover"])
	print("SMOKE ...while rigid_sets in a version-7 model stays malformed (null): ", Local.try_parse(_with_version(v8, Local.FOLLOW_MODEL_VERSION), 8, 1024) == null)

	# _adopt_limit_model keeps it (the anchor's constraint_model)
	var drag := MatesTool.new()
	var state := {"limits": null, "members": members, "hyst": {"active": {"refs": refs}}, "at_limit": false}
	drag._adopt_limit_model(state, v8)
	print("SMOKE _adopt_limit_model keeps a version-8 model that holds a limit: ", state["limits"] != null)
	var no_limit: Dictionary = _v8_model(by_id["local-floating-bolt-slide-and-spin"]["input"]["model"])
	var other_state := {"limits": null, "members": members, "hyst": {"active": {"refs": refs}}, "at_limit": false}
	drag._adopt_limit_model(other_state, no_limit)
	print("SMOKE ...and drops one that holds no limit (nothing to stop): ", other_state["limits"] == null)

	# a projection 8 mm along (gap 12, inside [5, 30]): untouched, followers included
	var inside: Array = _carried(refs, 8.0)
	var shown: Array = drag._limit_stop(state, inside, true)
	print("SMOKE a projection inside the range is left alone: ", absf(shown[0]["t"][0] - inside[0]["t"][0]) < 1e-12 and absf(shown[1]["t"][0] - inside[1]["t"][0]) < 1e-12 and not state["at_limit"])

	# 40 mm along (gap -20): the lead stops exactly at the bound (15 mm along, gap 5) and the follower rides along 15 mm, rigid with it; flagged
	var far: Array = _carried(refs, 40.0)
	shown = drag._limit_stop(state, far, true)
	var lead_moved: float = shown[0]["t"][0] - refs[0]["t"][0]
	var follower_moved: float = shown[1]["t"][0] - refs[1]["t"][0]
	print("SMOKE past the stop the lead stops exactly at the bound (15 mm along, gap 5) and the follower rides along with it, flagged: ", absf(lead_moved - 15.0) < 1e-4 and absf(follower_moved - lead_moved) < 1e-9 and state["at_limit"], " ", lead_moved, " ", follower_moved)
	var rigid := Se3.mat_vec(shown[0]["r"], OFFSET_T)
	print("SMOKE ...the follower stays exactly its lead times the offset: ", absf(shown[1]["t"][0] - (shown[0]["t"][0] + rigid[0])) < 1e-9 and absf(shown[1]["t"][1] - (shown[0]["t"][1] + rigid[1])) < 1e-9 and absf(shown[1]["t"][2] - (shown[0]["t"][2] + rigid[2])) < 1e-9)
	shown = drag._limit_stop(state, _carried(refs, -40.0), true)
	print("SMOKE ...and the same at the other end (gap 30, 10 mm back): ", absf(shown[0]["t"][0] - (refs[0]["t"][0] - 10.0)) < 1e-4 and absf(shown[1]["t"][0] - (refs[1]["t"][0] - 10.0)) < 1e-4 and state["at_limit"])
	state["at_limit"] = false
	drag._limit_stop(state, far, false)
	print("SMOKE only the frame being shown is recorded (an anchor's peek must not flip the flag): ", not state["at_limit"])

	# the member list may order the follower first: the model's lead is found by its id
	var swapped := {"limits": state["limits"], "members": ["cover", lead_id], "hyst": {"active": {"refs": [refs[1], refs[0]]}}, "at_limit": false}
	shown = drag._limit_stop(swapped, [far[1], far[0]], true)
	print("SMOKE with the follower listed first the lead is still the one measured (stops at 15 mm): ", absf(shown[1]["t"][0] - (refs[0]["t"][0] + 15.0)) < 1e-4 and absf(shown[0]["t"][0] - (refs[1]["t"][0] + 15.0)) < 1e-4 and swapped["at_limit"])

	# a model of another group is not applied: the leads and followers together must be exactly the drag's members
	var other_group := {"limits": state["limits"], "members": [lead_id], "hyst": {"active": {"refs": [refs[0]]}}, "at_limit": false}
	print("SMOKE a model whose followers are not among the drag's members is not applied: ", absf(drag._limit_stop(other_group, [far[0]], true)[0]["t"][0] - far[0]["t"][0]) < 1e-12)
	var stranger := {"limits": state["limits"], "members": [lead_id, "someone-else"], "hyst": {"active": {"refs": refs}}, "at_limit": false}
	print("SMOKE ...nor one for a different follower: ", absf(drag._limit_stop(stranger, far, true)[0]["t"][0] - far[0]["t"][0]) < 1e-12)
	var bigger := {"limits": state["limits"], "members": [lead_id, "cover", "extra"], "hyst": {"active": {"refs": [refs[0], refs[1], refs[1]]}}, "at_limit": false}
	print("SMOKE ...nor one for a larger group: ", absf(drag._limit_stop(bigger, [far[0], far[1], far[1]], true)[0]["t"][0] - far[0]["t"][0]) < 1e-12)

	# the version-7 stop (no set) is unchanged: one member, the same numbers as tests/limit_mates.gd
	var m7 = Local.try_parse(v7, 8)
	var s7 := {"limits": m7, "members": m7.member_ids, "hyst": {"active": {"refs": [refs0[0]]}}, "at_limit": false}
	var shown7: Array = drag._limit_stop(s7, [_carried([refs0[0]], 40.0)[0]], true)
	print("SMOKE a version-7 model (no set) stops exactly as before: ", absf(shown7[0]["t"][0] - (refs0[0]["t"][0] + 15.0)) < 1e-4 and s7["at_limit"])

	# the cost of the stop with a set: one bisection on the limit's value, no solve
	var started := Time.get_ticks_usec()
	for _i in 100:
		drag._limit_stop(state, far, true)
	print("SMOKE BENCH the stop on a lead and a follower: ", (Time.get_ticks_usec() - started) / 100, " us (a headset frame is 11000 us; reported, never a gate)")
	drag.free()
	quit()


static func _carried(poses: Array, dx: float) -> Array:
	## Every pose moved `dx` along x (a rigid carry, as the projector would show it).
	var out: Array = []
	for p in poses:
		out.append(Se3.make_pose([p["t"][0] + dx, p["t"][1], p["t"][2]], p["r"]))
	return out


static func _with_version(model: Dictionary, version: int) -> Dictionary:
	var m: Dictionary = model.duplicate(true)
	m["version"] = version
	return m
