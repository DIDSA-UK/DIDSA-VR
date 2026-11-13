extends RefCounted
## Timing of the local nearest-point retraction (scripts/motion/local_retraction.gd) on the golden-vector scenes, for the
## "is the GDScript port cheap enough for the headset?" decision (DIDSA-CAD docs/constrained-drag-f1a-design.md, F1b VR).
## Used by tests/bench_local_retraction.gd (desktop, tight loop) and scenes/bench_local_retraction.tscn (on the headset, one call
## per rendered frame so it competes with the real render loop and the thermal state is realistic).
##
## Cases: bolt in a fixed plate (k=1), floating bolt + plate (k=2), the 5-box row cut to its first 3 boxes (k=3, synthetic, 4 residual
## rows per mate), and the full 5- and 8-box rows (information only: beyond the GDScript limit MAX_MEMBERS); then the reduced models below. Every call is one
## full frame(): trust-region iterations + polish + the acceptance residual, Jacobians included. The projector's own frame on a
## golden `project` case is timed as the reference cost the app already pays.
##
## M2 (DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md`): the REDUCED models. Since M1 a group's rigid sets are merged into one body per set and
## the exported constraint model (version 8) has one member per set (a "lead"), so a 10-part chain is one lead and no rows. `tests/fixtures/m0_reduced_models.json`
## (a copy of DIDSA-CAD's `client/test/data/m0_reduced_models.json`, written by `backend/tests/export_m0_reduced_models.py`) holds the models of the 22 M0 scaling
## scene variants; the cases below time a frame() on three of them (one lead with nine or eight followers: no rows, 16 rows, 12 rows: the shapes a typical group now has)
## and, with `include_large`, on the linkage (3 and 4 leads, 40 rows) and a bolted chain (7 leads, 76 rows), which are too slow to share a headset frame with the
## others (they are for information).

const Se3 := preload("res://scripts/motion/se3.gd")
const Local := preload("res://scripts/motion/local_retraction.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const FIXTURE := "res://tests/fixtures/motion_vectors.json"
const REDUCED_FIXTURE := "res://tests/fixtures/m0_reduced_models.json"
## [label, scene, variant, only with include_large]
const REDUCED := [
	["v8 chain-10 floating (1 lead, 9 followers, 0 rows)", "chain-10", "floating", false],
	["v8 chain-10 fixed (1 lead, 8 followers, 16 rows)", "chain-10", "fixed", false],
	["v8 frame-10 fixed (1 lead, 8 followers, 12 rows)", "frame-10", "fixed", false],
	["v8 linkage fixed (3 leads, 20 followers, 40 rows)", "linkage-payload-20", "fixed", true],
	["v8 linkage floating (4 leads, 20 followers, 40 rows)", "linkage-payload-20", "floating", true],
	["v8 chain-5-bolts fixed (7 leads, 3 followers, 76 rows)", "chain-5-bolts", "fixed", true],
]

var cases: Array = [] ## [{name, model, poses, wishes, lever, k, rows}]
var projector_case := {}
var samples := {} ## name -> PackedFloat64Array of per-call microseconds


static func load_fixture() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))


func setup(include_large: bool = false) -> bool:
	var doc := load_fixture()
	if doc.is_empty():
		return false
	var by_id := {}
	for c in doc["cases"]:
		by_id[c["id"]] = c
	var specs := [
		["k=1 bolt in plate", "local-bolt-pull-off-and-spin", 0],
		["k=2 floating bolt", "local-floating-bolt-slide-and-spin", 0],
		["k=3 row of 3 boxes (synthetic)", "local-row5-slide-spin", 3],
		["k=5 row of 5 boxes (> limit)", "local-row5-slide-spin", 0],
		["k=8 row of 8 boxes (> limit)", "local-row8-slide-spin", 0],
	]
	for s in specs:
		if not include_large and str(s[0]).contains("(> limit)"):
			continue
		var inp: Dictionary = by_id[s[1]]["input"]
		var model_json: Dictionary = (inp["model"] as Dictionary).duplicate(true)
		var poses: Array = inp["poses"].map(func(p): return Se3.pose_from_json(p))
		var wishes: Array = inp["wishes"].map(func(p): return Se3.pose_from_json(p))
		var keep: int = s[2]
		if keep > 0:
			model_json["members"] = (model_json["members"] as Array).slice(0, keep)
			var mates: Array = []
			for m in model_json["mates"]:
				if int(m["a"]["member"]) < keep and int(m["b"]["member"]) < keep:
					mates.append(m)
			model_json["mates"] = mates
			poses = poses.slice(0, keep)
			wishes = wishes.slice(0, keep)
		var model = Local.try_parse(model_json, 8)
		if model == null:
			return false
		cases.append({"name": s[0], "model": model, "poses": poses, "wishes": wishes, "lever": float(inp["lever_arm"])})
		samples[s[0]] = PackedFloat64Array()
	if not _setup_reduced(include_large):
		return false
	# the projector's own frame (what the app already pays), from a golden `project` case with a basis
	for c in doc["cases"]:
		if c["kind"] == "project" and (c["input"]["basis"] as Array).size() > 0 and (c["input"]["refs"] as Array).size() >= 2:
			var i: Dictionary = c["input"]
			var refs: Array = i["refs"].map(func(p): return Se3.pose_from_json(p))
			projector_case = {
				"model": Projector.from_anchor(refs, i["basis"], float(i["lever_arm"])),
				"wish": Se3.pose_from_json(i["wanted"]),
				"name": "projector frame (%d members, %d basis rows)" % [refs.size(), (i["basis"] as Array).size()],
			}
			samples[projector_case["name"]] = PackedFloat64Array()
			break
	return true


func _setup_reduced(include_large: bool) -> bool:
	if not FileAccess.file_exists(REDUCED_FIXTURE):
		return false
	var all = JSON.parse_string(FileAccess.get_file_as_string(REDUCED_FIXTURE))
	if not (all is Array):
		return false
	for spec in REDUCED:
		if spec[3] and not include_large:
			continue
		var entry: Dictionary = {}
		for e in all:
			if e["scene"] == spec[1] and e["variant"] == spec[2]:
				entry = e
		if entry.is_empty():
			return false
		var model = Local.try_parse(entry["model"], 64, 1024) # the caps lifted: the cost is the point
		if model == null:
			return false
		cases.append({
			"name": spec[0],
			"model": model,
			"poses": entry["poses"].map(func(p): return Se3.pose_from_json(p)),
			"wishes": entry["wishes"].map(func(p): return Se3.pose_from_json(p)),
			"lever": float(entry["lever_arm"]),
		})
		samples[spec[0]] = PackedFloat64Array()
	return true


## One timed call of EVERY case (and the projector); appends the microseconds. (Desktop tight loop.)
func run_once() -> void:
	for c in cases:
		var t0 := Time.get_ticks_usec()
		(c["model"] as RefCounted).frame(c["poses"], c["wishes"], c["poses"], c["lever"])
		_add(c["name"], Time.get_ticks_usec() - t0)
	if not projector_case.is_empty():
		var t1 := Time.get_ticks_usec()
		(projector_case["model"] as RefCounted).project(projector_case["wish"])
		_add(projector_case["name"], Time.get_ticks_usec() - t1)


## One timed call of ONE entry, round-robin over the cases and the projector (a headset frame must not pay for all of them).
var _turn := 0


func run_next() -> void:
	var total := cases.size() + (0 if projector_case.is_empty() else 1)
	var i := _turn % total
	_turn += 1
	if i < cases.size():
		var c: Dictionary = cases[i]
		var t0 := Time.get_ticks_usec()
		(c["model"] as RefCounted).frame(c["poses"], c["wishes"], c["poses"], c["lever"])
		_add(c["name"], Time.get_ticks_usec() - t0)
	else:
		var t1 := Time.get_ticks_usec()
		(projector_case["model"] as RefCounted).project(projector_case["wish"])
		_add(projector_case["name"], Time.get_ticks_usec() - t1)


func _add(key: String, micros: float) -> void:
	var a: PackedFloat64Array = samples[key] # packed arrays are value types: write the appended copy back
	a.append(micros)
	samples[key] = a


func clear() -> void:
	for k in samples:
		samples[k] = PackedFloat64Array()


## "name: n=.. mean=.. p50=.. p95=.. p99=.. max=.. us" lines for the samples so far.
func report(label: String = "") -> Array:
	var out: Array = []
	for k in samples:
		var a: PackedFloat64Array = samples[k]
		if a.is_empty():
			continue
		var sorted := a.duplicate()
		sorted.sort()
		var total := 0.0
		for x in a:
			total += x
		var pick := func(q: float) -> float: return sorted[mini(sorted.size() - 1, int(q * sorted.size()))]
		out.append("SMOKE BENCH %s%-40s n=%5d mean %8.1f us  p50 %8.1f  p95 %8.1f  p99 %8.1f  max %8.1f" % [label, k, a.size(), total / a.size(), pick.call(0.5), pick.call(0.95), pick.call(0.99), sorted[sorted.size() - 1]])
	return out
