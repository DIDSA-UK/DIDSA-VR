extends RefCounted
## The headers every call to the DIDSA-CAD backend carries, in one place: the API key, and this app's own DOCUMENT SESSION.
##
## The backend keeps one in-memory document per `X-Document-Session` id (a request with none shares the fixed id "default"). The flat
## app sends a fresh id each launch; VR now does the same, so a VR import / New assembly / edit never replaces what the flat app has
## open on the same backend, and the other way round. Work moves between the two apps by FILE (VR's Save as new file writes a .didsa
## the flat app opens). The id is "vr-" plus random hex per launch, or `document_session` under [backend] in secrets.cfg when you want
## one that survives a restart (two headsets can then share a document on purpose).

const HEADER := "X-Document-Session"

static var session_id := ""


static func ensure() -> String:
	## The session id for this launch, made on first use.
	if session_id.is_empty():
		var crypto := Crypto.new()
		session_id = "vr-" + crypto.generate_random_bytes(6).hex_encode()
	return session_id


static func set_session_id(id: String) -> void:
	## An id chosen in secrets.cfg ("" keeps the generated one).
	if not id.strip_edges().is_empty():
		session_id = id.strip_edges()


static func headers(api_key: String, json_body: bool = false) -> Array:
	var out := ["X-API-Key: %s" % api_key, "%s: %s" % [HEADER, ensure()]]
	if json_body:
		out.append("Content-Type: application/json")
	return out
