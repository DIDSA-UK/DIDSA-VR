extends Node
## Live sessions, the app's side (DIDSA-CAD docs/live-sessions-scope.md): what Host Session, Join Session, End and Leave do, and who the app is while one runs.
## main.gd owns one of these (`main.session`); the landing's monolith drives it (launcher_window.gd's Host, Join and Session pages) and the other session scripts hang off it:
##   session_client.gd     the wire: one WebSocket to the hub, host / join / resume, the roster, reconnecting
##   session_publisher.gd  the PRESENTER: turns what the world does (poses, hide, section, place, a document change, what they are doing) into messages
##   session_observer.gd   an OBSERVER: fetches the model with the view token only, then applies the presenter's messages, smoothed
## Roles: "" (not in a session), "presenter" or "observer". The same app runs both; the role decides which tools exist (main.gd `apply_session_role`).
##
## Hosting needs, in this order: a model that can be shared (a document on the backend, or a demo glb shipped in the APK; a bare file from a folder cannot be, LS-9), the hub
## (the saved server's hub address and key, else the address its /health advertises with a key), and for a backend model a read-only VIEW TOKEN minted by the backend
## (POST /document/view-tokens). End and a failed start revoke every token this session minted. Nothing the hub is sent contains the CAD key; the hub key rides only in the
## WebSocket handshake.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Http := preload("res://scripts/session/session_http.gd")
const Publisher := preload("res://scripts/session/session_publisher.gd")
const Observer := preload("res://scripts/session/session_observer.gd")
const Presence := preload("res://scripts/session/session_presence.gd")
const Avatars := preload("res://scripts/session/session_avatars.gd")
const Navigation := preload("res://scripts/session/session_navigation.gd")
const Cursor := preload("res://scripts/session/session_cursor.gd")
const Marks := preload("res://scripts/session/session_marks.gd")
const OwnView := preload("res://scripts/session/session_own_view.gd")
const DocumentRevision := preload("res://scripts/session/document_revision.gd")
const BackendSession := preload("res://scripts/backend_session.gd")
const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const ServerAddress := preload("res://scripts/landing/server_address.gd")

signal changed() ## anything the Host / Join / Session pages show changed
signal ended_for_me(text: String) ## the session is over for this app (ended, removed, lost): the words

const TOKEN_RENEW_BEFORE_S := 3600.0 ## the presenter mints a fresh token when the one in use has less than this left
const RENEW_CHECK_S := 30.0
const TOKEN_CHECK_S := 60.0 ## the presenter asks the backend, as an observer would, whether the token still works (a backend that restarted has forgotten every token)

var main: Node
var client: Node ## session_client.gd
var http: Node ## session_http.gd
var publisher: Node
var observer: Node
var presence: Node ## what this person sends the others (head, hands, laser): session_presence.gd
var avatars: Node3D ## the others, drawn: session_avatars.gd
var navigation: Node ## Go to presenter, Follow presenter, Gather everyone: session_navigation.gd
var cursor: Node3D ## P4: an observer's drone cursor: session_cursor.gd
var marks: Node3D ## P4: Share, Ping, Look here, Raise hand and what others showed: session_marks.gd
var own_view: Node ## P4: what an observer changed in their own view, and Reset my view: session_own_view.gd
var role := ""
var starting := false ## host_session() / join_session() is mid-flight
var model: Dictionary = {} ## what is being shown to the session: {kind, ...} as in the hub's `host` message (with `title`)
var join_uri := ""
var hub_in_use := ""
var last_error := ""
var allow_loopback := OS.get_environment("DIDSA_SESSION_ALLOW_LOOPBACK") != "" ## tests, and a desktop preview with a hub on the same machine
var transport_factory: Callable = Callable() ## tests: makes the client's transports (a fake hub)
var advertised_hub: Dictionary = {} ## backend url -> the hub address its /health said (this run)

var _tokens: Array = [] ## the view tokens this app minted for the session: [{token, expires_at}]
var _renew_clock := 0.0
var _check_clock := 0.0
var _renewing := false
var _leaving := false ## this app is the one closing the session: client.closed is not news


func setup(p_main: Node) -> void:
	main = p_main
	http = Http.new()
	http.name = "Http"
	add_child(http)
	client = Client.new()
	client.name = "Client"
	add_child(client)
	if transport_factory.is_valid():
		client.transport_factory = transport_factory
	client.welcomed.connect(_on_welcomed)
	client.closed.connect(_on_closed)
	client.roster_changed.connect(func() -> void: changed.emit())
	client.reconnecting.connect(func(_n: int) -> void: changed.emit())
	client.state_changed.connect(func(_s: int) -> void: changed.emit())
	publisher = Publisher.new()
	publisher.name = "Publisher"
	add_child(publisher)
	observer = Observer.new()
	observer.name = "Observer"
	add_child(observer)
	presence = Presence.new()
	presence.name = "Presence"
	add_child(presence)
	avatars = Avatars.new()
	avatars.name = "Avatars"
	add_child(avatars)
	navigation = Navigation.new()
	navigation.name = "Navigation"
	add_child(navigation)
	cursor = Cursor.new()
	cursor.name = "Cursor"
	add_child(cursor)
	marks = Marks.new()
	marks.name = "Marks"
	add_child(marks)
	own_view = OwnView.new()
	own_view.name = "OwnView"
	add_child(own_view)


func use_transport(factory: Callable) -> void:
	## Tests: every socket this session opens comes from `factory` (tests/fake_session_hub.gd).
	transport_factory = factory
	if client != null:
		client.transport_factory = factory


func is_active() -> bool:
	return role != "" or starting


func is_presenter() -> bool:
	return role == "presenter"


func is_observer() -> bool:
	return role == "observer"


func code() -> String:
	return str(client.room.get("code", "")) if client != null else ""


# --- What can be hosted, and where the hub is -------------------------------------------------------------------------------------

func hostable_model() -> Dictionary:
	## {ok, source: {kind, ...}, title, error}: the model Host Session would share. A document on the backend (a view token is minted for it) or a demo glb (every headset has
	## the same file: it is loaded by its path). A bare .glb opened from a folder cannot be shared: it would mean sending a file (decision LS-9).
	if main.is_observer():
		return {"ok": false, "source": {}, "title": "", "error": "You are watching someone else's session."}
	if main.document_is_demo and main.shown_demo_path != "":
		var title: String = main.shown_demo_path.get_file().get_basename().replace("_", " ")
		for entry in DemoCatalog.models():
			if str(entry["path"]) == main.shown_demo_path:
				title = str(entry["name"])
		return {"ok": true, "source": {"kind": "demo", "path": main.shown_demo_path}, "title": title, "error": ""}
	if main.has_backend() and main.current_root_part_id() != "":
		return {"ok": true, "source": {"kind": "backend", "root_part_id": main.current_root_part_id(), "rev": DocumentRevision.latest, "quality": main.quality, "tier": "full" if main.tier == "" else main.tier},
			"title": "", "error": ""}
	return {"ok": false, "source": {}, "title": "", "error": "Open a model first: a file from your server, or one of the demo models. A file opened from a folder on this headset cannot be shared."}


static func choose_hub(saved_url: String, saved_key: String, advertised_url: String) -> Dictionary:
	## {ok, url, key, source, error}. The hub the saved server names (address and key, from Servers, a pairing code or secrets.cfg); failing that the address the backend's /health
	## advertises, which still needs the hub's key (the backend never knows it).
	var url := saved_url.strip_edges()
	var key := saved_key.strip_edges()
	if url != "" and key != "":
		return {"ok": true, "url": url, "key": key, "source": "saved", "error": ""}
	if url != "" and key == "":
		return {"ok": false, "url": url, "key": "", "source": "saved", "error": "The hub's key is missing. Add it under Servers > Hub (SESSION_HUB_API_KEY on the hub's machine)."}
	if advertised_url.strip_edges() != "":
		if key != "":
			return {"ok": true, "url": advertised_url.strip_edges(), "key": key, "source": "health", "error": ""}
		return {"ok": false, "url": advertised_url.strip_edges(), "key": "", "source": "health", "error": "Your server says its session hub is at %s, but its key is not set here. Add it under Servers > Hub (SESSION_HUB_API_KEY on the hub's machine)." % advertised_url.strip_edges()}
	return {"ok": false, "url": "", "key": "", "source": "", "error": "No session hub is set. Add its address and key under Servers > Hub, or scan DIDSA-CAD's Connect a VR headset code after setting the hub there."}


func resolve_hub() -> Dictionary:
	## choose_hub() for the server in use, asking its /health for an advertised hub when none is saved. Then the address rules.
	var advertised := ""
	if main.hub_url.strip_edges() == "" and main.has_backend():
		advertised = await fetch_advertised_hub()
	var chosen := choose_hub(main.hub_url, main.hub_key, advertised)
	if not chosen["ok"]:
		return chosen
	var checked := Protocol.hub_address(str(chosen["url"]), allow_loopback)
	if not checked["ok"]:
		return {"ok": false, "url": str(chosen["url"]), "key": "", "source": chosen["source"], "error": "The hub's address is not allowed: %s" % checked["message"]}
	chosen["url"] = checked["url"]
	return chosen


func fetch_advertised_hub() -> String:
	## The backend's /health `session_hub` ("" when none or on error). Remembered for the run.
	if advertised_hub.has(main.backend_url):
		return str(advertised_hub[main.backend_url])
	var response: Dictionary = await http.call_http(HTTPClient.METHOD_GET, main.backend_url.rstrip("/") + "/health", BackendSession.headers(main.api_key))
	if int(response.get("code", 0)) != 200:
		return ""
	var parsed = Http.json_of(response)
	var value := str((parsed as Dictionary).get("session_hub", "")).strip_edges() if parsed is Dictionary and (parsed as Dictionary).get("session_hub") is String else ""
	advertised_hub[main.backend_url] = value
	return value


# --- Host -----------------------------------------------------------------------------------------------------------------------

func host_session() -> Dictionary:
	## {ok, error}. Mints a view token, opens a room on the hub, and starts publishing. The code and QR are then in `client.room`.
	if is_active():
		return _fail_host("A session is already running.")
	starting = true
	last_error = ""
	changed.emit()
	var offered := hostable_model()
	if not offered["ok"]:
		return _fail_host(str(offered["error"]))
	var hub := await resolve_hub()
	if not hub["ok"]:
		return _fail_host(str(hub["error"]))
	var source: Dictionary = offered["source"]
	var title: String = offered["title"]
	var token := ""
	var expires_at := 0.0
	DocumentRevision.reset()
	if source["kind"] == "backend":
		var minted := await _mint_token(str(source["root_part_id"]))
		if not minted["ok"]:
			return _fail_host(str(minted["error"]))
		token = str(minted["token"])
		expires_at = float(minted["expires_at"])
		source["rev"] = int(minted["rev"])
		DocumentRevision.reset(int(minted["rev"]))
		title = await _root_title(str(source["root_part_id"]))
	model = _with_title(source, title)
	var info := {"name": display_name(), "device": device_kind(), "client": client_name(), "model": model,
		"backend_url": main.backend_url if source["kind"] == "backend" else "", "view_token": token, "view_expires_at": expires_at}
	if not client.host(str(hub["url"]), str(hub["key"]), info):
		await _revoke_tokens()
		return _fail_host(last_closed_text("Could not reach the hub."))
	hub_in_use = str(hub["url"])
	await _until_settled()
	if not client.is_live():
		var text := last_closed_text("The hub did not accept the session.")
		await _revoke_tokens()
		return _fail_host(text)
	starting = false
	changed.emit()
	return {"ok": true, "error": ""}


func end_session() -> void:
	## The presenter ends it for everyone and the token is revoked. (An observer's version is leave_session().)
	if role != "presenter":
		return
	publisher.stop()
	_leaving = true
	client.end_session()
	_leaving = false
	await _revoke_tokens()
	_become("")
	main.say("You ended the session.")


# --- Join -----------------------------------------------------------------------------------------------------------------------

func join_session(hub_url: String, code_text: String) -> Dictionary:
	## {ok, error}. By code and hub address (a scanned join code carries both). The model it shows replaces whatever is open here, so unsaved changes are asked about first.
	if is_active():
		return {"ok": false, "error": "A session is already running."}
	var code := Protocol.normalise_code(code_text)
	if not Protocol.code_is_valid(code):
		return {"ok": false, "error": "That is not a session code: six letters and digits (no 0, O, 1, I or L)."}
	var checked := Protocol.hub_address(hub_url, allow_loopback)
	if not checked["ok"]:
		return {"ok": false, "error": "The hub's address is not allowed: %s" % checked["message"]}
	if not main.confirm_discard("Join a session", join_session.bind(hub_url, code_text)):
		return {"ok": false, "error": "You have unsaved changes: choose what to do with them, then join again."}
	starting = true
	last_error = ""
	changed.emit()
	if not client.join(str(checked["url"]), code, {"name": display_name(), "device": device_kind(), "client": client_name()}):
		starting = false
		last_error = last_closed_text("Could not reach the hub.")
		changed.emit()
		return {"ok": false, "error": last_error}
	hub_in_use = str(checked["url"])
	await _until_settled()
	if not client.is_live():
		starting = false
		last_error = last_closed_text("Could not join.")
		changed.emit()
		return {"ok": false, "error": last_error}
	main.remember_session_hub(hub_in_use)
	starting = false
	changed.emit()
	return {"ok": true, "error": ""}


func leave_session() -> void:
	## An observer leaves: a clean goodbye, the shared model is put away and the app is the person's own again.
	if role != "observer":
		return
	observer.stop()
	_leaving = true
	client.leave()
	_leaving = false
	_become("")
	main.session_unload_shared_model()
	main.say("You left the session.")
	main.go_home()


# --- What the pages show --------------------------------------------------------------------------------------------------------

func display_name() -> String:
	return main.device_name()


func device_kind() -> String:
	if OS.get_name() == "Android":
		return "quest"
	return "pcvr" if main.xr_interface != null and main.xr_interface.is_initialized() else "desktop"


func client_name() -> String:
	return "didsa-vr/%s" % str(ProjectSettings.get_setting("application/config/version", "dev"))


func status_line() -> String:
	## One line for the monolith and the status text.
	if starting:
		return "Starting a session ..."
	if role == "":
		return ""
	var state_note := ""
	if client.state == Client.State.RECONNECTING:
		state_note = " (reconnecting ...)"
	elif role == "observer" and not client.presenter_connected():
		state_note = " (presenter reconnecting ...)"
	var count: int = client.participants.size()
	if role == "presenter":
		return "Hosting %s with %d %s%s" % [Protocol.code_for_display(code()), count, "person" if count == 1 else "people", state_note]
	return "Watching %s%s" % [str(client.presenter().get("name", "the presenter")), state_note]


func last_closed_text(fallback: String) -> String:
	return str(_last_closed_text) if _last_closed_text != "" else fallback


# --- Internals ------------------------------------------------------------------------------------------------------------------

var _last_closed_text := ""


func _until_settled() -> void:
	## Waits for the first welcome or the hub saying no. (The client is ticked by the tree.)
	_last_closed_text = ""
	while client.state == Client.State.CONNECTING or client.state == Client.State.AWAITING_WELCOME:
		await get_tree().process_frame


func _on_welcomed(welcome: Dictionary, resumed: bool) -> void:
	if resumed:
		changed.emit()
		return
	join_uri = str((welcome.get("room", {}) as Dictionary).get("join_uri", ""))
	var new_role := str((welcome.get("you", {}) as Dictionary).get("role", ""))
	_become(new_role)
	avatars.start(main, client)
	navigation.start(main, client, avatars)
	cursor.start(main, client)
	presence.start(main, client, navigation, cursor)
	marks.start(main, client, cursor, navigation)
	if new_role == "presenter":
		publisher.start(main, client, model if not model.is_empty() else hostable_model()["source"], http)
	else:
		own_view.start(main, client, observer)
		for hand in main.session_hands():
			hand.own_view_ref = own_view
		observer.start(main, client, http, own_view)
	changed.emit()


func _on_closed(kind: String, text: String) -> void:
	_last_closed_text = text
	if _leaving:
		return
	if role == "":
		return # a failed start: host_session() / join_session() report it
	var was := role
	publisher.stop()
	observer.stop()
	if was == "presenter":
		_revoke_tokens()
	_become("")
	if was == "observer":
		main.session_unload_shared_model()
	main.say(text)
	ended_for_me.emit(text)
	changed.emit()


func _become(new_role: String) -> void:
	role = new_role
	if new_role == "":
		marks.stop()
		presence.stop()
		cursor.stop()
		own_view.stop()
		for hand in main.session_hands():
			hand.own_view_ref = null
		navigation.stop()
		avatars.stop()
		join_uri = ""
		model = {}
		hub_in_use = ""
		_tokens.clear()
	main.apply_session_role(new_role)
	changed.emit()


func _fail_host(text: String) -> Dictionary:
	model = {}
	starting = false
	last_error = text
	changed.emit()
	return {"ok": false, "error": text}


func _with_title(source: Dictionary, title: String) -> Dictionary:
	var out := source.duplicate()
	if title != "":
		out["title"] = title
	return out


func _mint_token(root_part_id: String) -> Dictionary:
	## {ok, token, expires_at, rev, error}: POST /document/view-tokens (the presenter's own call: the CAD key and document session).
	var response: Dictionary = await http.call_http(HTTPClient.METHOD_POST, "%s/document/view-tokens" % main.backend_url.rstrip("/"),
		BackendSession.headers(main.api_key, true), JSON.stringify({"root_part_id": root_part_id}))
	DocumentRevision.note(response.get("headers", []))
	var code := int(response.get("code", 0))
	if int(response.get("result", 0)) != HTTPRequest.RESULT_SUCCESS or code != 201:
		var why := "the server could not be reached" if code == 0 else ("the server answered %d%s" % [code, ": " + Http.detail_of(response) if Http.detail_of(response) != "" else ""])
		if code == 404 or code == 405:
			why = "this server is too old to share a session (no view tokens): update DIDSA-CAD"
		return {"ok": false, "token": "", "expires_at": 0.0, "rev": 0, "error": "Could not get a read-only link for the observers: %s." % why}
	var parsed = Http.json_of(response)
	if not (parsed is Dictionary) or str((parsed as Dictionary).get("token", "")) == "":
		return {"ok": false, "token": "", "expires_at": 0.0, "rev": 0, "error": "The server's answer for the observers' read-only link could not be read."}
	var record := {"token": str(parsed["token"]), "expires_at": float(parsed.get("expires_at", 0.0))}
	_tokens.append(record)
	return {"ok": true, "token": record["token"], "expires_at": record["expires_at"], "rev": int(parsed.get("rev", 0)), "error": ""}


func _revoke_tokens() -> void:
	## DELETE every view token this session minted: after End an observer's link stops working at once.
	var minted := _tokens.duplicate()
	_tokens.clear()
	for record in minted:
		await http.call_http(HTTPClient.METHOD_DELETE, "%s/document/view-tokens/%s" % [main.backend_url.rstrip("/"), str(record["token"])], BackendSession.headers(main.api_key))


func _root_title(root_part_id: String) -> String:
	## The root Part's name for the session's title (never a file name). "" if it cannot be read.
	var response: Dictionary = await http.call_http(HTTPClient.METHOD_GET, "%s/document/parts/%s" % [main.backend_url.rstrip("/"), root_part_id], BackendSession.headers(main.api_key))
	DocumentRevision.note(response.get("headers", []))
	var parsed = Http.json_of(response)
	return str((parsed as Dictionary).get("name", "")) if parsed is Dictionary and int(response.get("code", 0)) == 200 else ""


func _process(delta: float) -> void:
	if role != "presenter" or _renewing or _tokens.is_empty():
		return
	_renew_clock += delta
	_check_clock += delta
	if _renew_clock >= RENEW_CHECK_S:
		_renew_clock = 0.0
		var latest: Dictionary = _tokens[-1]
		if float(latest["expires_at"]) > 0.0 and float(latest["expires_at"]) - Time.get_unix_time_from_system() < TOKEN_RENEW_BEFORE_S:
			renew_token()
	if _check_clock >= TOKEN_CHECK_S:
		_check_clock = 0.0
		check_token_alive()


func check_token_alive() -> void:
	## GET /document/view-state with the token and no key, exactly what an observer can do: 401 means the backend no longer knows it, so mint a new one and tell the observers.
	if role != "presenter" or _renewing or _tokens.is_empty() or model.get("kind", "") != "backend":
		return
	var response: Dictionary = await http.call_http(HTTPClient.METHOD_GET, "%s/document/view-state" % main.backend_url.rstrip("/"), ["X-View-Token: %s" % str(_tokens[-1]["token"])])
	if int(response.get("code", 0)) == 401:
		renew_token()


func renew_token() -> bool:
	## The presenter mints a fresh read-only token and tells the observers (the hub keeps it for ones that join or resume later). Also what to call when the backend lost its tokens.
	if role != "presenter" or model.get("kind", "") != "backend":
		return false
	_renewing = true
	var minted := await _mint_token(str(model["root_part_id"]))
	_renewing = false
	if not minted["ok"]:
		main.say(str(minted["error"]))
		return false
	client.send({"t": "token", "view_token": minted["token"], "view_expires_at": minted["expires_at"]})
	return true
