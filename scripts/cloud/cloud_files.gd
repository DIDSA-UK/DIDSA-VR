extends RefCounted
## S3: small file helpers for the mirror folder and the private state, as pure static functions: list a folder recursively (hidden entries and our own
## temp files skipped), hash a file or bytes (SHA-256, the store's own hash), read and write bytes (writes go to a temp file then a rename: never a
## half-written file), remove a file. Nothing here keeps state.

const TEMP_SUFFIX := ".cloudtmp"
const CHUNK := 1024 * 1024


static func list_files(root: String) -> Dictionary:
	## relative path ('/' separators) -> full path, for every file under `root`. A name starting with a dot, and the temp files of this code and of
	## project_save.gd (".saving"), are not files of the project: the mirror is visible and a user may keep their own notes beside it.
	var out := {}
	_walk(root, "", out, 0)
	return out


static func _walk(root: String, rel: String, out: Dictionary, depth: int) -> void:
	if depth > 24:
		return
	var folder := root if rel == "" else root.path_join(rel)
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	for name in dir.get_files():
		if is_project_file_name(name):
			out[name if rel == "" else rel + "/" + name] = folder.path_join(name)
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			_walk(root, sub if rel == "" else rel + "/" + sub, out, depth + 1)


static func is_project_file_name(name: String) -> bool:
	return not name.begins_with(".") and not name.ends_with(".saving") and not name.ends_with(TEMP_SUFFIX)


static func is_mirrorable(path: String) -> bool:
	## Whether a path the STORE names can be written into the mirror: relative, '/' separators, no '.' or '..' or empty segment (it can never leave the folder), no drive or
	## colon, and none of this code's own non-project names (a dot-name would never be scanned back). The real store refuses most of these already; a client does not
	## rely on that for a path it is about to write to disk.
	if path == "" or path.begins_with("/") or "\\" in path or ":" in path:
		return false
	for segment in path.split("/"):
		if segment == "" or segment == "." or segment == ".." or segment.begins_with(".") or segment.ends_with(TEMP_SUFFIX) or segment.ends_with(".saving"):
			return false
	return true


static func hash_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func hash_file(path: String) -> String:
	## SHA-256 of a file read in chunks ("" when it can't be read). The file is read once, so a change made meanwhile is never half-seen as two versions.
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var chunk := file.get_buffer(CHUNK)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	return ctx.finish().hex_encode()


static func read_bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()


static func file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return -1 if file == null else file.get_length()


static func write_bytes_atomic(path: String, bytes: PackedByteArray) -> String:
	## Writes beside `path`, then renames over it. "" on success, else why not (in words).
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return "couldn't make the folder %s (error %d)" % [dir, made]
	var temp := path + TEMP_SUFFIX
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return "couldn't write %s (error %d)" % [path.get_file(), FileAccess.get_open_error()]
	file.store_buffer(bytes)
	var wrote_ok := file.get_error() == OK
	file.close()
	if not wrote_ok:
		DirAccess.remove_absolute(temp)
		return "couldn't write %s (the disk may be full)" % path.get_file()
	var renamed := DirAccess.rename_absolute(temp, path)
	if renamed != OK:
		DirAccess.remove_absolute(temp)
		return "couldn't replace %s (error %d)" % [path.get_file(), renamed]
	return ""


static func remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
