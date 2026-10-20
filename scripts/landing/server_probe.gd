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
	return describe(int(answer[0]), int(answer[1]))


static func describe(result_code: int, response_code: int) -> Dictionary:
	## The words for an HTTPRequest outcome (pure, so a test can check each case).
	if result_code != HTTPRequest.RESULT_SUCCESS:
		match result_code:
			HTTPRequest.RESULT_TIMEOUT:
				return {"ok": false, "code": 0, "message": "No answer in %d seconds. Is it running, and are you on the same network?" % int(TIMEOUT_SECONDS)}
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				return {"ok": false, "code": 0, "message": "The secure connection failed (the certificate may not be trusted by the headset)."}
			_:
				return {"ok": false, "code": 0, "message": "Could not reach the server. Is it running, and is the address right?"}
	if response_code == 401 or response_code == 403:
		return {"ok": false, "code": response_code, "message": "The server refused the API key."}
	if response_code < 200 or response_code >= 300:
		return {"ok": false, "code": response_code, "message": "The server answered %d." % response_code}
	return {"ok": true, "code": response_code, "message": "The server answers."}
