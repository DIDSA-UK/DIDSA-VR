extends RefCounted
## Finding moved files: the rule that finds the file an occurrence places when its path misses. A copy of DIDSA-CAD's
## backend/app/document/file_lookup.py (DIDSA-CAD docs/moved-files-scope.md section 2), tested against its golden vectors
## (tests/fixtures/file_lookup_vectors.json, a copy of DIDSA-CAD docs/file-lookup/vectors.json; tests/file_lookup_vectors.gd).
##
## find_file(reference, at_path, index):
##   reference = {"external_ref": "parts/Frame A.didsa", "ref_part_id": "f676..." or null}
##   at_path   = {"path", "part_id"} (the file native_compose.gd's path lookup found, with its root Part id) or null
##   index     = [{"path", "part_id"}, ...] (every native file in the folders searched, part_id null when unreadable)
## returns {"result": "found" | "ask" | "suggest" | "missing", "path", "via": "path" | "id", "candidates", "path_mismatch"}:
##   1. the path: its file with the stored id, or any file there for an older reference (no id), is found via "path"; a file there
##      with another id is not used (path_mismatch) and the search goes on;
##   2. the id: one file with it is found via "id"; several are "ask" (nothing loaded until the user picks);
##   3. the name: same-name files anywhere (extension and case set aside), plus a mismatched file at the path, are only a "suggest";
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


static func _answer(result: String, path = null, via = null, candidates: Array = [], mismatch := false) -> Dictionary:
	var unique := {}
	for c in candidates:
		unique[c] = true
	var sorted: Array = unique.keys()
	sorted.sort()
	return {"result": result, "path": path, "via": via, "candidates": sorted, "path_mismatch": mismatch}


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
		if by_id.size() == 1:
			return _answer("found", by_id[0], "id", [], mismatch)
		if not by_id.is_empty():
			return _answer("ask", null, null, by_id, mismatch)
	var external_ref := str(reference.get("external_ref", "")).strip_edges() if reference.get("external_ref") != null else ""
	if external_ref != "":
		var key := name_key(external_ref)
		var by_name := []
		for entry in index:
			if name_key(str(entry["path"])) == key:
				by_name.append(entry["path"])
		if mismatch:
			by_name.append(at_path["path"])
		if not by_name.is_empty():
			return _answer("suggest", null, null, by_name, mismatch)
	return _answer("missing", null, null, [], mismatch)
