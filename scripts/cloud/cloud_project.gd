extends RefCounted
## S3 (DIDSA-CAD docs/shared-storage-scope.md sections 6 and 7, "DIDSA-VR (S3): a mirror folder"): ONE server project on this headset. The project's local copy is a plain, VISIBLE
## folder (the mirror: cloud_paths.gd) that the rest of the app reads and writes as any folder; this class keeps it level with the project store, with the same rules and
## the same words as the flat app's `RemoteStorageService` (DIDSA-CAD `client/lib/storage/server/`).
##
## What the mirror is, and what is kept elsewhere:
##   * Files in the mirror are the user's. project_save.gd writes there; a file DRAGGED IN or EDITED BY HAND there is a local change like any other. A file that is
##     MISSING from the mirror is only "not downloaded": it is NEVER a delete on the server (nothing in this class sends a delete).
##   * What each file was at the last sync (its version and hash), the queue of unsent saves, the change-feed cursor and the "mine" copies are in private storage
##     (cloud_state.gd), so deleting the mirror cannot delete the queue.
##
## The queue is found by SCANNING the mirror (scan()): every file whose SHA-256 differs from the hash it had at the last sync is a queued save. A new file is a queued
## create (base version null), a changed file a queued edit with the version it was based on as its base (the store's version check still catches a clash). Hash, not
## modified time alone: a file whose size and modified time match the last scan is trusted only if it was last changed before that scan, so a change made within the same
## second is still seen. The bytes sent are read once and what the store reports back is what is recorded, so a file that changes under a running sync is just a new
## queued edit at the next scan.
##
## The rules (S2's, kept):
##   * the base version of a file is the version it had when it was last synced; a file the open session holds (held_provider) is never refreshed under it, so a re-read
##     cannot move a base and a stale Part can never be saved over a newer version without a clash;
##   * a save is sent with a precondition: PUT with If-Match (a single file) or If-None-Match: * (a create), or ONE commit for several files (upload each, then POST commit,
##     all or nothing); a write with neither is a bug (428);
##   * 412 / 409 give a per-file clash with who changed it and when, and three choices (resolve()): Keep mine, Take theirs (mine kept locally until the next sync after the
##     one that finishes the resolution), Save mine as a copy ("<name> (<device>, <date>).didsa", a NEW Part id: cloud_remint.gd); a deleted or moved file is a clash too;
##   * an unreachable store queues the save and never loses it; 413 and 400 show the store's message, 401 names the key; a file over 100 MB that fails while the store
##     still answers may be the Cloudflare tunnel's limit (a file over 90 MB, or one a tunnel refuses, goes up in chunks that resume: S4; only an older store without uploads.chunked reports it); a save whose bytes equal the version it was read at is not sent;
##   * sync(): ask the change feed from the saved cursor first, flag queued saves it shows are now stale as clashes, refresh files others changed, then send the queue as
##     one commit. A refused cursor (400 bad_cursor) falls back to the tree.

const CloudFiles := preload("res://scripts/cloud/cloud_files.gd")
const CloudState := preload("res://scripts/cloud/cloud_state.gd")
const CloudRemint := preload("res://scripts/cloud/cloud_remint.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const FileIndex := preload("res://scripts/file_index.gd")

const TUNNEL_LIMIT := 100 * 1024 * 1024 ## a Cloudflare tunnel's documented request limit (free plan; not measured here)
const UPLOAD_KEEP_MS := 50 * 60 * 1000 ## the store keeps an upload an hour (and each chunk renews it)
const CHUNK_THRESHOLD := 90 * 1024 * 1024 ## S4: a file over this goes up in chunks (headroom under the tunnel's 100 MB request limit)
const CHUNK_BYTES := 32 * 1024 * 1024 ## ...of this size (the store's own advice, `chunk_size`, wins when it is smaller)
const CHUNK_RETRIES := 3 ## a chunk the store did not answer is retried this many times in a row before the sync gives up (the upload resumes next time)

signal changed ## the summary may have changed (a sync ended, a choice was made)

var client: RefCounted ## cloud_store_client.gd
var project := ""
var mirror_dir := ""
var state: RefCounted ## cloud_state.gd
var held_provider := Callable() ## () -> Array of mirror-relative paths the open session was composed from (never refreshed under it)
var clock := Callable() ## () -> unix time in ms (tests set it)
var online: Variant = null ## null: not tried yet, true, false
var auth_failed := false
var problems := {} ## path -> why the store would not take it (memory only; cleared by "Sync now")
var unsent_missing: Array = [] ## queued saves whose mirror file is gone (the warning)
var last_error := ""
var syncing := false
var tunnel_limit := TUNNEL_LIMIT ## tests lower it
var chunk_threshold := CHUNK_THRESHOLD ## tests lower these two
var chunk_bytes := CHUNK_BYTES

var _rerun := false
var _blocked := "" ## the queue contents a send failed for; not retried by the timer until they change
var _uploads := {} ## path -> {id, sha, at_ms}


func _init(p_client: RefCounted = null, p_project: String = "", p_mirror_dir: String = "", p_state: RefCounted = null) -> void:
	client = p_client
	project = p_project
	mirror_dir = p_mirror_dir
	state = p_state


# --- small helpers ------------------------------------------------------------------------------------------------------------------------

func now_ms() -> int:
	return int(clock.call()) if clock.is_valid() else int(Time.get_unix_time_from_system() * 1000.0)


func abs_path(rel: String) -> String:
	return mirror_dir.path_join(rel)


func _held() -> Dictionary:
	var out := {}
	if held_provider.is_valid():
		for rel in held_provider.call():
			out[str(rel)] = true
	return out


static func is_native_name(path: String) -> bool:
	return NativeCompose.native_extension(path) != ""


func _record(info: Dictionary) -> void:
	## A file as the store reports it is now both this device's synced copy and the newest listing. (The queue is NOT touched: see _record_sent.)
	var entry: Dictionary = CloudState.info_from_store(info)
	state.files[entry["path"]] = entry
	state.tree[entry["path"]] = entry.duplicate()
	state.behind.erase(entry["path"])
	state.stat.erase(entry["path"])


func _record_sent(info: Dictionary) -> void:
	## A queued save the store has taken: recorded, and off the queue.
	_record(info)
	state.queue.erase(str(info["path"]))
	problems.erase(str(info["path"]))
	_uploads.erase(str(info["path"]))
	state.uploads.erase(str(info["path"]))


func _set_tree(files: Array) -> void:
	state.tree.clear()
	for f in files:
		if f is Dictionary and f.has("path") and CloudFiles.is_mirrorable(str(f["path"])):
			state.tree[str(f["path"])] = CloudState.info_from_store(f)


func _mirror_clean(path: String) -> bool:
	## The mirror's file is exactly what was last synced (or is not there): safe to replace with a newer one.
	var full := abs_path(path)
	if not FileAccess.file_exists(full):
		return true
	var synced = state.files.get(path)
	return synced != null and CloudFiles.hash_file(full) == str(synced["sha256"])


# --- scan: the mirror's local changes become the queue ------------------------------------------------------------------------------------

func scan() -> Dictionary:
	## No network. {new: [paths], changed: [paths], reverted: [paths]}. See the class comment.
	var found := CloudFiles.list_files(mirror_dir)
	var result := {"new": [], "changed": [], "reverted": []}
	var dirty := false
	var hashed := false
	for rel in found:
		var full: String = found[rel]
		var size := CloudFiles.file_size(full)
		var mtime := FileAccess.get_modified_time(full)
		var cached = state.stat.get(rel)
		var sha := ""
		# The size / modified-time shortcut (kept across restarts, S4): the same size and mtime as when the file was hashed, and the file had been still for more than
		# a second by then (a write in the same second as the hash could leave both unchanged: git's "racy" rule). Anything else is hashed.
		if cached != null and int(cached["size"]) == size and int(cached["mtime"]) == mtime and mtime < int(cached["seen"]) - 1:
			sha = str(cached["sha"])
		else:
			sha = CloudFiles.hash_file(full)
			hashed = true
		if sha == "":
			continue # unreadable right now (being written?): the next scan sees it
		if cached == null or not (int(cached["size"]) == size and int(cached["mtime"]) == mtime and mtime < int(cached["seen"]) - 1):
			state.stat[rel] = {"size": size, "mtime": mtime, "sha": sha, "seen": int(Time.get_unix_time_from_system())} # (hashed just now)
		var synced = state.files.get(rel)
		if synced != null and sha == str(synced["sha256"]):
			if state.queue.has(rel):
				state.queue.erase(rel) # changed back to what was synced: nothing to send
				result["reverted"].append(rel)
				dirty = true
			continue
		var listed = state.tree.get(rel)
		if listed != null and sha == str(listed["sha256"]):
			state.files[rel] = (listed as Dictionary).duplicate() # these bytes ARE the store's current version (dragged in by hand, or the state was lost)
			state.queue.erase(rel)
			state.ignored.erase(rel)
			dirty = true
			continue
		if str(state.ignored.get(rel, "")) == sha:
			continue # kept local only, as the user chose; any further change queues it again
		state.ignored.erase(rel)
		var queued = state.queue.get(rel)
		if queued != null:
			if str(queued["sha"]) != sha:
				queued["sha"] = sha
				dirty = true
			continue
		state.queue[rel] = {"base": null if synced == null else int(synced["version"]), "queued_at_ms": now_ms(), "sha": sha, "clash": null, "reconciled": null}
		result["changed" if synced != null else "new"].append(rel)
		dirty = true
	for rel in state.stat.keys():
		if not found.has(rel):
			state.stat.erase(rel)
			dirty = true
	unsent_missing = []
	for rel in state.queue:
		if not found.has(rel):
			unsent_missing.append(rel)
	if dirty or hashed:
		state.save()
	return result


# --- reading the store: the feed first, the tree as the fallback -------------------------------------------------------------------------------

func _failure(answer: Dictionary, report: Dictionary) -> String:
	## "" when `answer` is ok; otherwise records why and returns "unreachable" or "error".
	if answer["ok"]:
		return ""
	if answer["kind"] == "unreachable":
		online = false
		report["reachable"] = false
		return "unreachable"
	online = true
	if answer["kind"] == "auth":
		auth_failed = true
		report["error"] = "The project store refused the key. Check the store key under Servers."
	else:
		report["error"] = str(answer["message"])
	last_error = str(report["error"])
	return "error"


func _pull(report: Dictionary) -> String:
	## Returns "", "unreachable" or "error". Updates the tree, the cursor, queued clashes and cached copies.
	var held := _held()
	if state.cursor == "":
		var first: Dictionary = await client.tree(project)
		var failed := _failure(first, report)
		if failed != "":
			return failed
		_set_tree(first["json"].get("files", []))
		state.cursor = str(first["json"].get("cursor", "0"))
		for path in state.queue: # a save that creates a file the store already has (state lost, or a file dropped in): a clash, before anything is sent
			var entry: Dictionary = state.queue[path]
			var listed = state.tree.get(path)
			if entry["base"] == null and listed != null and entry["clash"] == null:
				entry["clash"] = {"reason": "exists", "current_version": listed["version"], "deleted": false, "moved_to": null, "modified_by": listed["modified_by"], "modified_at": listed["modified_at"]}
		state.save()
		return ""
	var since: String = state.cursor
	var latest := {}
	var bad_cursor := false
	while true:
		var page: Dictionary = await client.changes(project, since)
		if not page["ok"]:
			if page["kind"] == "bad_request" and page["code"] == "bad_cursor":
				bad_cursor = true
				break
			return _failure(page, report)
		for change in page["json"].get("changes", []):
			latest[str(change["path"])] = change
		since = str(page["json"].get("cursor", since))
		if not bool(page["json"].get("more", false)):
			break
	if bad_cursor:
		# A cursor the store does not know (restored from a backup, say): compare with the whole tree instead.
		var whole: Dictionary = await client.tree(project)
		var failed2 := _failure(whole, report)
		if failed2 != "":
			return failed2
		_set_tree(whole["json"].get("files", []))
		latest = _changes_from_tree()
		since = str(whole["json"].get("cursor", "0"))
	elif _any_foreign(latest):
		var listing: Dictionary = await client.tree(project)
		var failed3 := _failure(listing, report)
		if failed3 != "":
			return failed3
		_set_tree(listing["json"].get("files", []))
	await _apply_changes(latest, held, report)
	state.cursor = since
	state.save()
	return ""


func _any_foreign(latest: Dictionary) -> bool:
	## Whether the feed shows a change this device does not already have (its own sends are already in the listing it keeps), so the tree is fetched only for those.
	for path in latest:
		var change: Dictionary = latest[path]
		var have = state.files.get(path)
		if str(change.get("op", "put")) != "put" or have == null or int(have["version"]) != int(change.get("version", 0)):
			return true
	return false


func _changes_from_tree() -> Dictionary:
	## What the feed would have said, worked out by comparing the new tree with what this device has (the bad-cursor fallback).
	var out := {}
	for path in state.tree:
		var listed: Dictionary = state.tree[path]
		var queued = state.queue.get(path)
		var have = state.files.get(path)
		var differs := false
		if queued != null:
			differs = queued["base"] == null or int(queued["base"]) != int(listed["version"])
		elif have != null:
			differs = int(have["version"]) != int(listed["version"])
		if differs:
			out[path] = {"path": path, "op": "put", "version": int(listed["version"]), "device": listed["modified_by"], "at": listed["modified_at"]}
	for path in state.files:
		if not state.tree.has(path):
			var queued2 = state.queue.get(path)
			if queued2 == null or queued2["base"] != null:
				out[path] = {"path": path, "op": "delete", "version": int(state.files[path]["version"]) + 1, "device": "", "at": ""}
	return out


func _apply_changes(latest: Dictionary, held: Dictionary, report: Dictionary) -> void:
	for path in latest:
		if not CloudFiles.is_mirrorable(str(path)):
			continue
		var change: Dictionary = latest[path]
		var version := int(change.get("version", 0))
		var have = state.files.get(path)
		if have != null and int(have["version"]) == version and str(change.get("op", "put")) == "put":
			continue # this device's own save (or a change it already has)
		var queued = state.queue.get(path)
		var is_put := str(change.get("op", "put")) == "put"
		if queued != null:
			var seen := maxi(0 if queued["base"] == null else int(queued["base"]), 0 if queued["reconciled"] == null else int(queued["reconciled"]))
			if queued["clash"] == null and version > seen:
				queued["clash"] = {
					"reason": ("exists" if queued["base"] == null else "changed") if is_put else "deleted",
					"current_version": version, "deleted": not is_put,
					"moved_to": change.get("moved_to"), "modified_by": str(change.get("device", "")), "modified_at": str(change.get("at", "")),
				}
			continue
		if have == null:
			continue # not downloaded here: the tree knows it, nothing to refresh
		if held.has(path):
			state.behind[path] = version # the open session holds it: left as it is (a save of it will clash, which is the point)
			continue
		if is_put:
			if not _mirror_clean(path):
				continue # changed here since the scan: the next scan queues it
			var fetched := await _download(path)
			if fetched["ok"]:
				report["refreshed"].append(path)
		else:
			if _mirror_clean(path):
				CloudFiles.remove_file(abs_path(path)) # the store removed it; this copy was its last version, still in the store's history
				state.files.erase(path)
				state.tree.erase(path)
				state.stat.erase(path)


func _download(path: String) -> Dictionary:
	## Fetches one file into the mirror and records it as synced. {ok, message, kind}. A file with an unsent save is never fetched over (the mirror file is the save).
	if not CloudFiles.is_mirrorable(path):
		return {"ok": false, "kind": "error", "message": "\"%s\" is not a path that can be copied to this headset." % path}
	if state.queue.has(path):
		return {"ok": false, "kind": "error", "message": "%s has a save that is not on the server yet." % path.get_file()}
	var got: Dictionary = await client.get_file(project, path)
	if not got["ok"]:
		if got["kind"] == "unreachable":
			online = false
		return got
	online = true
	var bytes: PackedByteArray = got["body"]
	var sha := CloudFiles.hash_bytes(bytes)
	if str(got.get("sha256", "")) != "" and str(got["sha256"]) != sha:
		return {"ok": false, "kind": "error", "message": "%s arrived damaged (its hash is not the store's); try again." % path.get_file()}
	var wrote := CloudFiles.write_bytes_atomic(abs_path(path), bytes)
	if wrote != "":
		return {"ok": false, "kind": "error", "message": wrote}
	var listed = state.tree.get(path)
	var info := {"path": path, "version": int(got["version"]), "sha256": sha, "size": bytes.size(),
		"modified_at": "" if listed == null else listed["modified_at"], "modified_by": "" if listed == null else listed["modified_by"],
		"part_id": null if listed == null else listed["part_id"]}
	_record(info)
	return {"ok": true, "kind": "ok", "message": "", "bytes": bytes}


# --- sync ------------------------------------------------------------------------------------------------------------------------------

func sync(force: bool = false) -> Dictionary:
	## Brings this device and the store level: scan, the change feed from the saved cursor, then the queue as one commit. `force` is "Sync now": it forgets what the timer
	## was holding back and tries again. Never fails for an unreachable store (the report says so); a clash is in the report and flagged on the queued save.
	## Returns {busy, reachable, sent: [paths], conflicts: [..], refreshed: [paths], error, warnings: [text]}.
	if syncing:
		_rerun = true
		return {"busy": true, "reachable": online != false, "sent": [], "conflicts": [], "refreshed": [], "error": "", "warnings": []}
	syncing = true
	var report: Dictionary = await _sync_once(force)
	while _rerun:
		_rerun = false
		report = await _sync_once(false)
	syncing = false
	changed.emit()
	return report


func _sync_once(force: bool) -> Dictionary:
	var report := {"busy": false, "reachable": true, "sent": [], "conflicts": [], "refreshed": [], "error": "", "warnings": []}
	scan()
	if force:
		_blocked = ""
		problems.clear()
	if client == null or not client.is_configured():
		report["reachable"] = false
		report["error"] = "No project store address or key is set (Servers page)."
		return report
	var pulled: String = await _pull(report)
	if pulled != "":
		state.save()
		return report
	online = true
	auth_failed = false
	last_error = ""
	_adopt_equal()
	var clashes := conflicts()
	if not clashes.is_empty():
		report["conflicts"] = clashes
		state.save()
		return report
	await _push(report)
	report["conflicts"] = conflicts()
	if not unsent_missing.is_empty():
		report["warnings"].append("%d unsent save%s %s no file in the local copy any more: %s" % [unsent_missing.size(), "" if unsent_missing.size() == 1 else "s", "has" if unsent_missing.size() == 1 else "have", ", ".join(PackedStringArray(unsent_missing))])
	state.save()
	return report


func _adopt_equal() -> void:
	## A queued save whose bytes equal the store's current version is not sent: it IS that version.
	for path in state.queue.keys():
		var listed = state.tree.get(path)
		if listed != null and str(state.queue[path]["sha"]) == str(listed["sha256"]):
			state.files[path] = (listed as Dictionary).duplicate()
			state.queue.erase(path)
			state.uploads.erase(path)


func _signature(paths: Array) -> String:
	var parts := []
	for path in paths:
		parts.append("%s=%s" % [path, state.queue[path]["sha"]])
	parts.sort()
	return "|".join(PackedStringArray(parts))


func _push(report: Dictionary) -> void:
	var entries: Array = []
	for path in state.queue:
		if FileAccess.file_exists(abs_path(path)):
			entries.append(path)
	entries.sort()
	if entries.is_empty():
		if state.queue.is_empty():
			state.age_mine()
			state.last_synced_ms = now_ms()
		return
	var signature := _signature(entries)
	if signature == _blocked:
		report["error"] = last_error
		return
	var outcome: Dictionary
	if entries.size() == 1 and CloudFiles.file_size(abs_path(entries[0])) <= chunk_threshold:
		outcome = await _send_single(entries[0])
	else:
		outcome = await _send_commit(entries)
	for path in outcome.get("sent", []):
		report["sent"].append(path)
	if str(outcome.get("error", "")) != "":
		report["error"] = outcome["error"]
		last_error = outcome["error"]
		if bool(outcome.get("block", false)):
			_blocked = signature
	if outcome.get("unreachable", false):
		report["reachable"] = false
	if state.queue.is_empty():
		state.age_mine()
		state.last_synced_ms = now_ms()
		_blocked = ""


func _send_single(path: String) -> Dictionary:
	var entry: Dictionary = state.queue[path]
	var bytes := CloudFiles.read_bytes(abs_path(path))
	var base := -1 if entry["base"] == null else int(entry["base"])
	var answer: Dictionary = await client.put_file(project, path, bytes, base)
	if answer["ok"]:
		online = true
		var info: Dictionary = answer["json"]
		info["path"] = path
		_record_sent(info)
		return {"sent": [path]}
	if answer["kind"] == "stale":
		online = true
		entry["clash"] = clash_from_current(answer["current"], entry["base"] == null)
		return {"error": "%s changed on the server." % path.get_file()}
	if answer["kind"] == "too_large" and not answer["from_store"]:
		return await _send_commit([path]) # something in front of the store refused the body: the commit path can send it in pieces
	return await _send_failed(answer, [path], bytes.size())


func _send_commit(entries: Array) -> Dictionary:
	var retried := false
	while true:
		var changes: Array = []
		var biggest := 0
		for path in entries:
			var size := CloudFiles.file_size(abs_path(path))
			biggest = maxi(biggest, size)
			var up: Dictionary = await _upload_file(path, size)
			if not up["ok"]:
				return await _send_failed(up, [path], size)
			var upload_id := str(up["upload_id"])
			var base = state.queue[path]["base"]
			changes.append({"op": "put", "path": path, "base_version": base, "upload_id": upload_id})
		var answer: Dictionary = await client.commit(project, changes)
		if answer["ok"]:
			online = true
			var sent: Array = []
			for info in answer["json"].get("files", []):
				if info is Dictionary and info.has("path"):
					_record_sent(info)
					sent.append(str(info["path"]))
			return {"sent": sent}
		if answer["kind"] == "conflict" and not answer["conflicts"].is_empty():
			online = true
			for conflict in answer["conflicts"]:
				var queued = state.queue.get(str(conflict.get("path", "")))
				if queued != null:
					queued["clash"] = clash_from_conflict(conflict)
			return {"error": "%d file%s changed on the server; nothing was saved there." % [answer["conflicts"].size(), "" if answer["conflicts"].size() == 1 else "s"]}
		if answer["kind"] == "bad_request" and answer["code"] == "unknown_upload" and not retried:
			retried = true
			_uploads.clear() # an upload expired (the store keeps them an hour): upload everything again, once
			state.uploads.clear()
			continue
		return await _send_failed(answer, entries, biggest)
	return {}


func _upload_file(path: String, size: int) -> Dictionary:
	## The bytes of one queued file are on the store, ready for a commit: {ok, upload_id}, or a failed store answer. A file up to `chunk_threshold` goes in one request (kept for
	## the hour, so a commit that has to be sent again does not upload again); a bigger one, or one a tunnel refused, in chunks (S4), resuming where the store says it got to.
	var full := abs_path(path)
	if size > chunk_threshold:
		return await _upload_chunked(path, size, CloudFiles.hash_file(full))
	var bytes := CloudFiles.read_bytes(full)
	var sha := CloudFiles.hash_bytes(bytes)
	var known = _uploads.get(path)
	if known != null and str(known["sha"]) == sha and now_ms() - int(known["at_ms"]) < UPLOAD_KEEP_MS:
		return {"ok": true, "upload_id": str(known["id"])}
	var up: Dictionary = await client.upload(project, bytes)
	if not up["ok"]:
		if up["kind"] == "too_large" and not up["from_store"]:
			var chunked: Dictionary = await _upload_chunked(path, bytes.size(), sha) # a tunnel with a lower limit than we thought: try chunks
			if chunked["ok"] or chunked["kind"] != "no_chunking":
				return chunked
		return up
	_uploads[path] = {"id": str(up["json"]["upload_id"]), "sha": sha, "at_ms": now_ms()}
	return {"ok": true, "upload_id": str(up["json"]["upload_id"])}


func _upload_chunked(path: String, size: int, sha: String) -> Dictionary:
	## Chunked upload with resume. The session (id, hash, size) is kept in the private state before the first chunk, so a cut connection, a store that was switched off, or the
	## app being closed all end the same way: next time the store is asked how far it got (`received`) and only the rest is sent. A changed file (another hash) starts over.
	if sha == "":
		return _failed_answer("error", "%s can't be read right now." % path.get_file())
	var health: Dictionary = await client.health()
	if health["kind"] == "unreachable":
		return health
	if not "uploads.chunked" in _features(health):
		return _failed_answer("no_chunking", "This project store is too old for uploads over 100 MB (it does not list uploads.chunked).")
	var id := ""
	var received := 0
	var known = state.uploads.get(path)
	if known != null and str(known["sha"]) == sha and int(known["size"]) == size and now_ms() - int(known["at_ms"]) < UPLOAD_KEEP_MS:
		var status: Dictionary = await client.upload_status(project, str(known["id"]))
		if status["ok"]:
			id = str(known["id"])
			received = int(status["json"].get("received", 0))
			if bool(status["json"].get("complete", false)):
				return {"ok": true, "upload_id": id}
		elif status["kind"] != "not_found":
			return status # unreachable and the like: the session stays saved
	if id == "":
		state.uploads.erase(path)
		var made: Dictionary = await client.upload_session(project, size, sha)
		if not made["ok"]:
			return made
		id = str(made["json"]["upload_id"])
		var advised := int(made["json"].get("chunk_size", chunk_bytes))
		state.uploads[path] = {"id": id, "sha": sha, "size": size, "at_ms": now_ms()}
		state.save()
		if advised > 0 and advised < chunk_bytes:
			chunk_bytes = advised
	var file := FileAccess.open(abs_path(path), FileAccess.READ)
	if file == null or file.get_length() != size:
		return _failed_answer("error", "%s changed while it was being sent; it will be tried again." % path.get_file())
	var failures := 0
	while received < size:
		file.seek(received)
		var piece := file.get_buffer(mini(chunk_bytes, size - received))
		var answer: Dictionary = await client.upload_chunk(project, id, received, piece)
		if answer["ok"]:
			failures = 0
			received += piece.size()
			state.uploads[path]["at_ms"] = now_ms()
			continue
		if answer["kind"] == "conflict" and answer["code"] == "wrong_offset":
			var there := int(answer["json"].get("received", 0)) # a reply was lost: the store says where it really is
			failures += 1 if there == received or there > size else 0 # (a store that keeps refusing the offset it names is not going to agree: give up, never loop)
			if failures >= CHUNK_RETRIES:
				return _failed_answer("error", "The project store and this headset disagree about how much of %s was uploaded; it will be tried again." % path.get_file())
			received = clampi(there, 0, size)
			continue
		if answer["kind"] == "unreachable" and failures < CHUNK_RETRIES - 1:
			failures += 1
			continue
		if answer["kind"] == "not_found":
			state.uploads.erase(path) # it expired: the next attempt starts a new one
		return answer
	state.uploads[path]["at_ms"] = now_ms()
	state.save()
	var done: Dictionary = await client.upload_complete(project, id)
	if done["ok"]:
		return {"ok": true, "upload_id": id}
	if done["kind"] == "bad_request" or done["kind"] == "not_found":
		state.uploads.erase(path) # damaged on the way, or gone: the upload cannot be repaired, the next attempt starts again
		state.save()
	return done


static func _features(health: Dictionary) -> Array:
	var list = health["json"].get("api_features", []) if health["ok"] else []
	return list if list is Array else []


static func _failed_answer(kind: String, message: String) -> Dictionary:
	return {"ok": false, "kind": kind, "message": message, "from_store": false, "code": "", "status": 0, "json": {}}


func _send_failed(answer: Dictionary, paths: Array, size: int) -> Dictionary:
	## A store answer that is not success and not a clash. The queue is kept as it is: nothing is lost.
	var kind: String = answer["kind"]
	if kind == "unreachable":
		if size > tunnel_limit and await _answers_without_chunking():
			return _problem(paths, "%s is %s. A server behind a Cloudflare tunnel can refuse an upload over 100 MB, and this project store cannot take it in pieces. The file was not saved to the server; it stays in the local copy." % [str(paths[0]).get_file(), size_text(size)])
		online = false
		return {"unreachable": true}
	online = true
	match kind:
		"no_chunking":
			return _problem(paths, "%s is %s. %s The file was not saved to the server; it stays in the local copy until you update the store." % [str(paths[0]).get_file(), size_text(size), answer["message"]])
		"error":
			if answer["status"] == 0:
				return {"error": answer["message"]} # not a store refusal (a file that changed while being read): tried again at the next sync
		"auth":
			auth_failed = true
			return {"error": "The project store refused the key (401). Check the store key under Servers."}
		"too_large":
			var said: String = ("It says: %s. " % answer["message"]) if answer["from_store"] else "Something in front of it (a tunnel?) refused it. "
			return _problem(paths, "%s is %s, which is too large for the project store. %sThe file was not saved to the server; it stays in the local copy until you choose Keep local only." % [str(paths[0]).get_file(), size_text(size), said])
		"bad_request":
			return _problem(paths, "The project store refused this save: %s" % answer["message"])
		"precondition_required":
			return _problem(paths, "The project store wanted to know which version a save replaces (a bug in this app): %s" % answer["message"])
	return _problem(paths, "The project store answered %d: %s" % [answer["status"], answer["message"]])


func _problem(paths: Array, message: String) -> Dictionary:
	for path in paths:
		problems[path] = message
	return {"error": message, "block": true}


func _answers_without_chunking() -> bool:
	## The store answers but cannot take a big file in pieces: then a failed upload of a file over the tunnel's limit is most likely the tunnel (a store that CAN chunk gets
	## the file in chunks instead, so this message would be wrong for it).
	var health: Dictionary = await client.health()
	return health["kind"] != "unreachable" and not "uploads.chunked" in _features(health)


func _server_answers() -> bool:
	var health: Dictionary = await client.health()
	return health["kind"] != "unreachable"


static func size_text(bytes: int) -> String:
	return "%d MB" % int(round(bytes / 1048576.0)) if bytes >= 1048576 else "%d KB" % int(round(bytes / 1024.0))


# --- clashes -------------------------------------------------------------------------------------------------------------------------------

static func clash_from_current(current: Dictionary, base_was_create: bool) -> Dictionary:
	## From a 412's `current`: the live file, or {deleted: true, version, moved_to?}, or nothing (the file does not exist). reason: changed | exists | deleted | missing.
	if current.is_empty():
		return {"reason": "missing", "current_version": null, "deleted": false, "moved_to": null, "modified_by": "", "modified_at": ""}
	var deleted: bool = bool(current.get("deleted", false))
	return {
		"reason": "deleted" if deleted else ("exists" if base_was_create else "changed"),
		"current_version": null if current.get("version") == null else int(current["version"]),
		"deleted": deleted, "moved_to": current.get("moved_to"),
		"modified_by": str(current.get("modified_by", "")), "modified_at": str(current.get("modified_at", "")),
	}


static func clash_from_conflict(conflict: Dictionary) -> Dictionary:
	## From one entry of a commit 409's `conflicts` ({path, op, base_version, reason, current_version, current}).
	var current = conflict.get("current")
	var base := clash_from_current(current if current is Dictionary else {}, conflict.get("base_version") == null)
	var reason := str(conflict.get("reason", "changed"))
	base["reason"] = reason
	if base["current_version"] == null and conflict.get("current_version") != null:
		base["current_version"] = int(conflict["current_version"])
	base["deleted"] = bool(base["deleted"]) or reason == "deleted"
	return base


func conflicts() -> Array:
	## [{path, clash, queued_at_ms, text}] for every queued save the store would not take as it stands.
	var out: Array = []
	var paths: Array = state.queue.keys()
	paths.sort()
	for path in paths:
		var entry: Dictionary = state.queue[path]
		if entry["clash"] != null:
			out.append({"path": path, "clash": entry["clash"], "queued_at_ms": entry["queued_at_ms"], "text": describe_clash(path, entry["clash"])})
	return out


static func format_when(iso: String) -> String:
	## "2026-11-13 14:05" in this device's local time ("" when there is none).
	if iso == "":
		return ""
	var unix := Time.get_unix_time_from_datetime_string(iso.replace("Z", "").substr(0, 19))
	if unix <= 0:
		return iso.substr(0, 16).replace("T", " ")
	var local := int(unix) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(local, true).substr(0, 16)


static func describe_clash(path: String, clash: Dictionary) -> String:
	## "Changed by Desktop on 2026-11-13 14:05", "Deleted by Quest 3", "Renamed to Shaft-v2.didsa by Desktop", "A file with this name was added by Phone".
	var who := str(clash.get("modified_by", ""))
	var by := "another device" if who == "" else who
	var when := format_when(str(clash.get("modified_at", "")))
	var on := "" if when == "" else " on " + when
	var reason := str(clash.get("reason", "changed"))
	if reason == "path_conflict":
		return "A file or folder is already in the way of %s" % path
	if reason == "missing":
		return "The server has no file with this name any more"
	if bool(clash.get("deleted", false)):
		var moved = clash.get("moved_to")
		return ("Deleted by %s%s" % [by, on]) if moved == null or str(moved) == "" else ("Renamed to %s by %s%s" % [moved, by, on])
	if reason == "exists":
		return "A file with this name was added by %s%s" % [by, on]
	return "Changed by %s%s" % [by, on]


# --- the choices ---------------------------------------------------------------------------------------------------------------------------

const KEEP_MINE := "keep_mine"
const TAKE_THEIRS := "take_theirs"
const SAVE_COPY := "save_copy"


static func conflict_copy_path(path: String, device: String, date: Dictionary, taken: Callable) -> String:
	## `parts/Shaft.didsa` -> `parts/Shaft (Desktop, 2026-11-13).didsa`; a number is added while `taken` says the name is used. The copy is always `.didsa`.
	var slash := path.rfind("/")
	var folder := "" if slash < 0 else path.substr(0, slash + 1)
	var name := path if slash < 0 else path.substr(slash + 1)
	for ext in [".didsa", ".DIDSAprt", ".didsacad", ".didsa.json"]:
		if name.to_lower().ends_with(ext.to_lower()):
			name = name.substr(0, name.length() - ext.length())
			break
	var who := device
	for bad in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]:
		who = who.replace(bad, "")
	who = who.strip_edges()
	if who == "":
		who = "device"
	var stamp := "%04d-%02d-%02d" % [int(date.get("year", 1970)), int(date.get("month", 1)), int(date.get("day", 1))]
	var base := "%s%s (%s, %s)" % [folder, name, who, stamp]
	var candidate := base + ".didsa"
	var n := 2
	while taken.call(candidate):
		candidate = "%s %d.didsa" % [base, n]
		n += 1
	return candidate


func resolve(choices: Dictionary) -> Dictionary:
	## `choices`: path -> KEEP_MINE | TAKE_THEIRS | SAVE_COPY, for the paths to settle (others stay as they are). Does not send: call sync() after, which sends the whole queue
	## as one commit. Take theirs and Save a copy need the store (theirs is fetched first; nothing changes if that fails).
	## Returns {ok, error, reload: bool (the open session no longer matches: offer to reopen), copies: {original -> copy path}}.
	var result := {"ok": true, "error": "", "reload": false, "copies": {}}
	for path in choices:
		var entry = state.queue.get(path)
		if entry == null:
			continue
		var clash = entry["clash"]
		match str(choices[path]):
			KEEP_MINE:
				if clash != null and str(clash["reason"]) == "path_conflict":
					result["ok"] = false
					result["error"] = "Keep mine is not possible for %s: a file or folder is in the way." % path
					return result
				if clash != null: # (with no clash there is nothing to re-base on: the save stays as it is)
					entry["base"] = null if (bool(clash["deleted"]) or str(clash["reason"]) == "missing") else clash["current_version"]
					entry["reconciled"] = clash["current_version"] # the feed reporting that same change is not a new clash
				entry["clash"] = null
				_blocked = ""
			TAKE_THEIRS:
				var failure := await _take_theirs(path, clash, result, false)
				if failure != "":
					result["ok"] = false
					result["error"] = failure
					return result
			SAVE_COPY:
				var failure2 := await _take_theirs(path, clash, result, true)
				if failure2 != "":
					result["ok"] = false
					result["error"] = failure2
					return result
	state.save()
	changed.emit()
	return result


func _take_theirs(path: String, clash, result: Dictionary, as_copy: bool) -> String:
	## "" on success, else why not (nothing is changed when theirs cannot be fetched).
	var full := abs_path(path)
	var mine := CloudFiles.read_bytes(full)
	var gone: bool = clash != null and (bool(clash["deleted"]) or str(clash["reason"]) == "missing")
	var theirs := PackedByteArray()
	var theirs_info := {}
	if not gone and not (clash != null and str(clash["reason"]) == "path_conflict"):
		var got: Dictionary = await client.get_file(project, path)
		if not got["ok"]:
			if got["kind"] == "unreachable":
				online = false
				return "Taking theirs needs the project store, and it can't be reached."
			if got["kind"] == "not_found":
				gone = true # it went away since the refusal: the same as theirs being a delete
			else:
				return str(got["message"])
		else:
			theirs = got["body"]
			var listed = state.tree.get(path)
			theirs_info = {"path": path, "version": int(got["version"]), "sha256": CloudFiles.hash_bytes(theirs), "size": theirs.size(),
				"modified_at": str(clash.get("modified_at", "")) if clash != null else "", "modified_by": str(clash.get("modified_by", "")) if clash != null else "",
				"part_id": null if listed == null else listed["part_id"]}
	if as_copy:
		if mine.is_empty():
			return "There is no local file to copy for %s." % path
		var device: String = client.device_name
		var copy_path := conflict_copy_path(path, device, Time.get_datetime_dict_from_system(), func(candidate: String) -> bool:
			return FileAccess.file_exists(abs_path(candidate)) or state.tree.has(candidate) or state.queue.has(candidate))
		var wrote := CloudFiles.write_bytes_atomic(abs_path(copy_path), CloudRemint.remint_bytes(mine))
		if wrote != "":
			return wrote
		result["copies"][path] = copy_path
		state.queue[copy_path] = {"base": null, "queued_at_ms": now_ms(), "sha": "", "clash": null, "reconciled": null} # (the scan below fills the hash)
	else:
		var kept: String = state.put_mine(path, mine, now_ms())
		if kept != "":
			return kept
	if gone:
		CloudFiles.remove_file(full)
		state.files.erase(path)
		state.tree.erase(path)
		state.stat.erase(path)
	elif not theirs_info.is_empty():
		var wrote2 := CloudFiles.write_bytes_atomic(full, theirs)
		if wrote2 != "":
			return wrote2
		state.files[path] = CloudState.info_from_store(theirs_info)
		state.tree[path] = CloudState.info_from_store(theirs_info)
		state.stat.erase(path)
	state.queue.erase(path)
	state.behind.erase(path)
	problems.erase(path)
	result["reload"] = true
	_blocked = ""
	if as_copy:
		scan() # the copy is a new file: the scan queues it with its hash
	return ""


func keep_local_only(path: String) -> void:
	## A save the store will not take (too large, a refused name): stop trying. The file stays in the mirror; any further change queues it again.
	var entry = state.queue.get(path)
	if entry == null:
		return
	state.ignored[path] = str(entry["sha"])
	state.queue.erase(path)
	problems.erase(path)
	_blocked = ""
	state.save()
	changed.emit()


func kept_copies() -> Array:
	var paths: Array = state.mine.keys()
	paths.sort()
	return paths


func restore_kept_as_file(path: String) -> Dictionary:
	## Puts a "mine" copy kept after Take theirs back as a file of its own (a new Part id), queued to send. {ok, error, path}.
	var bytes: PackedByteArray = state.get_mine(path)
	if bytes.is_empty():
		return {"ok": false, "error": "No kept copy of %s." % path, "path": ""}
	var copy_path := conflict_copy_path(path, client.device_name, Time.get_datetime_dict_from_system(), func(candidate: String) -> bool:
		return FileAccess.file_exists(abs_path(candidate)) or state.tree.has(candidate) or state.queue.has(candidate))
	var wrote := CloudFiles.write_bytes_atomic(abs_path(copy_path), CloudRemint.remint_bytes(bytes))
	if wrote != "":
		return {"ok": false, "error": wrote, "path": ""}
	state.drop_mine(path)
	scan()
	state.save()
	changed.emit()
	return {"ok": true, "error": "", "path": copy_path}


# --- opening: download what is needed -----------------------------------------------------------------------------------------------------

func ensure_file(path: String) -> Dictionary:
	## The file in the mirror, downloaded if it is not there. {ok, downloaded, message}. A file already in the mirror is not fetched again (a re-read must not move its base).
	if FileAccess.file_exists(abs_path(path)):
		return {"ok": true, "downloaded": false, "message": ""}
	if online == false and state.tree.has(path) == false:
		return {"ok": false, "downloaded": false, "message": "%s is not on this headset and the project store can't be reached." % path.get_file()}
	var got: Dictionary = await _download(path)
	if got["ok"]:
		changed.emit()
		return {"ok": true, "downloaded": true, "message": ""}
	var why: String = str(got["message"])
	if got["kind"] == "unreachable":
		why = "%s is not on this headset yet and the project store can't be reached." % path.get_file()
	elif got["kind"] == "auth":
		auth_failed = true
		why = "The project store refused the key. Check the store key under Servers."
	return {"ok": false, "downloaded": false, "message": why}


func prepare_open(root_path: String) -> Dictionary:
	## Downloads `root_path` and every file its occurrences reference, so native_compose.gd (which reads the mirror UNCHANGED) finds them. A reference that does not
	## resolve by its path is looked up in the store's part-id index (GET .../parts/{id}, the moved-files rule against the store), not by reading files.
	## {ok, downloaded: [paths], missing: [paths], error}.
	var result := {"ok": true, "downloaded": [], "missing": [], "error": ""}
	var root_dir := root_path.get_base_dir() if "/" in root_path else ""
	var todo: Array = [root_path]
	var seen := {}
	while not todo.is_empty():
		var path: String = todo.pop_front()
		if seen.has(path):
			continue
		seen[path] = true
		var got: Dictionary = await ensure_file(path)
		if not got["ok"]:
			if path == root_path:
				result["ok"] = false
				result["error"] = got["message"]
				return result
			result["missing"].append(path)
			continue
		if got["downloaded"]:
			result["downloaded"].append(path)
		if not is_native_name(path):
			continue
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(abs_path(path)))
		if not (parsed is Dictionary) or not (parsed.get("document") is Dictionary):
			continue
		for part in parsed["document"].get("parts", []):
			if not (part is Dictionary) or not (part.get("occurrences") is Array):
				continue
			for occ in part["occurrences"]:
				if not (occ is Dictionary):
					continue
				var ref := str(occ.get("external_ref", "")).strip_edges().replace("\\", "/")
				if ref == "" or ref.begins_with("/"):
					continue
				var wanted: Array = await _locate_reference(root_dir, ref, NativeCompose.ref_part_id_of(occ))
				if wanted.is_empty():
					result["missing"].append(ref)
				for w in wanted:
					todo.append(w)
	return result


func _normalise(base: String, ref: String) -> String:
	var parts: Array = []
	for segment in (base + "/" + ref if base != "" else ref).split("/", false):
		if segment == ".":
			continue
		if segment == "..":
			if parts.is_empty():
				return ""
			parts.pop_back()
		else:
			parts.append(segment)
	return "/".join(PackedStringArray(parts))


func _find_known(candidate: String) -> String:
	## `candidate` if the mirror or the store's listing has it, else a native file in the same folder with the same name once the extension and letter case are set aside
	## (native_compose.gd's rule), else "".
	if candidate == "":
		return ""
	if FileAccess.file_exists(abs_path(candidate)) or state.tree.has(candidate):
		return candidate
	if not is_native_name(candidate):
		return ""
	var folder := candidate.get_base_dir() if "/" in candidate else ""
	var key := NativeCompose.base_name_key(candidate.get_file())
	for path in state.tree:
		if (path.get_base_dir() if "/" in path else "") == folder and is_native_name(path) and NativeCompose.base_name_key(path.get_file()) == key:
			return path
	var found := CloudFiles.list_files(mirror_dir)
	for path in found:
		if (path.get_base_dir() if "/" in path else "") == folder and is_native_name(path) and NativeCompose.base_name_key(path.get_file()) == key:
			return path
	return ""


func _part_id_known(path: String) -> String:
	if FileAccess.file_exists(abs_path(path)):
		var local := FileIndex.read_part_id(abs_path(path))
		if local != "":
			return local
	var listed = state.tree.get(path)
	return "" if listed == null or listed["part_id"] == null else str(listed["part_id"])


func _locate_reference(root_dir: String, ref: String, ref_id: String) -> Array:
	## The store paths to bring into the mirror for one reference: the file at its path (when it is the placed part), else the files the store's part index names.
	var at_path: Array = []
	for base in [root_dir, ""]:
		var hit := _find_known(_normalise(base, ref))
		if hit != "" and not at_path.has(hit):
			at_path.append(hit)
	if ref_id == "":
		return at_path.slice(0, 1)
	for hit in at_path:
		var have := _part_id_known(hit)
		if have == "" or have == ref_id:
			return [hit]
	# The path found nothing, or found a different part: the moved-files rule, answered by the store's part index.
	var by_id: Array = []
	var answer := {"ok": false, "kind": "unreachable"}
	if online != false:
		answer = await client.parts(project, ref_id)
	if answer["ok"]:
		online = true
		for f in answer["json"].get("files", []):
			by_id.append(str(f["path"]))
	else:
		if answer["kind"] == "unreachable":
			online = false
		for path in state.tree: # offline: the listing's own part ids
			if state.tree[path]["part_id"] != null and str(state.tree[path]["part_id"]) == ref_id:
				by_id.append(path)
	for hit in at_path:
		if not by_id.has(hit):
			by_id.append(hit) # the wrong file at the path is brought too, so the lookup sees what it saw before
	return by_id


# --- what the Files page shows -------------------------------------------------------------------------------------------------------------

func file_state(path: String) -> String:
	## "clash" | "to_send" | "cloud" (in the store, not downloaded) | "local_only" (kept local) | "synced"
	var entry = state.queue.get(path)
	if entry != null:
		return "clash" if entry["clash"] != null else "to_send"
	if state.ignored.has(path):
		return "local_only"
	if not FileAccess.file_exists(abs_path(path)):
		return "cloud"
	return "synced"


func entries() -> Array:
	## Every file the project has, here or in the store: [{path, state, local, size, native, part_id}], sorted by path. No hashing (the list must be cheap); a change made
	## by hand shows as "to send" after the next scan.
	var found := CloudFiles.list_files(mirror_dir)
	var paths := {}
	for path in found:
		paths[path] = true
	for path in state.tree:
		paths[path] = true
	for path in state.queue:
		paths[path] = true
	var out: Array = []
	var sorted := paths.keys()
	sorted.sort()
	for path in sorted:
		var listed = state.tree.get(path)
		out.append({"path": path, "state": file_state(path), "local": found.has(path), "native": is_native_name(path),
			"size": CloudFiles.file_size(found[path]) if found.has(path) else (0 if listed == null else int(listed["size"])),
			"part_id": null if listed == null else listed["part_id"]})
	return out


func summary() -> Dictionary:
	## {symbol: "synced" | "to_send" | "clash" | "offline", online, to_send, clash, missing: [paths], problems, kept, local_only, auth_failed, last_synced_ms}.
	var to_send := 0
	var clash := 0
	for path in state.queue:
		if state.queue[path]["clash"] != null:
			clash += 1
		else:
			to_send += 1
	var symbol := "synced"
	if clash > 0:
		symbol = "clash"
	elif online == false or auth_failed:
		symbol = "offline"
	elif to_send > 0:
		symbol = "to_send"
	return {"symbol": symbol, "online": online, "to_send": to_send, "clash": clash, "missing": unsent_missing.duplicate(), "problems": problems.duplicate(),
		"kept": state.mine.size(), "local_only": state.ignored.size(), "auth_failed": auth_failed, "last_synced_ms": state.last_synced_ms}
