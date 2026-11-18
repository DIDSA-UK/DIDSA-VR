extends Node
## The few HTTP calls a live session makes, behind one awaitable function so a test can put a fake backend in its place: `transport` (method, url, headers, body_text) ->
## {result, code, headers, body}. The default uses an HTTPRequest per call. Used by session_manager.gd (view tokens, the hub's /health, the document revision) and
## session_observer.gd (the model's glb, fetched with the view token only).

const TIMEOUT_SECONDS := 60.0

var transport: Callable = Callable() ## tests: (method: int, url: String, headers: Array, body: String) -> Dictionary, may be a coroutine


func call_http(method: int, url: String, headers: Array, body_text: String = "") -> Dictionary:
	## {result: int (HTTPRequest.RESULT_*), code: int, headers: PackedStringArray, body: PackedByteArray}
	if transport.is_valid():
		return await transport.call(method, url, headers, body_text)
	var request := HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	request.accept_gzip = true
	add_child(request)
	var error := request.request(url, PackedStringArray(headers), method, body_text)
	if error != OK:
		request.queue_free()
		return {"result": HTTPRequest.RESULT_CANT_CONNECT, "code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
	var answer: Array = await request.request_completed
	request.queue_free()
	return {"result": int(answer[0]), "code": int(answer[1]), "headers": answer[2], "body": answer[3]}


static func json_of(response: Dictionary) -> Variant:
	## The response body as parsed JSON, or null.
	var body: PackedByteArray = response.get("body", PackedByteArray())
	if body.is_empty():
		return null
	var json := JSON.new()
	return json.data if json.parse(body.get_string_from_utf8()) == OK else null


static func detail_of(response: Dictionary) -> String:
	## FastAPI's `detail` for an error response, as text ("" when there is none).
	var parsed = json_of(response)
	if parsed is Dictionary and (parsed as Dictionary).has("detail"):
		var detail = parsed["detail"]
		return detail if detail is String else JSON.stringify(detail)
	return ""
