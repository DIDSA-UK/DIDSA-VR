extends RefCounted
## What this headset knows about one server project, kept in PRIVATE storage (user://didsa-cloud-state/<key>/state.json, see cloud_paths.gd), never in the visible mirror
## folder: deleting the mirror cannot delete the queue.
##
##   files    path -> {version, sha256, size, modified_at, modified_by, part_id}   each file AS LAST SYNCED: the version a save is sent as replacing (its base) and
##                                                                                  the hash the mirror file is compared with to tell a local change
##   tree     path -> the same                                                       the store's file list at the last contact (what is "not downloaded", and the
##                                                                                  offline answer of the moved-files part index)
##   queue    path -> {base (int or null = create), queued_at_ms, sha (of the mirror file when last seen), clash (null or {reason, current_version, deleted, moved_to,
##                     modified_by, modified_at}), reconciled (the store's version this save was last weighed against, or null)}
##   mine     path -> {at_ms, fresh}   bytes kept in mine/ after Take theirs, until the next sync after the one that finishes the resolution (`fresh` is true until
##                                     one sync has gone by; the following successful sync with nothing queued drops it)
##   ignored  path -> sha         a file the user chose to keep local only (a save the store will not take); a later change to the file queues it again
##   behind   path -> version     a file this session holds that the store has a newer version of (it is NOT refreshed under the open session)
##   cursor   String              where the store's change feed was last read ("" = never)
##
## Writes are atomic (temp file, then rename), so a kill mid-save leaves the last good file. A state file that can't be read starts clean (the mirror still has the
## files; the next sync recognises every file whose bytes equal the store's, and queues the rest as new files).

const CloudFiles := preload("res://scripts/cloud/cloud_files.gd")

var dir := ""
var files: Dictionary = {}
var tree: Dictionary = {}
var queue: Dictionary = {}
var mine: Dictionary = {}
var ignored: Dictionary = {}
var behind: Dictionary = {}
var cursor := ""
var last_synced_ms := 0
var load_error := ""
var store_url := "" ## which store and project this state belongs to (so the landing can list what is waiting without asking the network)
var project := ""


static func open(state_dir: String) -> RefCounted:
	var state = load("res://scripts/cloud/cloud_state.gd").new()
	state.dir = state_dir
	state.load_from_disk()
	return state


func _file() -> String:
	return dir.path_join("state.json")


func load_from_disk() -> void:
	files.clear()
	tree.clear()
	queue.clear()
	mine.clear()
	ignored.clear()
	behind.clear()
	cursor = ""
	last_synced_ms = 0
	load_error = ""
	if not FileAccess.file_exists(_file()):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_file()))
	if not (parsed is Dictionary):
		load_error = "the sync state couldn't be read; starting clean (the files in the local copy are kept)"
		return
	for entry in parsed.get("files", []):
		if entry is Dictionary and entry.has("path"):
			files[str(entry["path"])] = _info(entry)
	for entry in parsed.get("tree", []):
		if entry is Dictionary and entry.has("path"):
			tree[str(entry["path"])] = _info(entry)
	for entry in parsed.get("queue", []):
		if entry is Dictionary and entry.has("path"):
			queue[str(entry["path"])] = {
				"base": null if entry.get("base") == null else int(entry["base"]),
				"queued_at_ms": int(entry.get("queued_at_ms", 0)),
				"sha": str(entry.get("sha", "")),
				"clash": _clash(entry.get("clash")),
				"reconciled": null if entry.get("reconciled") == null else int(entry["reconciled"]),
			}
	var kept = parsed.get("mine", {})
	if kept is Dictionary:
		for path in kept:
			var value = kept[path]
			mine[str(path)] = {"at_ms": int(value.get("at_ms", 0)), "fresh": bool(value.get("fresh", false))} if value is Dictionary else {"at_ms": int(value), "fresh": false}
	var skipped = parsed.get("ignored", {})
	if skipped is Dictionary:
		for path in skipped:
			ignored[str(path)] = str(skipped[path])
	var newer = parsed.get("behind", {})
	if newer is Dictionary:
		for path in newer:
			behind[str(path)] = int(newer[path])
	cursor = str(parsed.get("cursor", ""))
	last_synced_ms = int(parsed.get("last_synced_ms", 0))
	store_url = str(parsed.get("store_url", ""))
	project = str(parsed.get("project", ""))


static func _info(entry: Dictionary) -> Dictionary:
	return {"path": str(entry["path"]), "version": int(entry.get("version", 0)), "sha256": str(entry.get("sha256", "")), "size": int(entry.get("size", 0)),
		"modified_at": str(entry.get("modified_at", "")), "modified_by": str(entry.get("modified_by", "")),
		"part_id": null if entry.get("part_id") == null else str(entry["part_id"])}


static func info_from_store(entry: Dictionary) -> Dictionary:
	## A store file record ({path, size, sha256, version, modified_at, modified_by, part_id}) as this file keeps it.
	return _info(entry)


static func _clash(raw) -> Variant:
	if not (raw is Dictionary):
		return null
	return {
		"reason": str(raw.get("reason", "changed")),
		"current_version": null if raw.get("current_version") == null else int(raw["current_version"]),
		"deleted": bool(raw.get("deleted", false)),
		"moved_to": null if raw.get("moved_to") == null else str(raw["moved_to"]),
		"modified_by": str(raw.get("modified_by", "")),
		"modified_at": str(raw.get("modified_at", "")),
	}


func to_dictionary() -> Dictionary:
	var out := {"store_url": store_url, "project": project, "cursor": cursor, "last_synced_ms": last_synced_ms, "files": [], "tree": [], "queue": [], "mine": mine, "ignored": ignored, "behind": behind}
	for path in files:
		out["files"].append(files[path])
	for path in tree:
		out["tree"].append(tree[path])
	for path in queue:
		var entry: Dictionary = (queue[path] as Dictionary).duplicate()
		entry["path"] = path
		out["queue"].append(entry)
	return out


func save() -> String:
	## "" on success, else why not.
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return "couldn't make the sync state folder (error %d)" % made
	return CloudFiles.write_bytes_atomic(_file(), JSON.stringify(to_dictionary()).to_utf8_buffer())


# --- "mine" copies (bytes kept after Take theirs) -----------------------------------------------------------------------------------------------------

func _mine_file(path: String) -> String:
	return dir.path_join("mine").path_join(path.sha256_text() + ".bin")


func put_mine(path: String, bytes: PackedByteArray, now_ms: int) -> String:
	var error := CloudFiles.write_bytes_atomic(_mine_file(path), bytes)
	if error == "":
		mine[path] = {"at_ms": now_ms, "fresh": true}
	return error


func age_mine() -> void:
	## Called after a successful sync with nothing left to send: a kept copy that has already been through one such sync is dropped; a fresh one is kept for the next.
	for path in mine.keys():
		if bool(mine[path].get("fresh", false)):
			mine[path]["fresh"] = false
		else:
			drop_mine(path)


func get_mine(path: String) -> PackedByteArray:
	return CloudFiles.read_bytes(_mine_file(path))


func drop_mine(path: String) -> void:
	mine.erase(path)
	CloudFiles.remove_file(_mine_file(path))
