extends RefCounted
## The project store's HTTP API (DIDSA-CAD `project-store/README.md`, `docs/shared-storage-scope.md` section 5), one coroutine per endpoint, with every status the store
## gives turned into a `kind` so no caller reads a status code. GDScript has no exceptions, so every call returns a Dictionary:
##
##   {ok, status, kind, message, json, body, headers, from_store, current, conflicts, code}
##
## kind: "ok" | "unreachable" (no answer: the caller queues, never loses) | "auth" (401: the store refused the key) | "not_found" (404) | "stale" (412: a single
## write's version is out of date; `current` says what is) | "conflict" (409; on a commit `conflicts` lists every clash and nothing was written) | "too_large" (413;
## `from_store` tells the store's own limit from a tunnel's page) | "bad_request" (400 / 422; `message` is the store's own words; `code` its `error` field, e.g.
## "bad_cursor", "unknown_upload") | "precondition_required" (428: a client bug, this client always sends a precondition) | "error".
##
## The transport is any object with `request(method: String, url: String, headers: Dictionary, body: PackedByteArray) -> Dictionary` (a coroutine returning
## {status: int, headers: Dictionary with lower-case keys, body: PackedByteArray, unreachable: bool, error: String}): cloud_http_transport.gd for real, a fake in
## the tests. X-Device-Name is sent on every call (printable ASCII only), and the store trusts it for nothing but "who changed it".

var base_url := ""
var api_key := ""
var device_name := ""
var transport: Object


func _init(p_transport: Object = null, p_url: String = "", p_key: String = "", p_device: String = "") -> void:
	transport = p_transport
	base_url = p_url.strip_edges().trim_suffix("/")
	api_key = p_key.strip_edges()
	device_name = p_device


static func ascii_header(value: String) -> String:
	## A header value the HTTP stack accepts: printable ASCII only (a device name may hold any characters).
	var out := ""
	for i in value.length():
		var c := value.unicode_at(i)
		out += char(c) if c >= 0x20 and c < 0x7f else "?"
	out = out.strip_edges()
	return out if out != "" else "device"


static func enc(segment: String) -> String:
	return segment.uri_encode()


static func file_path(project: String, path: String) -> String:
	var parts := PackedStringArray()
	for segment in path.split("/"):
		parts.append(enc(segment))
	return "/projects/%s/files/%s" % [enc(project), "/".join(parts)]


func is_configured() -> bool:
	return base_url != "" and api_key != ""


func _headers(extra: Dictionary = {}) -> Dictionary:
	var h := {"X-API-Key": api_key}
	if device_name != "":
		h["X-Device-Name"] = ascii_header(device_name)
	for key in extra:
		h[key] = extra[key]
	return h


func _call(method: String, path: String, extra_headers: Dictionary = {}, body: PackedByteArray = PackedByteArray(), commit: bool = false, json_body: bool = true) -> Dictionary:
	var answer: Dictionary = await transport.request(method, base_url + path, _headers(extra_headers), body)
	return interpret(answer, commit, json_body)


static func interpret(answer: Dictionary, commit: bool = false, json_body: bool = true) -> Dictionary:
	## A transport answer as this file's result Dictionary. Pure (the tests call it directly). `json_body` false: a success body is a file's bytes, not JSON, and is not parsed
	## (an error answer always is: the store's errors are JSON).
	var out := {"ok": false, "status": int(answer.get("status", 0)), "kind": "error", "message": "", "json": {}, "body": answer.get("body", PackedByteArray()),
		"headers": answer.get("headers", {}), "from_store": false, "current": {}, "conflicts": [], "code": ""}
	if bool(answer.get("unreachable", false)):
		out["kind"] = "unreachable"
		out["message"] = str(answer.get("error", "no answer"))
		return out
	var status: int = out["status"]
	if status >= 200 and status < 300 and not json_body:
		out["ok"] = true
		out["kind"] = "ok"
		return out
	var json: Dictionary = {}
	if not (out["body"] as PackedByteArray).is_empty():
		var reader := JSON.new() # (an error page that is not JSON is expected, so no error is printed)
		if reader.parse((out["body"] as PackedByteArray).get_string_from_utf8()) == OK and reader.data is Dictionary:
			json = reader.data
	out["json"] = json
	out["code"] = str(json.get("error", ""))
	out["from_store"] = json.has("error")
	var detail := str(json.get("detail", ""))
	if status >= 200 and status < 300:
		out["ok"] = true
		out["kind"] = "ok"
		return out
	match status:
		401:
			out["kind"] = "auth"
			out["message"] = detail if detail != "" else "The project store refused the key."
		404:
			out["kind"] = "not_found"
			out["message"] = detail if detail != "" else "Not found."
		412:
			out["kind"] = "stale"
			out["current"] = json.get("current") if json.get("current") is Dictionary else {}
			out["message"] = detail if detail != "" else "The file changed on the server."
		413:
			out["kind"] = "too_large"
			out["message"] = detail if detail != "" else "The server refused the upload as too large."
		428:
			out["kind"] = "precondition_required"
			out["message"] = detail if detail != "" else "The store needs to be told which version a write replaces (a bug in this app)."
		400, 422:
			out["kind"] = "bad_request"
			out["message"] = detail if detail != "" else "The project store refused the request."
		409:
			out["kind"] = "conflict"
			out["message"] = detail if detail != "" else "The project store reports a clash."
			if commit and json.get("conflicts") is Array:
				out["conflicts"] = json["conflicts"]
		_:
			out["message"] = detail if detail != "" else "The project store answered HTTP %d." % status
	return out


# --- the endpoints ------------------------------------------------------------------------------------------------------------------------

func health() -> Dictionary:
	return await _call("GET", "/health")


func list_projects() -> Dictionary:
	## json.projects: [{name, file_count, total_size, last_change, last_device}]
	return await _call("GET", "/projects")


func create_project(project_name: String) -> Dictionary:
	return await _call("POST", "/projects", {"Content-Type": "application/json"}, JSON.stringify({"name": project_name}).to_utf8_buffer())


func tree(project: String) -> Dictionary:
	## json.files: [{path, size, sha256, version, modified_at, modified_by, part_id}], json.cursor
	return await _call("GET", "/projects/%s/tree" % enc(project))


func get_file(project: String, path: String) -> Dictionary:
	## ok: body = the bytes, plus `version` (the ETag) and `sha256` (X-Sha256).
	var out := await _call("GET", file_path(project, path), {}, PackedByteArray(), false, false)
	if out["ok"]:
		out["version"] = int(str((out["headers"] as Dictionary).get("etag", "")).replace("\"", ""))
		out["sha256"] = str((out["headers"] as Dictionary).get("x-sha256", ""))
	return out


func put_file(project: String, path: String, bytes: PackedByteArray, if_match: int = -1) -> Dictionary:
	## One file's write. `if_match` >= 1 replaces that version; -1 creates only (If-None-Match: *). ALWAYS one of the two: a write with neither is refused (428).
	var h := {"Content-Type": "application/octet-stream"}
	if if_match >= 1:
		h["If-Match"] = "\"%d\"" % if_match
	else:
		h["If-None-Match"] = "*"
	return await _call("PUT", file_path(project, path), h, bytes)


func upload(project: String, bytes: PackedByteArray) -> Dictionary:
	## The bytes of one file of a later commit: json.upload_id (valid for an hour).
	return await _call("POST", "/projects/%s/uploads" % enc(project), {"Content-Type": "application/octet-stream"}, bytes)


func commit(project: String, changes: Array, message: String = "") -> Dictionary:
	## `changes`: [{op: "put", path, base_version (int, or null = create), upload_id}]. All or nothing: ok -> json.files (every new version), json.cursor;
	## a 409 -> kind "conflict" with `conflicts` (every clash) and nothing written.
	var body := {"changes": changes}
	if message != "":
		body["message"] = message
	return await _call("POST", "/projects/%s/commit" % enc(project), {"Content-Type": "application/json"}, JSON.stringify(body).to_utf8_buffer(), true)


func changes(project: String, since: String) -> Dictionary:
	## json.changes: [{path, op, version, device, at, moved_to?, moved_from?}], json.cursor, json.more
	return await _call("GET", "/projects/%s/changes?since=%s" % [enc(project), enc(since)])


func parts(project: String, part_id: String) -> Dictionary:
	## json.files: the live files whose root Part id this is (an empty list when none: the store answers 200 for an unknown id).
	return await _call("GET", "/projects/%s/parts/%s" % [enc(project), enc(part_id)])
