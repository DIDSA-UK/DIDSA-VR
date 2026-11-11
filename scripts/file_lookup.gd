extends RefCounted
## Finding moved files: the rule that finds the file an occurrence places when its path misses. A copy of DIDSA-CAD's
## backend/app/document/file_lookup.py (DIDSA-CAD docs/moved-files-scope.md section 2), tested against its golden vectors
## (tests/fixtures/file_lookup_vectors.json, a copy of DIDSA-CAD docs/file-lookup/vectors.json; tests/file_lookup_vectors.gd).
##
## find_file(reference, at_path, index):
##   reference = {"external_ref": "parts/Frame A.didsa", "ref_part_id": "f676..." or null}
##   at_path   = {"path", "part_id"} (the file native_compose.gd's path lookup found, with its root Part id) or null
##   index     = [{"path", "part_id"}, ...] (every native file in the folders searched, part_id null when unreadable)
## returns {"result": "found" | "likely" | "ask" | "suggest" | "missing", "path", "via": "path" | "id" | "suffix", "candidates", "path_mismatch"}:
##   1. the path: its file with the stored id, or any file there for an older reference (no id), is found via "path"; a file there
##      with another id is not used (path_mismatch) and the search goes on;
##   2. the id: one file with it is found via "id"; several are "ask" (nothing loaded until the user picks);
##   2b. the folder shift (DIDSA-CAD docs/flutter-testing-feedback-2026-11-11-plan.md item 1b): for a reference with NO stored id, exactly
##      one name match with the most trailing path segments in common (k >= 2, and one path is the other with leading folders dropped)
##      is "likely" via "suffix". Never used by the rule itself: the caller asks the user (or applies the session's stored answer);
##   3. the name: same-name files anywhere (extension and case set aside), plus a mismatched file at the path, are only a "suggest",
##      ordered by shared trailing segments, then path;
##   4. otherwise "missing".

const NATIVE_EXTENSIONS: Array[String] = ["didsa", "DIDSAprt", "didsacad"] ## as native_compose.gd


static func is_native(path: String) -> bool:
	var lower := path.strip_edges().to_lower()
	for extension in NATIVE_EXTENSIONS:
		if lower.ends_with("." + extension.to_lower()):
			return true
	return false


static func name_key(path: String) -> String:
	## The last path segment, lower-cased, with any native extension removed: `parts/Bracket.didsa` = `old/bracket.DIDSAprt`.
	var name := path.strip_edges().replace("\\", "/").get_file()
	var lower := name.to_lower()
	for extension in NATIVE_EXTENSIONS:
		var suffix := "." + extension.to_lower()
		if lower.ends_with(suffix):
			return lower.substr(0, lower.length() - suffix.length())
	return lower


static func segments(path: String) -> Array:
	## The folder-shift step's view of a path: separators unified, empty and "." segments dropped, lower-cased, and the file name
	## without its native extension (`Proj/Parts/Bracket.didsa` -> ["proj", "parts", "bracket"]).
	var raw := path.strip_edges().replace("\\", "/").split("/")
	var parts: Array = []
	for segment in raw:
		if segment != "" and segment != ".":
			parts.append(segment)
	if parts.is_empty():
		return []
	var out: Array = []
	for i in range(parts.size() - 1):
		out.append(str(parts[i]).to_lower())
	out.append(name_key(str(parts[parts.size() - 1])))
	return out


static func shared_tail(a: Array, b: Array) -> int:
	var count := 0
	while count < mini(a.size(), b.size()) and a[a.size() - 1 - count] == b[b.size() - 1 - count]:
		count += 1
	return count


static func _answer(result: String, path = null, via = null, candidates: Array = [], mismatch := false, keep_order := false) -> Dictionary:
	var out: Array = []
	if keep_order:
		out = candidates.duplicate()
	else:
		var unique := {}
		for c in candidates:
			unique[c] = true
		out = unique.keys()
		out.sort()
	return {"result": result, "path": path, "via": via, "candidates": out, "path_mismatch": mismatch}


static func find_file(reference: Dictionary, at_path, index: Array) -> Dictionary:
	var ref_id = reference.get("ref_part_id")
	if ref_id != null and str(ref_id) == "":
		ref_id = null
	var mismatch := false
	if at_path is Dictionary:
		if ref_id == null or at_path.get("part_id") == ref_id:
			return _answer("found", at_path["path"], "path")
		mismatch = true
	if ref_id != null:
		var by_id := []
		for entry in index:
			if entry.get("part_id") == ref_id:
				by_id.append(entry["path"])
		var unique_ids := {}
		for p in by_id:
			unique_ids[p] = true
		if unique_ids.size() == 1:
			return _answer("found", unique_ids.keys()[0], "id", [], mismatch)
		if not unique_ids.is_empty():
			return _answer("ask", null, null, by_id, mismatch)
	var external_ref := str(reference.get("external_ref", "")).strip_edges() if reference.get("external_ref") != null else ""
	if external_ref != "":
		var key := name_key(external_ref)
		var wanted := segments(external_ref)
		var names := {}
		for entry in index:
			if name_key(str(entry["path"])) == key:
				names[entry["path"]] = true
		if mismatch:
			names[at_path["path"]] = true
		if not names.is_empty():
			var scored: Array = []
			for path in names.keys():
				scored.append({"k": shared_tail(wanted, segments(str(path))), "path": path})
			scored.sort_custom(func(a, b): return a["k"] > b["k"] if a["k"] != b["k"] else str(a["path"]) < str(b["path"]))
			var best: Dictionary = scored[0]
			var unique_best: bool = scored.size() == 1 or int(scored[1]["k"]) < int(best["k"])
			var best_segments := segments(str(best["path"]))
			var whole_suffix: bool = int(best["k"]) == mini(wanted.size(), best_segments.size())
			if ref_id == null and unique_best and int(best["k"]) >= 2 and whole_suffix:
				return _answer("likely", best["path"], "suffix")
			var ordered: Array = []
			for item in scored:
				ordered.append(item["path"])
			return _answer("suggest", null, null, ordered, mismatch, true)
	return _answer("missing", null, null, [], mismatch)


# --- The learned folder shift (item 1c): `from` is replaced by `to` at the start of every stored path ---------------------------

static func raw_segments(path: String) -> Array:
	var out: Array = []
	for segment in path.strip_edges().replace("\\", "/").split("/"):
		if segment != "" and segment != ".":
			out.append(segment)
	return out


static func _lowered(parts: Array) -> Array:
	var out: Array = []
	for p in parts:
		out.append(str(p).to_lower())
	return out


static func shift_between(stored_path: String, found_path: String) -> Dictionary:
	## {"from": [...], "to": [...]} for the folders `found_path` adds / removes against `stored_path` (their shared trailing segments are
	## the unchanged tail), or {} when nothing shifted (same folders, a plain rename) or they share no tail.
	var stored := raw_segments(stored_path)
	var found := raw_segments(found_path)
	var tail := shared_tail(_lowered(stored), _lowered(found))
	if tail < 1:
		return {}
	var from: Array = stored.slice(0, stored.size() - tail)
	var to: Array = found.slice(0, found.size() - tail)
	if from.is_empty() and to.is_empty():
		return {}
	return {"from": from, "to": to}


static func apply_shift(shift: Dictionary, stored_path: String) -> String:
	## `stored_path` with the shift applied, or "" when it does not start with `from`.
	var stored := raw_segments(stored_path)
	var from: Array = shift["from"]
	if stored.size() < from.size():
		return ""
	for i in from.size():
		if str(stored[i]).to_lower() != str(from[i]).to_lower():
			return ""
	var out: Array = (shift["to"] as Array).duplicate()
	out.append_array(stored.slice(from.size()))
	return "/".join(PackedStringArray(out))


static func same_shift(a: Dictionary, b: Dictionary) -> bool:
	return "/".join(PackedStringArray(a["from"])) == "/".join(PackedStringArray(b["from"])) and "/".join(PackedStringArray(a["to"])) == "/".join(PackedStringArray(b["to"]))


static func files_at(candidate_path: String, index: Array) -> Array:
	## The entries of `index` ({"path", ...}) at `candidate_path`, compared the way the rule compares paths (case and native extension set aside).
	var wanted := "/".join(PackedStringArray(segments(candidate_path)))
	var out: Array = []
	for entry in index:
		if "/".join(PackedStringArray(segments(str(entry["path"])))) == wanted:
			out.append(entry)
	return out
