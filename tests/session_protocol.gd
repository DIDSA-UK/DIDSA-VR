extends SceneTree
## P2: scripts/session/session_protocol.gd, the pure parts of the session wire format: the join code's alphabet and how a typed one is cleaned, the join QR
## text (build and parse, and what is refused), the hub address rules, the 12-number transform in millimetres (rounding, mirror, a demo's metres), the
## `place` array, and the words for each hub error. Headless, no sockets: tests/session_client.gd runs the client against a fake hub.
## Run: "$GODOT" --headless --path . --script res://tests/session_protocol.gd  (see tests/README.md)

const P := preload("res://scripts/session/session_protocol.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _initialize() -> void:
	# --- codes
	_check(P.normalise_code("k7x-q4m") == "K7XQ4M" and P.normalise_code(" k7x q4m\n") == "K7XQ4M", "a typed code is upper-cased and stripped of dashes and spaces, as the hub does")
	_check(P.normalise_code("ké7") == "K7", "an accented letter is dropped, not mapped")
	_check(P.code_is_valid("K7XQ4M") and P.code_is_valid("ABCDEF") and P.code_is_valid("234567"), "a six-character code from the alphabet is valid")
	_check(not P.code_is_valid("K7XQ4") and not P.code_is_valid("K7XQ4MM") and not P.code_is_valid(""), "five, seven and no characters are not")
	_check(not P.code_is_valid("K0XQ4M") and not P.code_is_valid("K1XQ4M") and not P.code_is_valid("KOXQ4M") and not P.code_is_valid("KIXQ4M") and not P.code_is_valid("KLXQ4M"), "0 O 1 I L are not in the alphabet, so a typo of them is caught before the hub is asked")
	_check(P.code_for_display("K7XQ4M") == "K7X Q4M" and P.code_for_display("ab") == "ab", "a code is shown in two groups of three")
	# --- the join QR text
	var uri := P.build_join_uri("wss://sessions.example.net:8300/", "K7XQ4M")
	_check(uri == "didsa-join:1?h=wss%3A%2F%2Fsessions.example.net%3A8300&c=K7XQ4M", "the join text is didsa-join:1 with the hub percent-encoded (no trailing slash) and the code: " + uri)
	var parsed := P.parse_join(uri)
	_check(parsed["ok"] and parsed["hub_url"] == "wss://sessions.example.net:8300" and parsed["code"] == "K7XQ4M", "it parses back to the same hub and code")
	_check(P.parse_join("didsa-join:1?c=k7x-q4m")["code"] == "K7XQ4M" and P.parse_join("didsa-join:1?c=k7x-q4m")["hub_url"] == "", "a join text with no hub keeps the code and leaves the hub empty (use the hub you know)")
	var hub_made := P.parse_join("didsa-join:1?h=wss%3A%2F%2Fa.example.net%2Fws&c=K7XQ4M&future=1&x=%00")
	_check(hub_made["ok"] and hub_made["hub_url"] == "wss://a.example.net", "a trailing /ws is dropped from the hub and keys from a newer app are ignored")
	_check(P.parse_join("didsa-join:1?h=https%3A%2F%2Fa.example.net&c=K7XQ4M")["hub_url"] == "wss://a.example.net", "an https address is taken as wss")
	_check(P.parse_join("DIDSA-JOIN:1?c=K7XQ4M")["ok"], "the scheme is not case-sensitive")
	var lan := P.parse_join("didsa-join:1?h=ws%3A%2F%2F192.168.1.20%3A8300&c=K7XQ4M")
	_check(lan["ok"] and lan["hub_url"] == "ws://192.168.1.20:8300", "plain ws:// is allowed to a local-network address")
	var refused := {
		"plain ws to the internet": "didsa-join:1?h=ws%3A%2F%2Fsessions.example.net&c=K7XQ4M",
		"localhost": "didsa-join:1?h=wss%3A%2F%2Flocalhost%3A8300&c=K7XQ4M",
		"ftp": "didsa-join:1?h=ftp%3A%2F%2Fa.example.net&c=K7XQ4M",
		"no code": "didsa-join:1?h=wss%3A%2F%2Fa.example.net",
		"a code with an O": "didsa-join:1?c=K7XQ4O",
		"a short code": "didsa-join:1?c=K7XQ4",
		"version 2": "didsa-join:2?c=K7XQ4M",
		"no version": "didsa-join:?c=K7XQ4M",
		"no query": "didsa-join:1",
		"a pairing code": "didsa-vr:1?n=x&u=https%3A%2F%2Fa.example.net&k=k",
		"c twice": "didsa-join:1?c=K7XQ4M&c=K7XQ4N",
		"a control character": "didsa-join:1?h=wss%3A%2F%2Fa.example.net%0A&c=K7XQ4M",
		"too long": "didsa-join:1?c=K7XQ4M&h=" + "a".repeat(2000),
		"nothing": "",
	}
	for name in refused:
		var r := P.parse_join(str(refused[name]))
		_check(not r["ok"] and str(r["error"]) != "" and r["code"] == "" and r["hub_url"] == "", "a join text is refused: " + name)
	_check(P.looks_like_join(" didsa-join:1?c=K7XQ4M ") and not P.looks_like_join("didsa-vr:1?n=x") and not P.looks_like_join("hello"), "looks_like_join tells our scheme from a pairing code and from any other QR code")
	# --- hub addresses
	_check(P.hub_address("wss://sessions.example.net")["ok"] and P.hub_address("wss://sessions.example.net")["warning"] == "", "a public wss hub is fine, no warning")
	_check(P.hub_address("ws://192.168.1.20:8300")["ok"] and P.hub_address("ws://192.168.1.20:8300")["warning"] != "", "a LAN ws hub is allowed with a warning")
	_check(not P.hub_address("ws://127.0.0.1:8300")["ok"] and P.hub_address("ws://127.0.0.1:8300", true)["ok"] and P.hub_address("ws://127.0.0.1:8300", true)["url"] == "ws://127.0.0.1:8300", "localhost is refused unless a test or a desktop preview allows it")
	_check(P.socket_url("wss://h.example.net") == "wss://h.example.net/ws" and P.socket_url("wss://h.example.net/ws") == "wss://h.example.net/ws" and P.socket_url("wss://h.example.net/") == "wss://h.example.net/ws", "the socket is <hub>/ws, once")
	_check(P.health_url("wss://h.example.net/ws") == "https://h.example.net/health" and P.health_url("ws://192.168.1.20:8300") == "http://192.168.1.20:8300/health", "the hub's /health is on the same host over http(s)")
	# --- transforms
	var t := Transform3D(Basis(Vector3(0.3, 0.9, 0.1).normalized(), 0.7), Vector3(12.3456, -7.891, 1500.5))
	var a := P.xf_to_array(t)
	_check(a.size() == 12 and P.is_numbers(a, 12), "a transform is 12 numbers")
	var back: Transform3D = P.xf_from_array(a)
	_check(back.origin.distance_to(t.origin) < 0.01 and back.basis.x.distance_to(t.basis.x) < 1e-5 and back.basis.z.distance_to(t.basis.z) < 1e-5, "it round-trips within 0.01 mm and 1e-5")
	_check(absf(a[9] - 12.35) < 1e-9 and absf(a[10] + 7.89) < 1e-9 and absf(a[11] - 1500.5) < 1e-9 and JSON.stringify(a).contains("12.35,-7.89,1500.5"), "the origin is rounded to 0.01 mm (and prints that way)")
	_check(JSON.stringify(a).length() < 140, "the rounded numbers are short on the wire (%d bytes for 12)" % JSON.stringify(a).length())
	var mirror := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)), Vector3(5, 0, 0))
	var mirrored: Transform3D = P.xf_from_array(P.xf_to_array(mirror))
	_check(mirrored.basis.determinant() < 0 and mirrored.basis.x.is_equal_approx(Vector3(-1, 0, 0)), "a mirrored transform keeps its mirror (twelve numbers, not a quaternion)")
	var demo := Transform3D(Basis.IDENTITY, Vector3(0.5, 1.0, -2.0)) # a demo glb is in metres
	var demo_a := P.xf_to_array(demo, 1000.0)
	_check(demo_a[9] == 500.0 and demo_a[10] == 1000.0 and demo_a[11] == -2000.0, "a demo's metres go out as millimetres")
	_check((P.xf_from_array(demo_a, 1000.0) as Transform3D).origin.is_equal_approx(demo.origin), "...and come back as metres")
	_check(P.xf_from_array([1, 2, 3]) == null and P.xf_from_array("no") == null and P.xf_from_array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, INF]) == null and P.xf_from_array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, "x"]) == null, "a malformed or non-finite array is refused (null)")
	_check(not P.is_numbers([true, 0, 0], 3) and P.is_numbers([1, 2.5, -3], 3) and not P.is_numbers([1, 2], 3), "booleans are not numbers")
	var place := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001).rotated(Vector3.UP, 0.5), Vector3(0.123456, 1.0, -1.5))
	var place_a := P.place_to_array(place)
	var place_back: Transform3D = P.xf_from_array(place_a)
	_check(is_equal_approx(place_back.basis.get_scale().x, 0.001) and place_back.origin.distance_to(place.origin) < 1e-4, "the model's place keeps its 0.001 scale (a unit basis would lose it to rounding)")
	var pose := P.pose_to_array(Vector3(1.234, 5.678, 9.0), Quaternion(Vector3.UP, 0.4))
	_check(pose.size() == 7 and P.is_numbers(pose, 7), "a pose is 7 numbers")
	# --- words
	_check(P.error_text("bad_code").contains("No session has that code") and P.error_text("room_full").contains("full") and P.error_text("removed").contains("removed"), "the hub's error codes have plain words")
	_check(P.error_text("something_new", "from the hub") == "from the hub" and P.error_text("something_new").contains("something_new"), "an unknown code shows the hub's own message, or the code")
	var every := true
	for code in ["proto_unsupported", "bad_code", "room_full", "room_locked", "removed", "not_allowed", "rate_limited", "too_big", "resume_expired", "hub_full", "bad_message"]:
		every = every and P.ERROR_WORDS.has(code)
	_check(every, "every code in the scope's list has words")
	_check(P.end_text("ended").contains("ended") and P.end_text("presenter_gone").contains("did not come back") and P.end_text("zzz") != "", "the end reasons have words")
	_check(P.colour_of("#E8590C").is_equal_approx(Color.html("#E8590C")) and P.colour_of("nonsense", Color.RED) == Color.RED, "the hub's colour is read, with a fallback")
	quit()
