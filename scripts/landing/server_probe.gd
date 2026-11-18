extends Node
## The Servers page's Test button: GET <url>/health with the API key (what DIDSA-CAD's own pairing check asks), and what the answer means in words.
## One probe is one request; add it to the tree, `await probe.check(url, key)`, then free it.

const BackendSession := preload("res://scripts/backend_session.gd")
const TIMEOUT_SECONDS := 6.0


func check(url: String, api_key: String) -> Dictionary:
	## {ok: bool, message: String, code: int}
	var request := HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	var error := request.request(url.rstrip("/") + "/health", BackendSession.headers(api_key), HTTPClient.METHOD_GET)
	if error != OK:
		request.queue_free()
		return describe(HTTPRequest.RESULT_CANT_CONNECT, 0)
	var answer: Array = await request.request_completed
	request.queue_free()
	var out := describe(int(answer[0]), int(answer[1]))
	if out["ok"]:
		out["session_hub"] = hub_in_health(answer[3]) # P2: where this backend says its session hub is ("" for an older one, or none set)
	return out


static func hub_in_health(body: PackedByteArray) -> String:
	## `session_hub` from DIDSA-CAD's /health: the hub's public wss:// address when the backend was told SESSION_HUB_URL (never a key). "" when it says none.
	var json := JSON.new()
	if body.is_empty() or json.parse(body.get_string_from_utf8()) != OK or not (json.data is Dictionary):
		return ""
	var value = (json.data as Dictionary).get("session_hub", "")
	return str(value).strip_edges() if value is String else ""


const NO_INTERNET_HINT := " If every server fails like this, this build may lack Android's Internet permission: Permissions > Internet in the export preset, then rebuild."


static func describe(result_code: int, response_code: int, on_android: bool = OS.get_name() == "Android") -> Dictionary:
	## The words for an HTTPRequest outcome (pure, so a test can check each case). On Android a failure to resolve or connect also names the Internet
	## permission: Godot's Android export leaves it off by default, and then nothing can connect (the first Quest 3 pairing, 22 Oct 2026).
	var hint := NO_INTERNET_HINT if on_android else ""
	if result_code != HTTPRequest.RESULT_SUCCESS:
		match result_code:
			HTTPRequest.RESULT_TIMEOUT:
				return {"ok": false, "code": 0, "message": "No answer in %d seconds. Is it running, and are you on the same network?" % int(TIMEOUT_SECONDS)}
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				return {"ok": false, "code": 0, "message": "The secure connection failed (the certificate may not be trusted by the headset)."}
			HTTPRequest.RESULT_CANT_RESOLVE:
				return {"ok": false, "code": 0, "message": "Could not find that address (the name did not resolve). Check the spelling, or use the server's IP address." + hint}
			_:
				return {"ok": false, "code": 0, "message": "Could not reach the server. Is it running, and is the address right?" + hint}
	if response_code == 401 or response_code == 403:
		return {"ok": false, "code": response_code, "message": "The server refused the API key."}
	if response_code < 200 or response_code >= 300:
		return {"ok": false, "code": response_code, "message": "The server answered %d." % response_code}
	return {"ok": true, "code": response_code, "message": "The server answers."}
