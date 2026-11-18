extends SceneTree
## The Servers page's Test button against a real (stub) HTTP server (tests/helpers/stub_health_server.py, started here with python3): a right key
## answers, a wrong key is refused in words, 403 and 500 are named, a path with no route is named, a port with nothing listening is "could not
## reach". Also what each HTTPRequest outcome is called (pure). The stub is not DIDSA-CAD: it only says whether the headset's request, headers and
## answer handling work on a real socket. A real backend answering is tests/e2e_servers.gd's job (not written: no backend was available).
## Run: "$GODOT" --headless --path . --script res://tests/server_probe.gd   (needs python3 on the PATH)

const ServerProbe := preload("res://scripts/landing/server_probe.gd")
const PORT := 18765
const KEY := "stubkey"

var pid := -1


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func _initialize() -> void:
	var script := ProjectSettings.globalize_path("res://tests/helpers/stub_health_server.py")
	pid = OS.create_process("python3", ["-I", script, str(PORT), KEY])
	var probe := ServerProbe.new()
	root.add_child(probe)
	var base := "http://127.0.0.1:%d" % PORT

	# wait for the stub to listen (up to ~8 s)
	var up := false
	for i in 40:
		var r: Dictionary = await probe.check(base, KEY)
		if r["code"] == 200:
			up = true
			break
		await create_timer(0.2).timeout
	check("the stub server is up", up)
	if not up:
		_finish()
		return

	var ok: Dictionary = await probe.check(base, KEY)
	check("the right key: it answers", ok["ok"] and ok["code"] == 200 and ok["message"] == "The server answers.")
	var wrong: Dictionary = await probe.check(base, "not the key")
	check("a wrong key is refused, in words", not wrong["ok"] and wrong["code"] == 401 and "refused the API key" in wrong["message"])
	var forbidden: Dictionary = await probe.check(base + "/forbidden", KEY)
	check("403 is also a refused key", not forbidden["ok"] and "refused the API key" in forbidden["message"])
	var broken: Dictionary = await probe.check(base + "/broken", KEY)
	check("a server error is named by its number", not broken["ok"] and broken["code"] == 500 and "500" in broken["message"])
	var missing: Dictionary = await probe.check(base + "/nothing", KEY)
	check("a path with no health route is named by its number", not missing["ok"] and missing["code"] == 404 and "404" in missing["message"])
	var trailing: Dictionary = await probe.check(base + "/", KEY)
	check("a trailing slash on the address does not matter", trailing["ok"])
	var nobody: Dictionary = await probe.check("http://127.0.0.1:%d" % (PORT + 1), KEY)
	check("nothing listening: could not reach, asking if it is running", not nobody["ok"] and "Could not reach" in nobody["message"])

	check("timeouts are described", "No answer" in ServerProbe.describe(HTTPRequest.RESULT_TIMEOUT, 0)["message"])
	check("a TLS failure mentions the certificate", "certificate" in ServerProbe.describe(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR, 0)["message"])
	check("on Android a connect or resolve failure names the Internet permission (Godot's export leaves it off)", "Internet permission" in ServerProbe.describe(HTTPRequest.RESULT_CANT_CONNECT, 0, true)["message"] and "Internet permission" in ServerProbe.describe(HTTPRequest.RESULT_CANT_RESOLVE, 0, true)["message"])
	check("...not on a PC, and not for a timeout", not ("Internet permission" in ServerProbe.describe(HTTPRequest.RESULT_CANT_CONNECT, 0, false)["message"]) and not ("Internet permission" in ServerProbe.describe(HTTPRequest.RESULT_TIMEOUT, 0, true)["message"]))
	check("a name that does not resolve says so", "did not resolve" in ServerProbe.describe(HTTPRequest.RESULT_CANT_RESOLVE, 0, false)["message"])
	check("/health's session_hub is read (P2): the address, trimmed", ServerProbe.hub_in_health('{"status":"ok","session_hub":" wss://s.example.net "}'.to_utf8_buffer()) == "wss://s.example.net")
	check("...none from an older backend, a non-string, junk or an empty body", ServerProbe.hub_in_health('{"status":"ok"}'.to_utf8_buffer()) == "" and ServerProbe.hub_in_health('{"session_hub":5}'.to_utf8_buffer()) == "" and ServerProbe.hub_in_health("not json".to_utf8_buffer()) == "" and ServerProbe.hub_in_health(PackedByteArray()) == "")
	check("any 2xx is fine", ServerProbe.describe(HTTPRequest.RESULT_SUCCESS, 204)["ok"])
	_finish()


func _finish() -> void:
	if pid > 0:
		OS.kill(pid)
	print("SMOKE PASSED")
	quit()
