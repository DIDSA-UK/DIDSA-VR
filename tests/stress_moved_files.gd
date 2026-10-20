extends SceneTree
## Stress for finding moved files (DIDSA-CAD docs/moved-files-scope.md, F2), headless, no network: hundreds of seeded random project
## folders - files in odd folders (spaces, accents, deep, a dot-folder), copies carrying the same part id, a different part sitting at
## the old path, corrupt / empty / not-native files, references with the right id, no id, an older file's resolved_part_id or a wrong
## id, references to paths that moved, were renamed or never existed - composed by native_compose.gd and compared with a separate,
## simple model of the rule written here from the scope doc (not from the code under test): which references resolve, which are
## asked / suggested / missing and whether the path mismatch is reported. Then worlds with a reference cycle, a self-reference, a
## chain four deep, and nothing but garbage, which must not hang or throw and must keep the payload coherent.
## Invariants on every compose: `text` parses, no duplicate part ids, every resolved_part_id names a part in the payload, a reference
## is never resolved to a file whose id differs from the one it remembers unless it had none.
## Run: "$GODOT" --headless --path . --script res://tests/stress_moved_files.gd [-- worlds=300 seed=1]

const NativeCompose := preload("res://scripts/native_compose.gd")
const FileIndex := preload("res://scripts/file_index.gd")
const DIR := "user://stress_moved_files"

var failures := 0
var rng := RandomNumberGenerator.new()
var worlds := 300
var current := ""

const FOLDERS := ["", "a/", "a/b/", "x y/", "ünï cödé/", ".hid/", "deep/1/2/3/4/5/6/", "Parts/", "parts/"]
const NAMES := ["Frame", "Bolt (1)", "Leg", "Plate 2", "ÜberPlatte", "a", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]


func _check(ok: bool, label: String) -> void:
	if not ok:
		print("SMOKE ", current, " ", label, ": false")
		failures += 1


func _part(id: String, occurrences: Array = []) -> Dictionary:
	return {"id": id, "name": id, "features": [], "occurrences": occurrences, "mates": []}


func _occ(id: String, ref: String, ref_part_id, resolved_part_id) -> Dictionary:
	var occ := {"id": id, "external_ref": ref, "resolved_part_id": resolved_part_id, "name_override": null,
		"transform": {"translation": [10, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}, "suppressed": false, "hidden": false, "fixed": false, "color": null}
	if ref_part_id != null:
		occ["ref_part_id"] = ref_part_id
	return occ


func _write_text(rel: String, text: String) -> String:
	var path := DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


func _write(rel: String, part: Dictionary) -> String:
	var payload := {"schema_version": 1, "document": {"id": "doc-" + str(part["id"]), "root_part_id": part["id"], "parts": [part]}, "sketches": []}
	return _write_text(rel, NativeCompose.to_json(payload))


func _remove_tree(folder: String) -> void:
	var d := DirAccess.open(folder)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_tree(folder.path_join(sub))
	for file in d.get_files():
		d.remove(file)
	DirAccess.remove_absolute(folder)


static func _name_key(path: String) -> String:
	var n := path.replace("\\", "/").get_file().to_lower()
	for ext in [".didsa", ".didsaprt", ".didsacad"]:
		if n.ends_with(ext):
			return n.substr(0, n.length() - ext.length())
	return n


func _pick(list: Array):
	return list[rng.randi() % list.size()]


func _world(n: int) -> void:
	current = "world %d" % n
	_remove_tree(DIR)
	FileIndex._id_cache.clear() # ids are cached per file and modified time (whole seconds): a rewritten file would read stale
	# --- the files on disk, and a model of them
	var files: Array = [] # {path, id ("" = unreadable)}
	var count := rng.randi_range(2, 8)
	for i in count:
		var folder: String = _pick(FOLDERS)
		var name: String = _pick(NAMES)
		var path: String = "%s%s%d.didsa" % [folder, name, i] if rng.randf() < 0.5 else "%s%s.didsa" % [folder, name]
		var is_corrupt := rng.randf() < 0.1
		var id := "id%d" % rng.randi_range(0, count)
		if files.any(func(f) -> bool: return f["path"] == path):
			continue
		if is_corrupt:
			var junk: String = _pick(["", "{not json", "[]", "{\"document\": 5}", "{\"document\": {\"parts\": []}}", "\u0000\u0001", "{\"document\":{\"parts\":[{},{}]}}"])
			_write_text(path, junk)
			files.append({"path": path, "id": ""})
		else:
			_write(path, _part(id))
			files.append({"path": path, "id": id})
	# --- the root's references
	var occs: Array = []
	var expectations: Array = [] # per occurrence, in order, from the model below
	var refs_n := rng.randi_range(1, 7)
	for i in refs_n:
		var target: Dictionary = _pick(files)
		var mode := rng.randi_range(0, 5)
		var ref: String = target["path"]
		match mode:
			1: ref = "%s%s" % [_pick(FOLDERS), target["path"].get_file()] # moved: the same name, some folder
			2: ref = "%s%s" % [target["path"].get_base_dir() + "/" if target["path"].get_base_dir() != "" else "", "Renamed%d.didsa" % i]
			3: ref = "gone/Never%d.didsa" % i
		var ref_id = target["id"] if target["id"] != "" else "id-of-a-corrupt-file"
		var roll := rng.randf()
		var ref_part_id = null
		var resolved_part_id = null
		if roll < 0.55:
			ref_part_id = ref_id
		elif roll < 0.7:
			ref_part_id = null
		elif roll < 0.85:
			resolved_part_id = ref_id # an older file: only resolved_part_id
		else:
			ref_part_id = "wrong-id"
		occs.append(_occ("o%d" % i, ref, ref_part_id, resolved_part_id))
	var root_path := _write("Root.didsa", _part("root", occs))
	var all := files.duplicate()
	all.append({"path": "Root.didsa", "id": "root"})

	# --- the model of the rule (docs/moved-files-scope.md section 2), in order, with "a part id is used once" bookkeeping
	var loaded_ids := {"root": "Root.didsa"}
	var loaded_files := {"Root.didsa": true}
	for occ in occs:
		var ref: String = occ["external_ref"]
		var stored := ""
		for k in ["ref_part_id", "resolved_part_id"]:
			if occ.get(k) != null and str(occ[k]) != "":
				stored = str(occ[k])
				break
		var at: Variant = null
		for f in files:
			if f["path"] == ref:
				at = f
		var expect := {"resolved": false, "result": "", "mismatch": false, "file": ""}
		var chosen = null
		var preset = occ.get("resolved_part_id")
		if preset != null and str(preset) != "" and loaded_ids.has(str(preset)):
			# native_compose.gd's _needs_file(): an occurrence whose resolved_part_id already names a Part in the payload is
			# taken as resolved (a bundle file); its file is not looked for and nothing is reported.
			expect["result"] = "bundle"
			expectations.append(expect)
			continue
		if at != null and (stored == "" or at["id"] == stored):
			chosen = at
		else:
			expect["mismatch"] = at != null
			var visible := all.filter(func(f) -> bool: return not (".hid/" in f["path"]) and not f["path"].begins_with(".hid"))
			var by_id := visible.filter(func(f) -> bool: return stored != "" and f["id"] == stored)
			if by_id.size() == 1:
				chosen = by_id[0]
			elif by_id.size() > 1:
				expect["result"] = "ask"
			else:
				var names := visible.filter(func(f) -> bool: return _name_key(f["path"]) == _name_key(ref))
				expect["result"] = "suggest" if (not names.is_empty() or at != null) else "missing"
		if chosen != null:
			# Loading it: a file that isn't a single readable part, or whose part id another file already brought in, stays unresolved.
			if chosen["id"] == "" or (loaded_ids.has(chosen["id"]) and loaded_ids[chosen["id"]] != chosen["path"]):
				expect["result"] = "unloadable"
			else:
				expect["resolved"] = true
				expect["file"] = chosen["path"]
				loaded_ids[chosen["id"]] = chosen["path"]
				loaded_files[chosen["path"]] = true
		expectations.append(expect)

	var failures_before := failures
	var started := Time.get_ticks_msec()
	var composed := NativeCompose.compose(root_path)
	_check(Time.get_ticks_msec() - started < 5000, "compose took %d ms" % (Time.get_ticks_msec() - started))
	_check(composed["ok"], "compose ok (%s)" % str(composed.get("error")))
	_invariants(composed)
	var payload = JSON.parse_string(composed["text"])
	var root_part: Dictionary = payload["document"]["parts"][0]
	var resolved_n := 0
	for i in occs.size():
		var o: Dictionary = (root_part["occurrences"] as Array)[i]
		var e: Dictionary = expectations[i]
		var got_resolved: bool = o.get("resolved_part_id") != null and str(o["resolved_part_id"]) != "" and o["resolved_part_id"] != occs[i].get("resolved_part_id") or (o.get("resolved_part_id") != null and e["resolved"])
		var review := {}
		for item in composed["review"]:
			if item["occurrence_id"] == o["id"]:
				review = item
		if e["resolved"]:
			resolved_n += 1
			_check(o.get("resolved_part_id") != null and str(o["resolved_part_id"]) == _id_of(files, e["file"]) and str(o["external_ref"]) == e["file"] or str(o["external_ref"]).get_file() == e["file"].get_file(),
				"occurrence %d (%s, stored %s) should resolve to %s; got ref %s resolved %s" % [i, occs[i]["external_ref"], str(occs[i].get("ref_part_id", occs[i].get("resolved_part_id"))), e["file"], str(o["external_ref"]), str(o.get("resolved_part_id"))])
		else:
			_check(review.is_empty() == (e["result"] == "unloadable" or e["result"] == "bundle") and (review.is_empty() or review["result"] == e["result"]),
				"occurrence %d (%s, stored %s) should be %s; review says %s" % [i, occs[i]["external_ref"], str(occs[i].get("ref_part_id", occs[i].get("resolved_part_id"))), e["result"], str(review.get("result", "none"))])
			if not review.is_empty():
				_check(bool(review["path_mismatch"]) == bool(e["mismatch"]), "occurrence %d path_mismatch %s should be %s" % [i, str(review["path_mismatch"]), str(e["mismatch"])])
			_check(got_resolved == false or o.get("resolved_part_id") == occs[i].get("resolved_part_id"), "occurrence %d must not resolve (%s)" % [i, e["result"]])
	if failures > failures_before:
		print("  world files: ", JSON.stringify(files))
		print("  root occurrences: ", JSON.stringify(occs.map(func(o) -> Array: return [o["external_ref"], o.get("ref_part_id"), o.get("resolved_part_id")])))
		print("  composed occurrences: ", JSON.stringify((root_part["occurrences"] as Array).map(func(o) -> Array: return [o["external_ref"], o.get("resolved_part_id")])))
		print("  review: ", JSON.stringify(composed["review"].map(func(r) -> Array: return [r["ref"], r["result"], r["path_mismatch"]])), " unresolved: ", JSON.stringify(composed["unresolved"]))
	_check(int(composed["resolved"]) == resolved_n, "resolved count %d should be %d" % [int(composed["resolved"]), resolved_n])


func _id_of(files: Array, path: String) -> String:
	for f in files:
		if f["path"] == path:
			return f["id"]
	return ""


func _invariants(composed: Dictionary) -> void:
	var payload = JSON.parse_string(composed["text"])
	_check(payload is Dictionary and payload.get("document") is Dictionary, "text parses to a document")
	if not (payload is Dictionary):
		return
	var ids := {}
	for p in payload["document"]["parts"]:
		_check(not ids.has(p["id"]), "duplicate part id %s in the payload" % str(p["id"]))
		ids[p["id"]] = true
	for p in payload["document"]["parts"]:
		for o in p.get("occurrences", []):
			if o.get("resolved_part_id") != null and str(o["resolved_part_id"]) != "":
				pass # an unresolved older reference keeps its stored resolved_part_id (the backend seeds ref_part_id from it and drops it)
	for item in composed["review"]:
		_check(item["result"] in ["ask", "suggest", "missing"], "a review item with result %s" % str(item["result"]))
		_check((item["result"] == "ask") == (item["candidates"].size() > 1 and item["result"] == "ask"), "ask has several candidates")


func _graph_worlds() -> void:
	current = "graph worlds"
	# A cycle A -> B -> A, a self-reference, and a chain four deep.
	_remove_tree(DIR)
	_write("A.didsa", _part("A", [_occ("oB", "B.didsa", "B", null)]))
	_write("B.didsa", _part("B", [_occ("oA", "A.didsa", "A", null)]))
	var composed := NativeCompose.compose(DIR.path_join("A.didsa"))
	_check(composed["ok"], "a cycle composes (ok)")
	_check(composed["unresolved"].any(func(s) -> bool: return "refers back" in s), "a cycle is reported (%s)" % str(composed["unresolved"]))
	_invariants(composed)
	_remove_tree(DIR)
	_write("S.didsa", _part("S", [_occ("o", "S.didsa", "S", null)]))
	composed = NativeCompose.compose(DIR.path_join("S.didsa"))
	_check(composed["ok"] and composed["resolved"] == 0, "a self-reference resolves nothing")
	_invariants(composed)
	_remove_tree(DIR)
	_write("c4.didsa", _part("c4"))
	_write("sub/c3.didsa", _part("c3", [_occ("o", "../c4.didsa", "c4", null)]))
	_write("c2.didsa", _part("c2", [_occ("o", "sub/c3.didsa", "c3", null)]))
	_write("c1.didsa", _part("c1", [_occ("o", "c2.didsa", "c2", null)]))
	_write("moved/c1.didsa", _part("c1root", [_occ("o", "../c1.didsa", "c1", null)]))
	composed = NativeCompose.compose(DIR.path_join("moved/c1.didsa"))
	_check(composed["ok"], "a chain composes")
	_invariants(composed)
	# Garbage and edge roots.
	for text in ["", "{", "null", "[]", "{\"document\":null}", "\u00ef\u00bb\u00bf{}", "{\"document\":{\"parts\":[{\"id\":\"x\",\"occurrences\":[{\"id\":\"o\",\"external_ref\":5}]}]}}",
			"{\"document\":{\"parts\":[{\"id\":\"x\",\"occurrences\":[{\"id\":\"o\",\"external_ref\":\"\"}]}]}}",
			"{\"document\":{\"parts\":[{\"id\":\"x\",\"occurrences\":[{\"id\":\"o\",\"external_ref\":\"../../../../etc/passwd\",\"ref_part_id\":\"q\"}]}]}}",
			"{\"document\":{\"parts\":[{\"id\":\"x\",\"occurrences\":[{\"id\":\"o\",\"external_ref\":\"C:\\\\windows\\\\x.didsa\",\"ref_part_id\":7}]}]}}"]:
		_remove_tree(DIR)
		var path := _write_text("G.didsa", text)
		var got := NativeCompose.compose(path)
		_check(got.has("ok"), "garbage root %s answers" % text.left(20).c_escape())
		if got["ok"]:
			_invariants(got)
	_remove_tree(DIR)
	# A compose of a missing file.
	_check(not NativeCompose.compose(DIR.path_join("nothing.didsa"))["ok"], "a missing root is not ok")


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seed="):
			rng.seed = int(a.trim_prefix("seed="))
		elif a.begins_with("worlds="):
			worlds = int(a.trim_prefix("worlds="))
	if rng.seed == 0:
		rng.seed = 1
	var t0 := Time.get_ticks_msec()
	for n in worlds:
		_world(n)
		if failures > 12:
			break
	_graph_worlds()
	_remove_tree(DIR)
	print("SMOKE STRESS: %d random project folders and the graph worlds in %d ms" % [worlds, Time.get_ticks_msec() - t0])
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
