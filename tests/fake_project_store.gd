extends RefCounted
## An in-memory stand-in for DIDSA-CAD's project store (`project-store/`), speaking the same HTTP shapes through the `request()` transport interface of
## scripts/cloud/cloud_store_client.gd, so the sync layer can be driven headless with no network (as tests/fake_appearance_api.gd and the FakeTool in
## tests/mates_suggested_type.gd fake the backend). Modelled on the real store's api.py / store.py and on the flat app's test/support/fake_project_store.dart:
##
##   * every call needs X-API-Key (401 otherwise), X-Device-Name is recorded as "modified by";
##   * a PUT needs If-Match: "<v>" or If-None-Match: * (428 otherwise); a stale one is 412 with `current`; a save that changes nothing makes no new version;
##   * a commit is all or nothing: 409 with every clash (`reason` exists / missing / deleted / changed) and nothing written; uploads are consumed only when it lands;
##   * versions are per-file counters, a delete is a version; the change feed has a cursor ("bad_cursor" for one it does not know); GET .../parts/{id} is the part index;
##   * a body over `max_bytes` is 413.
## S4: chunked uploads as in the real store (POST uploads/sessions, GET/PUT uploads/{id}?offset=, POST uploads/{id}/complete: in-order chunks, 409 wrong_offset with `received`, the
## declared SHA-256 checked at complete, listed as "uploads.chunked" in /health unless `chunked` is false), `chunk_cap` (a body over it is a tunnel's non-JSON 413, like the real tunnel),
## `lose_reply_next(substring)` (the request is APPLIED and the reply never arrives), `die_after(n)` (the store goes offline after n more requests), `restart_store()` (it keeps
## its data; a store switched off and on) and `expire_uploads()`.
## Test controls: `offline` (every call is unreachable), `fail_next(substring, status, body)` (the next matching call answers that), `put_direct` / `delete_direct`
## (another device saves), `requests` (the log), `forget_feed()` (every cursor is refused). fail_next(.., 0) drops the connection for one call.

var key := "test-key"
var offline := false
var max_bytes := 200 * 1024 * 1024
var chunked := true ## advertise and serve chunked uploads
var chunk_cap := 0 ## > 0: a request body over this many bytes is refused by "a tunnel" (413, an HTML page, not the store's JSON)
var chunks_received := 0 ## chunk requests that were applied
var requests: Array = [] ## [{method, path, device}]
var projects := {} ## name -> {path -> {history: [{version, bytes (or null for a delete), by, at, deleted, moved_to}]}}
var _seq := 0
var _feed: Array = [] ## [{seq, project, path, op, version, device, at, moved_to?}]
var _uploads := {} ## id -> {project, bytes}
var _sessions := {} ## id -> {project, size, sha256, bytes (so far), complete}
var _next_upload := 1
var _fail: Array = [] ## [{substring, status, body}]
var _lose: Array = [] ## [substring]: apply the next matching request, then drop the connection
var _die_in := -1
var _clock := 0
var _forget_below := -1 ## cursors at or below this are refused (forget_feed)


func add_project(project: String) -> void:
	if not projects.has(project):
		projects[project] = {}


func fail_next(substring: String, status: int, body: Dictionary = {}) -> void:
	_fail.append({"substring": substring, "status": status, "body": body})


func lose_reply_next(substring: String) -> void:
	_lose.append(substring)


func die_after(requests_left: int) -> void:
	_die_in = requests_left


func restart_store() -> void:
	## Switched off and on again: the data stays (the real store keeps uploads, sessions and versions on disk), the connection is back.
	offline = false
	_die_in = -1


func expire_uploads() -> void:
	_uploads.clear()
	_sessions.clear()


func forget_feed() -> void:
	_forget_below = _seq + 1000000 # any cursor this store ever issued is now "not one this store issued"


func requests_matching(method: String, substring: String) -> Array:
	return requests.filter(func(r: Dictionary) -> bool: return (method == "" or r["method"] == method) and substring in str(r["path"]))


func at_now() -> String:
	_clock += 60
	var minutes := _clock / 60
	return "2026-11-13T%02d:%02d:00Z" % [8 + minutes / 60, minutes % 60]


# --- direct manipulation (another device, outside the HTTP surface) ---------------------------------------------------------------------------------

func put_direct(project: String, path: String, content, device: String = "Desktop") -> int:
	## `content`: a String or bytes.
	add_project(project)
	return _write(project, path, content.to_utf8_buffer() if content is String else content, device)["version"]


func delete_direct(project: String, path: String, device: String = "Desktop", moved_to: String = "") -> void:
	var files: Dictionary = projects[project]
	var entry: Dictionary = files[path]
	var version: int = entry["history"].back()["version"] + 1
	entry["history"].append({"version": version, "bytes": null, "by": device, "at": at_now(), "deleted": true, "moved_to": moved_to})
	_record(project, path, "delete", version, device, moved_to)


func file_bytes(project: String, path: String) -> PackedByteArray:
	var entry = projects.get(project, {}).get(path)
	if entry == null or entry["history"].back()["deleted"]:
		return PackedByteArray()
	return entry["history"].back()["bytes"]


func has_file(project: String, path: String) -> bool:
	var entry = projects.get(project, {}).get(path)
	return entry != null and not entry["history"].back()["deleted"]


func version_of(project: String, path: String) -> int:
	var entry = projects.get(project, {}).get(path)
	return 0 if entry == null else int(entry["history"].back()["version"])


func device_of(project: String, path: String) -> String:
	var entry = projects.get(project, {}).get(path)
	return "" if entry == null else str(entry["history"].back()["by"])


func live_paths(project: String) -> Array:
	var out: Array = []
	for path in projects.get(project, {}):
		if not projects[project][path]["history"].back()["deleted"]:
			out.append(path)
	out.sort()
	return out


# --- the transport ---------------------------------------------------------------------------------------------------------------------------

func request(method: String, url: String, headers: Dictionary, body: PackedByteArray) -> Dictionary:
	var path := url.get_slice("://", 1)
	path = path.substr(path.find("/")) if "/" in path else "/"
	requests.append({"method": method, "path": path, "device": str(headers.get("X-Device-Name", "")), "if_match": str(headers.get("If-Match", "")), "if_none_match": str(headers.get("If-None-Match", "")), "size": body.size()})
	if _die_in == 0:
		offline = true
	elif _die_in > 0:
		_die_in -= 1
	if offline:
		return {"status": 0, "headers": {}, "body": PackedByteArray(), "unreachable": true, "error": "no answer (fake store offline)"}
	if chunk_cap > 0 and body.size() > chunk_cap:
		return {"status": 413, "headers": {"content-type": "text/html"}, "body": "<html>413 Request Entity Too Large</html>".to_utf8_buffer(), "unreachable": false, "error": ""}
	for i in _lose.size():
		if str(_lose[i]) in path:
			_lose.remove_at(i)
			_request_inner(method, url, headers, body, path)
			return {"status": 0, "headers": {}, "body": PackedByteArray(), "unreachable": true, "error": "no answer (reply lost)"}
	return _request_inner(method, url, headers, body, path)


func _request_inner(method: String, url: String, headers: Dictionary, body: PackedByteArray, path: String) -> Dictionary:
	for i in _fail.size():
		if str(_fail[i]["substring"]) in path:
			var f: Dictionary = _fail.pop_at(i)
			if int(f["status"]) == 0:
				return {"status": 0, "headers": {}, "body": PackedByteArray(), "unreachable": true, "error": "no answer (injected)"}
			return _json(int(f["status"]), f["body"] if not (f["body"] as Dictionary).is_empty() else {"error": "injected", "detail": "injected failure %d" % int(f["status"])})
	if str(headers.get("X-API-Key", "")) != key:
		return _json(401, {"error": "unauthorized", "detail": "the API key is missing or wrong"})
	var device := str(headers.get("X-Device-Name", ""))
	var query := ""
	if "?" in path:
		query = path.get_slice("?", 1)
		path = path.get_slice("?", 0)
	var segments := PackedStringArray()
	for segment in path.split("/", false):
		segments.append(segment.uri_decode())
	if body.size() > max_bytes and method in ["PUT", "POST"]:
		return _json(413, {"error": "too_large", "detail": "a file may be at most %d bytes" % max_bytes})
	if segments.size() == 1 and segments[0] == "health":
		return _json(200, {"status": "ok", "api_features": ["files.if_match", "commit.all_or_nothing", "uploads", "changes.cursor", "parts.index"] + (["uploads.chunked"] if chunked else []), "version": "fake"})
	if segments.size() == 1 and segments[0] == "projects":
		if method == "GET":
			var list := []
			for name in projects:
				list.append({"name": name, "file_count": live_paths(name).size(), "total_size": 0, "last_change": null, "last_device": null})
			return _json(200, {"projects": list})
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		var name := str(parsed.get("name", "")) if parsed is Dictionary else ""
		if projects.has(name):
			return _json(409, {"error": "conflict", "detail": "a project named '%s' already exists" % name})
		add_project(name)
		return _json(201, {"name": name, "file_count": 0, "total_size": 0})
	if segments.size() < 3 or segments[0] != "projects":
		return _json(404, {"error": "not_found", "detail": "no such route"})
	var project := segments[1]
	if not projects.has(project):
		return _json(404, {"error": "not_found", "detail": "no project %s" % project})
	var rest := segments.slice(2)
	var files: Dictionary = projects[project]
	match rest[0]:
		"tree":
			var out := []
			for p in live_paths(project):
				out.append(_info(project, p))
			return _json(200, {"project": project, "files": out, "cursor": str(_seq)})
		"changes":
			var since := ""
			for pair in query.split("&", false):
				if pair.begins_with("since="):
					since = pair.substr(6).uri_decode()
			if not since.is_valid_int() or int(since) < 0 or int(since) > _seq or int(since) <= _forget_below:
				return _json(400, {"error": "bad_cursor", "detail": "the cursor %s is not one this store issued" % since})
			var changes := []
			for c in _feed:
				if c["project"] == project and int(c["seq"]) > int(since):
					var item := {"path": c["path"], "op": c["op"], "version": c["version"], "device": c["device"], "at": c["at"]}
					if c.has("moved_to") and str(c["moved_to"]) != "":
						item["moved_to"] = c["moved_to"]
					changes.append(item)
			return _json(200, {"project": project, "changes": changes, "cursor": str(_seq), "more": false})
		"parts":
			var wanted := rest[1] if rest.size() > 1 else ""
			var found := []
			for p in live_paths(project):
				if _part_id(p, file_bytes(project, p)) == wanted:
					found.append(_info(project, p))
			return _json(200, {"part_id": wanted, "files": found})
		"uploads":
			if rest.size() > 1:
				return _chunked(method, project, rest, query, body)
			var id := "up%d" % _next_upload
			_next_upload += 1
			_uploads[id] = {"project": project, "bytes": body}
			return _json(201, {"upload_id": id, "size": body.size(), "sha256": _sha(body), "expires_at": "later"})
		"commit":
			return _commit(project, body, device)
		"files":
			var file := "/".join(rest.slice(1))
			return _file(method, project, file, headers, body, device)
	return _json(404, {"error": "not_found", "detail": "no such route"})


func _chunked(method: String, project: String, rest: PackedStringArray, query: String, body: PackedByteArray) -> Dictionary:
	if not chunked:
		return _json(404, {"error": "not_found", "detail": "no such route"})
	if rest[1] == "sessions" and method == "POST":
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if not (parsed is Dictionary) or int(parsed.get("size", 0)) < 1 or str(parsed.get("sha256", "")).length() != 64:
			return _json(400, {"error": "bad_request", "detail": "size and sha256 are needed"})
		if int(parsed["size"]) > max_bytes:
			return _json(413, {"error": "too_large", "detail": "a file may be at most %d bytes" % max_bytes})
		var id := "up%d" % _next_upload
		_next_upload += 1
		_sessions[id] = {"project": project, "size": int(parsed["size"]), "sha256": str(parsed["sha256"]), "bytes": PackedByteArray(), "complete": false}
		return _json(201, {"upload_id": id, "size": int(parsed["size"]), "received": 0, "chunk_size": 32 * 1024 * 1024, "complete": false})
	var up_id := rest[1]
	var session = _sessions.get(up_id)
	if session == null or session["project"] != project:
		return _json(404, {"error": "unknown_upload", "detail": "upload %s is unknown, expired or belongs to another project" % up_id})
	var info := {"upload_id": up_id, "size": session["size"], "received": (session["bytes"] as PackedByteArray).size(), "complete": session["complete"]}
	if rest.size() == 2 and method == "GET":
		return _json(200, info)
	if rest.size() == 2 and method == "PUT":
		var offset := -1
		for pair in query.split("&", false):
			if pair.begins_with("offset="):
				offset = int(pair.substr(7))
		if session["complete"]:
			return _json(409, merge_dict({"error": "upload_complete", "detail": "this upload is already complete"}, info))
		if offset != info["received"]:
			return _json(409, merge_dict({"error": "wrong_offset", "detail": "expected offset %d, got %d" % [info["received"], offset]}, info))
		if int(info["received"]) + body.size() > int(session["size"]):
			return _json(400, {"error": "chunk_past_end", "detail": "this chunk goes past the size the upload declared"})
		var so_far: PackedByteArray = session["bytes"]
		so_far.append_array(body)
		session["bytes"] = so_far
		chunks_received += 1
		info["received"] = (session["bytes"] as PackedByteArray).size()
		return _json(200, info)
	if rest.size() == 3 and rest[2] == "complete" and method == "POST":
		if not session["complete"]:
			if int(info["received"]) != int(session["size"]):
				return _json(409, merge_dict({"error": "incomplete", "detail": "%d of %d bytes received" % [info["received"], session["size"]]}, info))
			if _sha(session["bytes"]) != session["sha256"]:
				_sessions.erase(up_id)
				return _json(400, {"error": "checksum_mismatch", "detail": "the bytes received do not match the declared SHA-256"})
			session["complete"] = true
			_uploads[up_id] = {"project": project, "bytes": session["bytes"]}
		return _json(200, {"upload_id": up_id, "size": session["size"], "sha256": session["sha256"], "expires_at": "later"})
	return _json(404, {"error": "not_found", "detail": "no such route"})


static func merge_dict(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate()
	out.merge(b, true)
	return out


func _file(method: String, project: String, file: String, headers: Dictionary, body: PackedByteArray, device: String) -> Dictionary:
	var files: Dictionary = projects[project]
	if method == "GET":
		if not has_file(project, file):
			return _json(404, {"error": "not_found", "detail": "no file %s in %s" % [file, project]})
		var bytes := file_bytes(project, file)
		return {"status": 200, "headers": {"etag": "\"%d\"" % version_of(project, file), "x-sha256": _sha(bytes)}, "body": bytes, "unreachable": false, "error": ""}
	if method != "PUT":
		return _json(405, {"error": "method", "detail": "not allowed"})
	var if_match := str(headers.get("If-Match", ""))
	var if_none := str(headers.get("If-None-Match", ""))
	if if_match == "" and if_none == "":
		return _json(428, {"error": "precondition_required", "detail": "send If-Match or If-None-Match"})
	var live := has_file(project, file)
	if if_none != "":
		if live:
			return _json(412, {"error": "stale_version", "detail": "'%s' already exists" % file, "current": _current(project, file)}, {"ETag": "\"%d\"" % version_of(project, file)})
	else:
		var wanted := int(if_match.replace("\"", ""))
		if not live or version_of(project, file) != wanted:
			return _json(412, {"error": "stale_version", "detail": "'%s' is not at version %d" % [file, wanted], "current": _current(project, file)})
	if live and _sha(file_bytes(project, file)) == _sha(body):
		var info := _info(project, file)
		info["op"] = "put"
		info["unchanged"] = true
		return _json(200, info, {"ETag": "\"%d\"" % version_of(project, file)})
	var created := not live
	var info2 := _write(project, file, body, device)
	return _json(201 if created else 200, info2, {"ETag": "\"%d\"" % int(info2["version"])})


func _commit(project: String, body: PackedByteArray, device: String) -> Dictionary:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or not (parsed.get("changes") is Array):
		return _json(422, {"error": "invalid_body", "detail": "the request body is not the shape this endpoint takes"})
	var conflicts := []
	var staged := []
	for change in parsed["changes"]:
		var path := str(change.get("path", ""))
		var upload_id := str(change.get("upload_id", ""))
		if str(change.get("op", "")) != "put" or not _uploads.has(upload_id) or _uploads[upload_id]["project"] != project:
			return _json(400, {"error": "unknown_upload", "detail": "upload %s is unknown, expired or belongs to another project" % upload_id})
		var base = change.get("base_version")
		var live := has_file(project, path)
		if base == null:
			if live:
				conflicts.append(_conflict(project, path, base, "exists"))
		elif not live or version_of(project, path) != int(base):
			var entry = projects[project].get(path)
			var reason := "missing" if entry == null else ("deleted" if not live else "changed")
			conflicts.append(_conflict(project, path, base, reason))
		staged.append({"path": path, "bytes": _uploads[upload_id]["bytes"], "upload": upload_id})
	if not conflicts.is_empty():
		return _json(409, {"error": "conflict", "detail": "%d change(s) clash with what is current; nothing was written" % conflicts.size(), "conflicts": conflicts})
	var applied := []
	for item in staged:
		var live2 := has_file(project, item["path"])
		if live2 and _sha(file_bytes(project, item["path"])) == _sha(item["bytes"]):
			var info := _info(project, item["path"])
			info["op"] = "put"
			info["unchanged"] = true
			applied.append(info)
		else:
			var written := _write(project, item["path"], item["bytes"], device)
			written["op"] = "put"
			applied.append(written)
		_uploads.erase(item["upload"])
	return _json(200, {"files": applied, "cursor": str(_seq)})


func _conflict(project: String, path: String, base, reason: String) -> Dictionary:
	return {"path": path, "op": "put", "base_version": base, "reason": reason, "current_version": null if version_of(project, path) == 0 else version_of(project, path), "current": _current(project, path)}


func _current(project: String, path: String) -> Variant:
	var entry = projects[project].get(path)
	if entry == null:
		return null
	var last: Dictionary = entry["history"].back()
	if last["deleted"]:
		var out := {"path": path, "version": last["version"], "deleted": true, "modified_at": last["at"], "modified_by": last["by"]}
		if str(last.get("moved_to", "")) != "":
			out["moved_to"] = last["moved_to"]
		return out
	return _info(project, path)


func _write(project: String, path: String, bytes: PackedByteArray, device: String) -> Dictionary:
	var files: Dictionary = projects[project]
	if not files.has(path):
		files[path] = {"history": []}
	var history: Array = files[path]["history"]
	var version: int = 1 if history.is_empty() else int(history.back()["version"]) + 1
	history.append({"version": version, "bytes": bytes, "by": device, "at": at_now(), "deleted": false, "moved_to": ""})
	_record(project, path, "put", version, device, "")
	return _info(project, path)


func _record(project: String, path: String, op: String, version: int, device: String, moved_to: String) -> void:
	_seq += 1
	_feed.append({"seq": _seq, "project": project, "path": path, "op": op, "version": version, "device": device, "at": at_now(), "moved_to": moved_to})


func _info(project: String, path: String) -> Dictionary:
	var last: Dictionary = projects[project][path]["history"].back()
	return {"path": path, "size": (last["bytes"] as PackedByteArray).size(), "sha256": _sha(last["bytes"]), "version": last["version"], "modified_at": last["at"],
		"modified_by": last["by"], "part_id": _part_id(path, last["bytes"])}


func _part_id(path: String, bytes: PackedByteArray) -> Variant:
	var lower := path.to_lower()
	if not (lower.ends_with(".didsa") or lower.ends_with(".didsaprt") or lower.ends_with(".didsa.json")):
		return null
	var reader := JSON.new()
	if reader.parse(bytes.get_string_from_utf8()) == OK and reader.data is Dictionary and reader.data.get("document") is Dictionary and reader.data["document"].get("root_part_id") != null:
		return str(reader.data["document"]["root_part_id"])
	return null


static func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _json(status: int, body: Dictionary, headers: Dictionary = {}) -> Dictionary:
	var out_headers := {}
	for k in headers:
		out_headers[str(k).to_lower()] = headers[k]
	return {"status": status, "headers": out_headers, "body": JSON.stringify(body).to_utf8_buffer(), "unreachable": false, "error": ""}
