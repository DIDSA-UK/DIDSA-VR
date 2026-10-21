extends RefCounted
## What a pairing QR code says, and what the headset will take from it. The format is DIDSA-CAD's (docs/vr-headset-pairing.md, "The code's contents"):
##
##     didsa-vr:1?n=<name>&u=<base url>&k=<api key>          (each value percent-encoded; Dart's Uri.encodeQueryComponent, so a space is `+`)
##     optional, reserved: s=<document session>  r=<relay url>  rk=<relay key>
##
## The headset refuses anything that does not start `didsa-vr:1?`, a version it does not know, a code with no address or key, an address
## server_address.gd refuses (so plain http:// only to a local network), and anything carrying control characters or an absurd length. Unknown extra
## keys are ignored (a later DIDSA-CAD may add some). A code is data from outside: nothing in it is trusted beyond being a candidate to show the user, who
## must still say "Connect".

const ServerAddress := preload("res://scripts/landing/server_address.gd")
const SCHEME := "didsa-vr"
const VERSION := 1
const MAX_LENGTH := 2048
const MAX_VALUE := 512
const MAX_NAME := 64
static var _CONTROL_ESCAPE := RegEx.create_from_string("%(0[0-9a-fA-F]|1[0-9a-fA-F]|7[fF])") ## a percent-escaped control character
const KEYS: Array[String] = ["n", "u", "k", "s", "r", "rk"]


static func looks_like_pairing(text: String) -> bool:
	## Whether a scanned string is meant to be one of ours (so a scan of any other QR code can be ignored quietly instead of reported as an error).
	return text.strip_edges().to_lower().begins_with(SCHEME + ":")


static func parse(raw: String) -> Dictionary:
	## {ok: bool, error: String, name, url, api_key, document_session, relay_url, relay_api_key, warning: String}
	var text := raw.strip_edges()
	if text.length() > MAX_LENGTH:
		return _fail("That code is too long to be a DIDSA pairing code.")
	if not text.begins_with(SCHEME + ":"):
		return _fail("That is not a DIDSA pairing code.")
	var rest := text.substr(SCHEME.length() + 1)
	var question := rest.find("?")
	if question == -1:
		return _fail("That pairing code has no details in it.")
	var version := rest.substr(0, question)
	if version != str(VERSION):
		if version.is_valid_int():
			return _fail("That code is version %s; this app understands version %d. Update the app (or DIDSA-CAD)." % [version, VERSION])
		return _fail("That is not a DIDSA pairing code.")
	var values := {}
	for pair in rest.substr(question + 1).split("&", false):
		var equals := pair.find("=")
		var key := pair if equals == -1 else pair.substr(0, equals)
		var encoded := "" if equals == -1 else pair.substr(equals + 1)
		if _CONTROL_ESCAPE.search(encoded) != null:
			return _fail("That pairing code has characters in it that cannot be right. Show the code again.") # (a %00 would end a decoded string early, so it is looked for before decoding)
		var value := _decode(encoded)
		if key not in KEYS:
			continue # a key from a newer DIDSA-CAD: ignored
		if values.has(key):
			return _fail("That pairing code names %s twice, so it is ambiguous. Show the code again." % key)
		values[key] = value
	for key in values:
		var value: String = values[key]
		if value.length() > MAX_VALUE:
			return _fail("That pairing code has a value that is too long.")
		if _has_control(value):
			return _fail("That pairing code has characters in it that cannot be right. Show the code again.")
	var url := ServerAddress.normalise(str(values.get("u", "")))
	var key_text := str(values.get("k", "")).strip_edges()
	if url == "":
		return _fail("That pairing code has no server address.")
	if key_text == "":
		return _fail("That pairing code has no API key.")
	var address := ServerAddress.check(url)
	if address["level"] == ServerAddress.Level.REFUSED:
		return _fail(str(address["message"]))
	var relay_url := ServerAddress.normalise(str(values.get("r", "")))
	if relay_url != "" and ServerAddress.check(relay_url)["level"] == ServerAddress.Level.REFUSED:
		return _fail("The browser relay address in that code is not allowed: %s" % ServerAddress.check(relay_url)["message"])
	var name := str(values.get("n", "")).strip_edges().substr(0, MAX_NAME)
	if name == "":
		name = ServerAddress.default_name(url)
	return {
		"ok": true, "error": "", "name": name, "url": address["url"], "api_key": key_text,
		"document_session": str(values.get("s", "")).strip_edges(), "relay_url": relay_url, "relay_api_key": str(values.get("rk", "")).strip_edges(),
		"warning": str(address["message"]) if address["level"] == ServerAddress.Level.WARN else "",
	}


static func build(name: String, url: String, api_key: String) -> String:
	## A code the way DIDSA-CAD writes it (tests use this to round-trip; the headset itself never makes one).
	return "%s:%d?n=%s&u=%s&k=%s" % [SCHEME, VERSION, _encode(name), _encode(ServerAddress.normalise(url)), _encode(api_key.strip_edges())]


static func _encode(value: String) -> String:
	return value.uri_encode().replace("%20", "+")


static func _decode(value: String) -> String:
	return value.replace("+", " ").uri_decode() # Dart writes a space as +, and a real + as %2B


static func _has_control(value: String) -> bool:
	for i in value.length():
		var code := value.unicode_at(i)
		if code < 32 or code == 127:
			return true
	return false


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "name": "", "url": "", "api_key": "", "document_session": "", "relay_url": "", "relay_api_key": "", "warning": ""}
