extends Node
## The design table's line to the DIDSA-CAD backend: ONE request in flight at a time, in the order they were asked.
##
## The backend holds a single in-memory Document per session and its sketch calls build on each other
## (a point must exist before the line that uses it), and main.gd's own loads already learned that
## overlapping calls can 500 or interleave. So every call takes a ticket and waits its turn; two
## coroutines (a tap and a dimension, say) can never reorder or overlap.
##
## Paths are the full route ("/document/parts/..." or "/sketch/sketches/..."); sketch routes live under
## /sketch, not /document, so unlike mates_tool.gd's helper nothing is prefixed here. The VR client sends no
## X-Document-Session header, so everything lands in the "default" session its other tools use.
##
## request() returns {ok, code, json, error}; fetch_bytes() returns {ok, code, bytes, error}. Both are
## coroutines. Tests give the sketch logic a fake Callable with the same shape instead of this node.

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
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
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
