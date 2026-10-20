extends RefCounted
## Finding moved files (DIDSA-CAD docs/moved-files-scope.md, F2): an index of every native file under the folders a reference is
## looked for in (native_compose.gd's bases: the opened file's folder, the project folder, the models folders), with each file's
## root Part id, for file_lookup.gd's steps 2 and 3. Built only when a reference misses, walking every subfolder (dot-folders
## skipped; at most MAX_FILES files, MAX_DEPTH folders deep). Reading a file's id means opening it, so the ids are cached per file
## and last-modified time for the whole session.

const FileLookup := preload("res://scripts/file_lookup.gd")
const MAX_FILES := 5000
const MAX_DEPTH := 12

static var _id_cache: Dictionary = {} ## file -> {"mtime": int, "id": String}


static func read_part_id(file: String) -> String:
	## A native file's root Part id (document.root_part_id, else its first Part's id), or "" when it can't be read.
	if not FileAccess.file_exists(file):
		return ""
	var mtime := FileAccess.get_modified_time(file)
	var cached = _id_cache.get(file)
	if cached != null and cached["mtime"] == mtime:
		return cached["id"]
	var found := ""
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
	if parsed is Dictionary and parsed.get("document") is Dictionary:
		var document: Dictionary = parsed["document"]
		if document.get("root_part_id") != null:
			found = str(document["root_part_id"])
		if found == "" and document.get("parts") is Array and not (document["parts"] as Array).is_empty() and document["parts"][0] is Dictionary:
			found = str(document["parts"][0].get("id", ""))
	_id_cache[file] = {"mtime": mtime, "id": found}
	return found


static func relative_to(file: String, bases: Array) -> String:
	## `file` as a reference: its path under the first of `bases` that holds it, or "" when none does (an external_ref never walks
	## out of the folders it is looked for in).
	for base in bases:
		var prefix := str(base).trim_suffix("/") + "/"
		if file.begins_with(prefix):
			return file.substr(prefix.length())
	return ""


static func build(bases: Array) -> Array:
	## [{"path" (relative to its base, the reference form), "file" (full path), "part_id" ("" when unreadable)}], each file once
	## (under the first base that holds it), in walk order.
	var out := []
	var seen := {}
	for base in bases:
		_walk(str(base), str(base), 0, seen, out)
	return out


static func _walk(base: String, folder: String, depth: int, seen: Dictionary, out: Array) -> void:
	if depth > MAX_DEPTH or out.size() >= MAX_FILES:
		return
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	for name in dir.get_files():
		if out.size() >= MAX_FILES:
			return
		if not FileLookup.is_native(name):
			continue
		var file := folder.path_join(name)
		if seen.has(file):
			continue
		seen[file] = true
		out.append({"path": relative_to(file, [base]), "file": file, "part_id": read_part_id(file)})
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			_walk(base, folder.path_join(sub), depth + 1, seen, out)
