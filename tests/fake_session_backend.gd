extends RefCounted
## A fake DIDSA-CAD backend for the live-session tests: just the routes a session touches, with the same rules as the real one (DIDSA-CAD backend/app/auth.py, view_tokens.py,
## session_hooks.py, document/view_routes.py; checked end to end by tests/e2e_session_*.gd). Plug it in with `session.http.transport = backend.handle`.
##   GET  /health                                      200 {status, session_hub?}
##   POST /document/view-tokens                        key needed; 201 {token, root_part_id, expires_at, rev}
##   DELETE /document/view-tokens/{token}              key needed; 204, or 404 for one it does not know
##   GET  /document/parts/{id}                         key needed; {name}
##   GET  /document/view-state                         with a token: 200 {rev, ...} or 401 view_token_invalid; with the key: 404 (the answer still carries the revision)
##   GET  /document/parts/{id}/assembly-mesh.glb       key OR a live token; the glb bytes, ETag "<rev>-<query>", 304 for a matching If-None-Match; 401 view_token_invalid
## Every /document answer carries X-Document-Revision. `log` has every request: {method, path, query, headers (lower-cased names), body}.

var key := "cad-secret"
var rev := 3
var hub_advertised := ""
var glb: PackedByteArray = FileAccess.get_file_as_bytes("res://tests/fixtures/session_assembly.glb")
var glb_variant: PackedByteArray = PackedByteArray() ## served after bump() when set (a "changed" mesh)
var tokens: Dictionary = {} ## live token -> true
var revoked: Array = []
var log: Array = []
var mint_status := 201 ## a test sets 404 / 500 to see Host Session cope
var offline := false ## every call fails to connect
var delay_s := 0.0 ## each answer takes this long (a test queues doc_changed messages behind a slow fetch)
var _minted := 0
var _glb_serves := 0


func handle(method: int, url: String, headers: Array, body: String) -> Dictionary:
	if delay_s > 0.0:
		await (Engine.get_main_loop() as SceneTree).create_timer(delay_s).timeout
	if offline:
		return {"result": HTTPRequest.RESULT_CANT_CONNECT, "code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
	var h := {}
	for header in headers:
		var text := str(header)
		var colon := text.find(":")
		h[text.substr(0, colon).to_lower()] = text.substr(colon + 1).strip_edges()
	var no_scheme := url.substr(url.find("://") + 3)
	var path_query := no_scheme.substr(no_scheme.find("/"))
	var path := path_query.get_slice("?", 0)
	var query := path_query.get_slice("?", 1) if path_query.contains("?") else ""
	log.append({"method": method, "path": path, "query": query, "headers": h, "body": body})
	var has_key: bool = h.get("x-api-key", "") == key
	var token: String = str(h.get("x-view-token", ""))
	var token_ok: bool = not has_key and tokens.has(token)
	if path == "/health":
		var health := {"status": "ok"}
		if hub_advertised != "":
			health["session_hub"] = hub_advertised
		return _json(200, health)
	if not path.begins_with("/document"):
		return _json(404, {"detail": "Not found"})
	if not has_key and not (method == HTTPClient.METHOD_GET and (path == "/document/view-state" or path.ends_with("/assembly-mesh.glb"))):
		return _json(401, {"detail": "Invalid or missing API key"}, false)
	if not has_key and not token_ok:
		return _json(401, {"detail": "view_token_invalid"})
	if path == "/document/view-tokens" and method == HTTPClient.METHOD_POST:
		if mint_status != 201:
			return _json(mint_status, {"detail": "no"})
		_minted += 1
		var parsed = JSON.parse_string(body)
		var token_text := "tok-%d" % _minted
		tokens[token_text] = true
		return _json(201, {"token": token_text, "root_part_id": parsed.get("root_part_id", ""), "expires_at": Time.get_unix_time_from_system() + 43200.0, "rev": rev})
	if path.begins_with("/document/view-tokens/") and method == HTTPClient.METHOD_DELETE:
		var gone := path.get_file()
		if tokens.has(gone):
			tokens.erase(gone)
			revoked.append(gone)
			return _empty(204)
		return _json(404, {"detail": "View token not found"})
	if path == "/document/view-state":
		if token_ok:
			return _json(200, {"rev": rev, "root_part_id": "part-root", "expires_at": Time.get_unix_time_from_system() + 43200.0})
		return _json(404, {"detail": "view-state is for a view token"})
	if path.ends_with("/assembly-mesh.glb"):
		var etag := "\"%d-%d\"" % [rev, query.hash()]
		if token_ok and h.get("if-none-match", "") == etag:
			var not_modified := _empty(304)
			not_modified["headers"].append("ETag: " + etag)
			return not_modified
		_glb_serves += 1
		var out := {"result": HTTPRequest.RESULT_SUCCESS, "code": 200, "headers": PackedStringArray(["Content-Type: model/gltf-binary", "X-Document-Revision: %d" % rev] + (["ETag: " + etag] if token_ok else [])),
			"body": glb_variant if not glb_variant.is_empty() and rev > 3 else glb}
		return out
	var parts := path.split("/")
	if parts.size() == 4 and parts[2] == "parts" and method == HTTPClient.METHOD_GET:
		return _json(200, {"id": parts[3], "name": "Gearbox"})
	return _json(404, {"detail": "Not found"})


func bump() -> int:
	## A change to the document (the real one bumps on every 2xx non-GET that changes it).
	rev += 1
	return rev


func requests_to(fragment: String) -> Array:
	return log.filter(func(r: Dictionary) -> bool: return str(r["path"]).contains(fragment))


func _json(code: int, data: Dictionary, with_rev: bool = true) -> Dictionary:
	var headers := PackedStringArray(["Content-Type: application/json"])
	if with_rev:
		headers.append("X-Document-Revision: %d" % rev)
	return {"result": HTTPRequest.RESULT_SUCCESS, "code": code, "headers": headers, "body": JSON.stringify(data).to_utf8_buffer()}


func _empty(code: int) -> Dictionary:
	return {"result": HTTPRequest.RESULT_SUCCESS, "code": code, "headers": PackedStringArray(["X-Document-Revision: %d" % rev]), "body": PackedByteArray()}
