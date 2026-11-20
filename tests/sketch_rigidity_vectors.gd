extends SceneTree
## Headless, no network: the sketch rigidity count (scripts/design_table/sketch_rigidity.gd, parity follow-ups F7, written from DIDSA-CAD's docs/sketch-rigidity-spec.md) against
## DIDSA-CAD's docs/sketch-rigidity-vectors.json (34 cases: every input of the flat app's dof_analysis tests with its assertions, and seven whole-entity scenes). The json is
## COPIED to tests/fixtures/sketch_rigidity_vectors.json; with a DIDSA-CAD checkout reachable (env DIDSA_CAD_DIR, else ../DIDSA-CAD) the test also fails if the copy differs.
## Replay (spec 6): the four sets (fully, over, grounded, pinned) and `any_grounded` equal the file's EXACTLY (there are no numbers); every `checks` query (fully, over, grounded,
## pinned, segment_fully, segment_over, any_grounded) answers `want`; a scene's entities get their verdict by section 4's pair rule (over / fully / free).
## Run: "$GODOT" --headless --path . --script res://tests/sketch_rigidity_vectors.gd

const Rigidity := preload("res://scripts/design_table/sketch_rigidity.gd")
const FIXTURE := "res://tests/fixtures/sketch_rigidity_vectors.json"

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/sketch-rigidity-vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/sketch-rigidity-vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


static func _sorted(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


static func _answer(r, query: String, args: Array) -> Variant:
	match query:
		"fully":
			return r.is_fully(str(args[0]))
		"over":
			return r.is_over(str(args[0]))
		"grounded":
			return r.is_grounded(str(args[0]))
		"pinned":
			return r.is_pinned(str(args[0]))
		"segment_fully":
			return r.segment_fully(str(args[0]), str(args[1]))
		"segment_over":
			return r.segment_over(str(args[0]), str(args[1]))
		"any_grounded":
			return r.any_grounded
	return null


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc: Variant = JSON.parse_string(text)
	if not (doc is Dictionary):
		_check(false, "fixture parses")
		quit(1)
		return
	_check(true, "fixture copy vs DIDSA-CAD: %s" % _source_check(text))
	var cost_ok := true
	for t in doc["dof_cost"]:
		cost_ok = cost_ok and Rigidity.COST.get(t, 0) == int(doc["dof_cost"][t])
	for t in Rigidity.COST:
		cost_ok = cost_ok and int(doc["dof_cost"].get(t, -1)) == int(Rigidity.COST[t])
	_check(cost_ok, "the cost table equals the file's")
	var n := 0
	var passed := 0
	var queries := 0
	var entities := 0
	for c: Dictionary in doc["cases"]:
		n += 1
		var inp: Dictionary = c["input"]
		var r = Rigidity.analyse(inp["point_ids"], inp["fixed"], inp["lines"], inp["constraints"], bool(inp["trust_converged_solve"]))
		var want: Dictionary = c["frames"][0]
		var problem := ""
		for key in ["fully", "over", "grounded", "pinned"]:
			var got := _sorted(r.get(key))
			if got != want[key]:
				problem = "%s %s, expected %s" % [key, got, want[key]]
				break
		if problem == "" and r.any_grounded != bool(want["any_grounded"]):
			problem = "any_grounded %s" % r.any_grounded
		if problem == "":
			for q: Dictionary in c["checks"]:
				queries += 1
				if _answer(r, str(q["query"]), q["args"]) != q["want"]:
					problem = "query %s%s answered %s, expected %s" % [q["query"], q["args"], _answer(r, str(q["query"]), q["args"]), q["want"]]
					break
		if problem == "" and inp.has("entities"):
			for kind in inp["entities"]:
				for eid in inp["entities"][kind]:
					entities += 1
					var got_state: String = r.entity_state(Rigidity.pairs_of(str(kind), inp["entities"][kind][eid]))
					if got_state != str(want["entities"][kind][eid]):
						problem = "%s %s is %s, expected %s" % [kind, eid, got_state, want["entities"][kind][eid]]
		if problem == "":
			passed += 1
		_check(problem == "", "rigidity case %s%s" % [c["id"], "" if problem == "" else " (" + problem + ")"])
	_check(passed == n, "rigidity vectors: %d cases, %d queries, %d entities, %d passed" % [n, queries, entities, passed])
	print("SMOKE ", "PASSED" if failures == 0 else "FAILED")
	quit(0 if failures == 0 else 1)
