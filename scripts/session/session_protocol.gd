extends RefCounted
## The wire format of a live session, in one place (DIDSA-CAD docs/live-sessions-scope.md, section 4; the hub is DIDSA-CAD session-hub/). Nothing here
## opens a socket or touches the scene: the pure parts (codes, the join QR text, transforms, error words) so a test can pin each one.
##
## Model space is the frame of the glb root as VR shows it under AssemblyRoot, in MILLIMETRES (a backend model's own units, so unit_mm is 1.0; a demo
## glb is in metres, so its unit_mm is 1000.0 and a transform's origin is scaled by it). A transform is 12 numbers, basis x, y, z columns then the
## origin; a pose is 7 numbers, position then a quaternion.

const ServerAddress := preload("res://scripts/landing/server_address.gd")

const PROTO := 1
const JOIN_SCHEME := "didsa-join"
const JOIN_VERSION := 1
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789" ## no 0/O, 1/I/L (the hub's alphabet)
const CODE_LENGTH := 6
const MAX_JOIN_LENGTH := 1024
const POSITION_STEP := 0.01 ## model mm: what a transform's origin is rounded to on the wire
const BASIS_STEP := 1e-5

const ERROR_WORDS := {
	"proto_unsupported": "This hub speaks a different version of the session protocol. Update the app (or the hub).",
	"bad_code": "No session has that code. Check it and try again.",
	"room_full": "That session is full.",
	"room_locked": "The presenter has locked that session: nobody new can join.",
	"removed": "The presenter removed you from the session.",
	"not_allowed": "The hub refused that: hosting needs the hub's key.",
	"rate_limited": "The hub is refusing this headset for a while (too many wrong codes, or too many messages).",
	"too_big": "A message was too big for the hub.",
	"resume_expired": "The session has gone (or your place in it has expired). Join again.",
	"hub_full": "The hub has no room for another session just now.",
	"bad_message": "The hub could not use what was sent to host this model.",
}
const END_WORDS := {
	"ended": "The presenter ended the session.",
	"presenter_gone": "The presenter did not come back, so the session ended.",
}


static func normalise_code(text: String) -> String:
	## What the hub does with a typed code: upper-case letters and digits only (so "k7x-q4m" works).
	var out := ""
	for i in text.length():
		var ch := text[i].to_upper()
		if ch.unicode_at(0) < 128 and (ch >= "A" and ch <= "Z" or ch >= "0" and ch <= "9"):
			out += ch
	return out


static func code_is_valid(code: String) -> bool:
	## A well-formed code (6 characters from the hub's alphabet): checked before asking the hub so a typo costs no wrong-code strike.
	if code.length() != CODE_LENGTH:
		return false
	for i in code.length():
		if not CODE_ALPHABET.contains(code[i]):
			return false
	return true


static func code_for_display(code: String) -> String:
	## "K7X Q4M": easier to read out and to type.
	return code if code.length() != CODE_LENGTH else "%s %s" % [code.substr(0, 3), code.substr(3)]


static func error_text(code: String, message: String = "") -> String:
	return str(ERROR_WORDS.get(code, message if message != "" else "The hub refused that (%s)." % code))


static func end_text(reason: String) -> String:
	return str(END_WORDS.get(reason, "The session ended."))


# --- The join QR code / link: didsa-join:1?h=<hub wss address>&c=<code> -----------------------------------------------------

static func build_join_uri(hub_url: String, code: String) -> String:
	var text := "%s:%d?" % [JOIN_SCHEME, JOIN_VERSION]
	if hub_url.strip_edges() != "":
		text += "h=%s&" % _encode(ServerAddress.normalise(hub_url))
	return text + "c=" + code


static func looks_like_join(text: String) -> bool:
	return text.strip_edges().to_lower().begins_with(JOIN_SCHEME + ":")


static func parse_join(raw: String) -> Dictionary:
	## {ok, error, hub_url, code}. A scanned or pasted join code is data from outside: refused when it is not ours, a version we do not know, has no
	## well-formed code, or its hub address is one the headset may not use (the same rules as a typed one). `h` may be missing: the person then uses
	## the hub they already know. Unknown keys are ignored.
	var text := raw.strip_edges()
	if text.length() > MAX_JOIN_LENGTH:
		return _join_fail("That code is too long to be a DIDSA join code.")
	if not looks_like_join(text):
		return _join_fail("That is not a DIDSA join code.")
	var rest := text.substr(JOIN_SCHEME.length() + 1)
	var question := rest.find("?")
	if question == -1:
		return _join_fail("That join code has no details in it.")
	var version := rest.substr(0, question)
	if version != str(JOIN_VERSION):
		if version.is_valid_int():
			return _join_fail("That join code is version %s; this app understands version %d. Update the app." % [version, JOIN_VERSION])
		return _join_fail("That is not a DIDSA join code.")
	var values := {}
	for pair in rest.substr(question + 1).split("&", false):
		var equals := pair.find("=")
		var key := pair if equals == -1 else pair.substr(0, equals)
		var value := "" if equals == -1 else pair.substr(equals + 1).replace("+", " ").uri_decode()
		if key not in ["h", "c"]:
			continue
		if values.has(key):
			return _join_fail("That join code names %s twice, so it is ambiguous." % key)
		values[key] = value
	for key in values:
		for i in str(values[key]).length():
			var c := str(values[key]).unicode_at(i)
			if c < 32 or c == 127:
				return _join_fail("That join code has characters in it that cannot be right.")
	var code := normalise_code(str(values.get("c", "")))
	if not code_is_valid(code):
		return _join_fail("That join code has no valid session code in it.")
	var hub_url := ""
	if str(values.get("h", "")).strip_edges() != "":
		var checked := hub_address(str(values["h"]))
		if not checked["ok"]:
			return _join_fail("The hub address in that join code is not allowed: %s" % checked["message"])
		hub_url = str(checked["url"])
	return {"ok": true, "error": "", "hub_url": hub_url, "code": code}


static func hub_address(raw: String, allow_loopback: bool = false) -> Dictionary:
	## {ok, url, message, warning}: a hub address (ws:// or wss://, or http(s) taken as the matching one) under the same rules as a server's. `allow_loopback`
	## is for tests and a desktop preview that hosts its own hub on localhost.
	var checked := ServerAddress.check_relay(raw)
	if checked["level"] == ServerAddress.Level.REFUSED:
		if allow_loopback and ServerAddress.is_loopback(str(checked["host"])):
			return {"ok": true, "url": _force_ws(raw), "message": "", "warning": ""}
		return {"ok": false, "url": "", "message": str(checked["message"]), "warning": ""}
	return {"ok": true, "url": str(checked["url"]), "message": "", "warning": str(checked["message"]) if checked["level"] == ServerAddress.Level.WARN else ""}


static func socket_url(hub_url: String) -> String:
	## The WebSocket endpoint of a hub address: <hub>/ws.
	var url := ServerAddress.normalise(hub_url)
	return url if url.ends_with("/ws") else url + "/ws"


static func health_url(hub_url: String) -> String:
	## The hub's HTTP /health on the same host: wss -> https, ws -> http.
	var url := ServerAddress.normalise(hub_url)
	if url.ends_with("/ws"):
		url = url.substr(0, url.length() - 3)
	if url.to_lower().begins_with("wss://"):
		url = "https://" + url.substr(6)
	elif url.to_lower().begins_with("ws://"):
		url = "http://" + url.substr(5)
	return url + "/health"


# --- Transforms and poses ---------------------------------------------------------------------------------------------------

static func xf_to_array(t: Transform3D, unit_mm: float = 1.0) -> Array:
	## 12 numbers: basis x, y, z columns, then the origin in model mm (rounded to 0.01 mm; the basis to 1e-5).
	var out: Array = []
	for column in [t.basis.x, t.basis.y, t.basis.z]:
		out.append_array([snappedf(column.x, BASIS_STEP), snappedf(column.y, BASIS_STEP), snappedf(column.z, BASIS_STEP)])
	var o := t.origin * unit_mm
	out.append_array([snappedf(o.x, POSITION_STEP), snappedf(o.y, POSITION_STEP), snappedf(o.z, POSITION_STEP)])
	return out


static func xf_from_array(a, unit_mm: float = 1.0) -> Variant:
	## The Transform3D a 12-number array says (origin back from model mm), or null when it is not 12 finite numbers.
	if not is_numbers(a, 12):
		return null
	var basis := Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8]))
	return Transform3D(basis, Vector3(a[9], a[10], a[11]) / unit_mm)


static func place_to_array(t: Transform3D) -> Array:
	## The model root in the presenter's world, METRES, scale included (the `place` message): the basis keeps the scale, so it is not rounded to 1e-5
	## relative to a unit basis; 1e-7 is plenty (a scale of 0.001 is carried as 0.001).
	var out: Array = []
	for column in [t.basis.x, t.basis.y, t.basis.z]:
		out.append_array([snappedf(column.x, 1e-9), snappedf(column.y, 1e-9), snappedf(column.z, 1e-9)])
	out.append_array([snappedf(t.origin.x, 1e-4), snappedf(t.origin.y, 1e-4), snappedf(t.origin.z, 1e-4)])
	return out


static func pose_to_array(position_mm: Vector3, rotation: Quaternion) -> Array:
	return [snappedf(position_mm.x, POSITION_STEP), snappedf(position_mm.y, POSITION_STEP), snappedf(position_mm.z, POSITION_STEP),
		snappedf(rotation.x, 1e-4), snappedf(rotation.y, 1e-4), snappedf(rotation.z, 1e-4), snappedf(rotation.w, 1e-4)]


static func is_numbers(value, length: int) -> bool:
	if not (value is Array) or (value as Array).size() != length:
		return false
	for v in value:
		if not (v is float or v is int) or is_nan(float(v)) or is_inf(float(v)):
			return false
	return true


static func colour_of(hex: String, fallback: Color = Color.WHITE) -> Color:
	## The hub's participant colour ("#E8590C").
	return Color.html(hex) if Color.html_is_valid(hex) else fallback


# --- Helpers ----------------------------------------------------------------------------------------------------------------

static func _encode(value: String) -> String:
	return value.uri_encode().replace("%20", "+")


static func _force_ws(raw: String) -> String:
	var url := ServerAddress.normalise(raw)
	if url.to_lower().begins_with("http://"):
		return "ws://" + url.substr(7)
	if url.to_lower().begins_with("https://"):
		return "wss://" + url.substr(8)
	return url


static func _join_fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "hub_url": "", "code": ""}
