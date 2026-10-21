extends SceneTree
## What a pairing QR code says and what the headset takes from it (docs/landing-scope.md L6; scripts/landing/pairing_payload.gd): DIDSA-CAD's format
## (`didsa-vr:1?n=<name>&u=<url>&k=<key>`, Dart's percent-encoding where a space is `+`) parsed, and every refusal the contract asks for. Pure, no scene.
## The codes below are written out by hand the way DIDSA-CAD's `HeadsetPairing.payload` writes them (client/test/headset_pairing_test.dart is its
## reference); they were not produced by a real DIDSA-CAD build.
## Run: "$GODOT" --headless --path . --script res://tests/pairing_payload.gd

const Payload := preload("res://scripts/landing/pairing_payload.gd")


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func refused(text: String, expect_in_error: String) -> bool:
	var r := Payload.parse(text)
	if r["ok"] or not (expect_in_error in str(r["error"])):
		print("  refused? ", text.left(60), " -> ", r["ok"], " ", r["error"])
		return false
	return r["url"] == "" and r["api_key"] == "" # nothing leaks out of a refused code


func _initialize() -> void:
	# --- accepted ---------------------------------------------------------------------------------------------------------
	var good := Payload.parse("didsa-vr:1?n=Workshop+PC&u=https%3A%2F%2Fcad.example.net&k=a+b%26c%3Dd")
	check("a code as DIDSA-CAD writes it: name, address and key decoded (a + is a space, %26 and %3D are & and =)", good["ok"] and good["name"] == "Workshop PC" and good["url"] == "https://cad.example.net" and good["api_key"] == "a b&c=d" and good["warning"] == "")
	var lan := Payload.parse("didsa-vr:1?n=Phone+server+%28192.168.1.9%29&u=http%3A%2F%2F192.168.1.9%3A8000&k=secret")
	check("a local http code is accepted with the unencrypted warning", lan["ok"] and lan["url"] == "http://192.168.1.9:8000" and lan["name"] == "Phone server (192.168.1.9)" and "unencrypted" in lan["warning"])
	check("a real + in a value is %2B and stays a +", Payload.parse("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=p%2Bq")["api_key"] == "p+q")
	check("a trailing slash on the address is dropped", Payload.parse("didsa-vr:1?u=https%3A%2F%2Fa.example.net%2F&k=k")["url"] == "https://a.example.net")
	var no_name := Payload.parse("didsa-vr:1?u=https%3A%2F%2Fcad.example.net%3A8443&k=k")
	check("no name: the host is used", no_name["ok"] and no_name["name"] == "cad.example.net")
	check("a long name is cut to 64 characters", Payload.parse("didsa-vr:1?n=%s&u=https%%3A%%2F%%2Fa.example.net&k=k" % "x".repeat(200))["name"].length() == 64)
	var extras := Payload.parse("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=k&s=vr-session-1&r=https%3A%2F%2Frelay.example.net&rk=relaykey&zz=ignored")
	check("the reserved keys (document session, relay) are read and an unknown key is ignored", extras["ok"] and extras["document_session"] == "vr-session-1" and extras["relay_url"] == "https://relay.example.net" and extras["relay_api_key"] == "relaykey")
	check("surrounding spaces and a newline from a scanner are tolerated", Payload.parse("  didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=k\n")["ok"])

	# --- the round trip ------------------------------------------------------------------------------------------------------
	var odd_keys := ["p+q r&s=t/é", "a b&c=d", "%41", "ünï cödé", "with#hash?and=eq"]
	var round_ok := true
	for k in odd_keys:
		var r := Payload.parse(Payload.build("Name & Co", "https://cad.example.net/", k))
		if not (r["ok"] and r["api_key"] == k.strip_edges() and r["name"] == "Name & Co" and r["url"] == "https://cad.example.net"):
			round_ok = false
			print("  round trip failed for ", k, " -> ", r)
	check("build then parse returns the same name, address and key for awkward keys", round_ok)

	# --- codes in DIDSA-CAD's encoding (tests/fixtures/make_pairing_codes.py: Dart's encodeQueryComponent via Python's quote_plus) --------------------------
	var vectors = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/pairing_codes.json"))
	var wrong_vectors := 0
	for v in vectors:
		var r := Payload.parse(v["code"])
		if not (r["ok"] and r["name"] == str(v["name"]).strip_edges().substr(0, 64) and r["url"] == v["url"] and r["api_key"] == str(v["key"]).strip_edges()):
			wrong_vectors += 1
			if wrong_vectors < 4:
				print("  vector failed: ", v, " -> ", r)
	check("%d generated codes (spaces, symbols, accents, CJK, emoji) decode to exactly what was encoded" % vectors.size(), vectors.size() == 60 and wrong_vectors == 0)

	# --- refused ------------------------------------------------------------------------------------------------------------------
	check("an empty string", refused("", "not a DIDSA"))
	check("any other QR code's text", refused("https://example.com/", "not a DIDSA"))
	check("a Wi-Fi code", refused("WIFI:S:home;T:WPA;P:password;;", "not a DIDSA"))
	check("the scheme alone (no details)", refused("didsa-vr:1", "no details"))
	check("a newer version names the versions", refused("didsa-vr:2?u=https%3A%2F%2Fa.example.net&k=k", "version 2"))
	check("version 0", refused("didsa-vr:0?u=https%3A%2F%2Fa.example.net&k=k", "version 0"))
	check("a version that is not a number", refused("didsa-vr:x?u=https%3A%2F%2Fa.example.net&k=k", "not a DIDSA"))
	check("upper-case scheme is not DIDSA's", refused("DIDSA-VR:1?u=https%3A%2F%2Fa.example.net&k=k", "not a DIDSA"))
	check("no address", refused("didsa-vr:1?n=x&k=k", "no server address"))
	check("no key", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net", "no API key"))
	check("an empty key", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=", "no API key"))
	check("plain http to the internet", refused("didsa-vr:1?u=http%3A%2F%2Fexample.com&k=k", "https"))
	check("localhost", refused("didsa-vr:1?u=http%3A%2F%2Flocalhost%3A8000&k=k", "localhost"))
	check("the emulator alias", refused("didsa-vr:1?u=http%3A%2F%2F10.0.2.2%3A8000&k=k", "emulator"))
	check("a link-local address", refused("didsa-vr:1?u=http%3A%2F%2F169.254.1.1&k=k", "link-local"))
	check("credentials in the address", refused("didsa-vr:1?u=https%3A%2F%2Fuser%3Apw%40a.example.net&k=k", "not a valid"))
	check("a file: address", refused("didsa-vr:1?u=file%3A%2F%2F%2Fetc%2Fpasswd&k=k", "not a valid"))
	check("a javascript: address", refused("didsa-vr:1?u=javascript%3Aalert(1)&k=k", "not a valid"))
	check("the address twice (ambiguous)", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net&u=https%3A%2F%2Fevil.example.net&k=k", "twice"))
	check("a newline inside the key", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=a%0Ab", "characters"))
	check("a NUL inside the name", refused("didsa-vr:1?n=a%00b&u=https%3A%2F%2Fa.example.net&k=k", "characters"))
	check("a value that is too long", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=" + "k".repeat(600), "too long"))
	check("a whole code that is too long", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=k&zz=" + "z".repeat(3000), "too long"))
	check("a relay address that is not allowed refuses the whole code", refused("didsa-vr:1?u=https%3A%2F%2Fa.example.net&k=k&r=http%3A%2F%2Fexample.com", "relay"))

	# --- recognising ours ------------------------------------------------------------------------------------------------------------
	check("looks_like_pairing: ours (any case) yes, others no", Payload.looks_like_pairing("didsa-vr:1?x") and Payload.looks_like_pairing(" DIDSA-VR:9") and not Payload.looks_like_pairing("https://a.example.net") and not Payload.looks_like_pairing(""))
	print("SMOKE PASSED")
	quit()
