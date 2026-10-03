extends Node
## The design table's line to the DIDSA-CAD backend: ONE request in flight at a time, in the order they were asked.
##
## The backend holds a single in-memory Document per session and its sketch calls build on each other
## (a point must exist before the line that uses it), and main.gd's own loads already learned that
## overlapping calls can 500 or interleave. So every call takes a ticket and waits its turn; two
## coroutines (a tap and a dimension, say) can never reorder or overlap.
##
## Paths are the full route ("/document/parts/..." or "/sketch/sketches/..."); sketch routes live under
## /sketch, not /document, so unlike mates_tool.gd's helper nothing is prefixed here. Every call carries the app's own
## X-Document-Session (backend_session.gd), so VR's document is separate from the flat app's on a shared backend.
##
## request() returns {ok, code, json, error}; fetch_bytes() returns {ok, code, bytes, error}. Both are
## coroutines. Tests give the sketch logic a fake Callable with the same shape instead of this node.

const BackendSession := preload("res://scripts/backend_session.gd") ## the API key and this app's own X-Document-Session on every call
signal _turn

var backend_url := ""
var api_key := ""
var requests_sent := 0

var _next_ticket := 0
var _serving := 0


func configure(url: String, key: String) -> void:
	backend_url = url
	api_key = key


func is_configured() -> bool:
	return not backend_url.is_empty() and not api_key.is_empty()


func request(method: int, path: String, body_dict = null) -> Dictionary:
	var ticket := _next_ticket
	_next_ticket += 1
	while _serving != ticket:
		await _turn
	var result := await _send(method, path, body_dict)
	_serving += 1
	_turn.emit()
	return result


var _view_filters := -1 ## -1 = not asked yet, 0 = the backend lacks the Build tree's glb parameters, 1 = it has them


func supports_view_filters() -> bool:
	## Does this backend's assembly-mesh.glb take hidden_feature_ids and rollback_excluded_feature_ids (DIDSA-CAD 2026-10-03)? Asked once
	## from its OpenAPI document and remembered. An older backend ignores them silently, so Hide / Show and Roll back would claim to
	## work and change nothing. If the question itself can't be answered (no network) the answer is "yes" and is not remembered.
	if _view_filters >= 0:
		return _view_filters == 1
	var r: Dictionary = await request(HTTPClient.METHOD_GET, "/openapi.json", null)
	if not r["ok"] or not (r["json"] is Dictionary):
		return true
	_view_filters = 1 if view_filters_in(r["json"]) else 0
	return _view_filters == 1


static func view_filters_in(openapi: Dictionary) -> bool:
	## True if the OpenAPI document's assembly-mesh.glb GET lists both parameters.
	var paths: Dictionary = openapi.get("paths", {})
	for route in paths:
		if str(route).ends_with("/assembly-mesh.glb"):
			var names: Array = []
			for param in (paths[route] as Dictionary).get("get", {}).get("parameters", []):
				names.append(str((param as Dictionary).get("name", "")))
			return names.has("hidden_feature_ids") and names.has("rollback_excluded_feature_ids")
	return false


func fetch_bytes(path: String) -> Dictionary:
	var ticket := _next_ticket
	_next_ticket += 1
	while _serving != ticket:
		await _turn
	var result := await _send(HTTPClient.METHOD_GET, path, null, true)
	_serving += 1
	_turn.emit()
	return result


func _send(method: int, path: String, body_dict, want_bytes: bool = false) -> Dictionary:
	if not is_configured():
		return {"ok": false, "code": 0, "json": null, "bytes": PackedByteArray(), "error": "no backend configured"}
	requests_sent += 1
	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key, true)
	var body := "" if body_dict == null else JSON.stringify(body_dict)
	var err := req.request(backend_url + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "json": null, "bytes": PackedByteArray(), "error": "request failed to start (error %d)" % err}
	var result: Array = await req.request_completed
	req.queue_free()
	var result_code: int = result[0]
	var response_code: int = result[1]
	var raw: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": response_code, "json": null, "bytes": PackedByteArray(), "error": "network error (result %d)" % result_code}
	var ok: bool = response_code >= 200 and response_code < 300
	if want_bytes:
		return {"ok": ok, "code": response_code, "json": null, "bytes": raw, "error": "" if ok else raw.get_string_from_utf8().left(300)}
	var parsed = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	return {"ok": ok, "code": response_code, "json": parsed, "bytes": PackedByteArray(), "error": "" if ok else error_text(parsed)}


static func error_text(parsed) -> String:
	## The backend's own `detail`, as plain text a status line can show.
	if parsed is Dictionary and parsed.has("detail"):
		var detail = parsed["detail"]
		if detail is Dictionary:
			return str(detail.get("type", detail.get("message", JSON.stringify(detail))))
		if detail is Array and not detail.is_empty() and detail[0] is Dictionary:
			return str(detail[0].get("msg", JSON.stringify(detail[0])))
		return str(detail)
	return str(parsed) if parsed != null else "unknown error"
