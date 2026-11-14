extends Node
## The real transport for cloud_store_client.gd: one HTTPRequest per call (a Node, so it needs the tree). `request()` is a coroutine returning
## {status, headers (lower-case keys), body, unreachable, error}. A connection that fails, times out or has a TLS problem is `unreachable`, which the sync layer turns
## into "queue it, never lose it"; any HTTP answer, including an error status, is a real answer.

const METHODS := {"GET": HTTPClient.METHOD_GET, "POST": HTTPClient.METHOD_POST, "PUT": HTTPClient.METHOD_PUT, "DELETE": HTTPClient.METHOD_DELETE}
const READ_TIMEOUT := 30.0 ## seconds, for small answers
const FILE_TIMEOUT := 600.0 ## seconds, for a file body in either direction (a big STEP file on a slow link)


func request(method: String, url: String, headers: Dictionary, body: PackedByteArray) -> Dictionary:
	for _wait in 5: # (a node added to the tree this frame is not in it yet)
		if is_inside_tree():
			break
		await Engine.get_main_loop().process_frame
	if not is_inside_tree():
		return {"status": 0, "headers": {}, "body": PackedByteArray(), "unreachable": true, "error": "the transport is not in the scene tree"}
	var req := HTTPRequest.new()
	req.use_threads = true
	req.download_chunk_size = 262144 # (the default 64 KiB is slow for a big file)
	req.timeout = FILE_TIMEOUT if (body.size() > 256 * 1024 or (method == "GET" and "/files/" in url)) else READ_TIMEOUT
	add_child(req)
	var lines := PackedStringArray()
	for key in headers:
		lines.append("%s: %s" % [key, headers[key]])
	var started := req.request_raw(url, lines, METHODS.get(method, HTTPClient.METHOD_GET), body)
	if started != OK:
		req.queue_free()
		return {"status": 0, "headers": {}, "body": PackedByteArray(), "unreachable": true, "error": "the request could not start (error %d)" % started}
	var result: Array = await req.request_completed
	req.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"status": 0, "headers": {}, "body": PackedByteArray(), "unreachable": true, "error": "no answer (%s)" % _result_text(int(result[0]))}
	var out := {}
	for line in (result[2] as PackedStringArray):
		var colon := line.find(":")
		if colon > 0:
			out[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	return {"status": int(result[1]), "headers": out, "body": result[3], "unreachable": false, "error": ""}


static func _result_text(code: int) -> String:
	match code:
		HTTPRequest.RESULT_CANT_CONNECT: return "can't connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "can't find that address"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "connection lost"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS problem"
		HTTPRequest.RESULT_TIMEOUT: return "timed out"
		_: return "error %d" % code
