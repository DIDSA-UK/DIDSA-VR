extends Node
## The session client: one participant's connection to the session hub (DIDSA-CAD session-hub/, protocol: docs/live-sessions-scope.md section 4).
## It knows the wire and nothing about the scene: host / join / resume, the welcome and its snapshot, ping / pong, the error codes, the roster, and
## reconnecting with `resume` after a drop. Everything the presenter streams (poses, visibility, section, place, doc_changed, status, gather ...) and
## presence is handed on as signals; session_manager.gd, session_publisher.gd and session_observer.gd use them.
##
## Time is the `delta` given to tick() (what _process passes), never the wall clock, so a test drives it by calling tick().
##
## Reconnect: a socket that closes (or goes silent for 30 s) without an `error`, an `end` or our own leave is a DROP. With a resume token from the
## welcome the client retries after 1, 2, 4, 8, then every 10 seconds for 10 minutes (the hub's window), each time sending `resume`; a presenter's
## resume carries the hub key again. `resume_expired` (or the window running out) ends it. A drop before the first welcome is a failed connect and
## is reported as such, not retried.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const Transport := preload("res://scripts/session/session_transport.gd")
const ServerProbe := preload("res://scripts/landing/server_probe.gd")

enum State { IDLE, CONNECTING, AWAITING_WELCOME, LIVE, RECONNECTING, CLOSED }

const CONNECT_TIMEOUT := 10.0 ## seconds to open the socket and get a welcome
const SILENT_TIMEOUT := 30.0 ## the hub pings every 10 s: this long without any packet is a drop
const RESUME_WINDOW := 600.0 ## the hub keeps a dropped place this long
const BACKOFF: Array[float] = [1.0, 2.0, 4.0, 8.0, 10.0]
const SEND_RATE := 55.0 ## messages a second this client sends at most (the hub's limit is 60 averaged over 5 s); presence and poses are the ones dropped
const DROPPABLE: Array[String] = ["presence", "poses"]
const REFUSED_JOIN := "The hub would not let you in: no session has that code, the presenter has locked it, or it is full. Check the code and try again."
const REFUSED_HOST := "The hub would not host this session: its key may be wrong, or it may be full."
const REFUSED_LIVE := "The hub closed the connection: it refused something this device sent (too many messages, or one that was too big)."

signal state_changed(state: int)
signal welcomed(welcome: Dictionary, resumed: bool) ## the hub accepted us (or took us back, resumed = true)
signal message_received(message: Dictionary) ## a relayed message that is not plumbing: model, doc_changed, poses, visibility, section, place, status, scene, gather, mark ...
signal presence_received(message: Dictionary)
signal roster_changed()
signal presenter_resumed() ## the presenter came back after a drop: its `seq` starts again from 1 (the scope's section 4.1), so an observer forgets the numbers it had applied
signal token_changed(view_token: String, expires_at: float) ## the presenter renewed the read-only token
signal reconnecting(attempt: int)
signal closed(kind: String, text: String) ## kind: error | ended | left | connect_failed | resume_failed. text is plain words for the status line. `last_code` has the hub's code

var transport_factory: Callable = func() -> RefCounted: return Transport.new()
var state := State.IDLE
var role := "" ## "presenter" | "observer", from the welcome
var me: Dictionary = {} ## {id, name, colour, role}
var room: Dictionary = {} ## {code, join_uri, locked}
var participants: Dictionary = {} ## id (int) -> {id, name, colour, role, device, hand, muted, talking, connected}
var snapshot: Dictionary = {}
var backend_url := "" ## observers: where to fetch the model
var view_token := ""
var view_expires_at := 0.0
var resume_token := ""
var last_code := ""
var hub_url := ""
var dropped_count := 0 ## presence / poses messages not sent because the rate guard was empty (a test reads it)
var send_count := 0

var _transport: RefCounted = null
var _hub_key := ""
var _first: Dictionary = {} ## host or join: the first message
var _final := false ## an error, an end or our own leave: nothing more to try
var _seq := 0
var _clock := 0.0 ## accumulated tick() time
var _state_since := 0.0
var _last_rx := 0.0
var _attempt := 0
var _next_attempt_at := 0.0
var _dropped_at := 0.0
var _first_connect := true ## no welcome yet this run: a failure is "connect_failed"
var _tokens := SEND_RATE
var _opened := false


func _process(delta: float) -> void:
	tick(delta)


# --- Starting -----------------------------------------------------------------------------------------------------------------

func host(hub: String, hub_key: String, info: Dictionary) -> bool:
	## Creates a room: info has name, device, client, model {kind, ...}, backend_url, view_token, view_expires_at. False when a socket cannot start.
	_reset()
	hub_url = hub
	_hub_key = hub_key.strip_edges()
	_first = {"t": "host", "proto": Protocol.PROTO}
	_first.merge(info)
	return _connect()


func join(hub: String, code: String, info: Dictionary) -> bool:
	## Joins by code: info has name, device, client.
	_reset()
	hub_url = hub
	_hub_key = ""
	_first = {"t": "join", "proto": Protocol.PROTO, "code": Protocol.normalise_code(code)}
	_first.merge(info)
	return _connect()


func is_live() -> bool:
	return state == State.LIVE


func is_presenter() -> bool:
	return role == "presenter"


func presenter() -> Dictionary:
	for id in participants:
		if str(participants[id].get("role", "")) == "presenter":
			return participants[id]
	return {}


func presenter_connected() -> bool:
	var p := presenter()
	return p.is_empty() or bool(p.get("connected", true))


func others() -> Array:
	## Everyone but this participant.
	var out: Array = []
	for id in participants:
		if int(id) != int(me.get("id", -1)):
			out.append(participants[id])
	return out


# --- Sending ------------------------------------------------------------------------------------------------------------------

func send(message: Dictionary) -> bool:
	## A message to the hub; false (and nothing sent) unless live. Presence and poses are dropped when this client is over its send rate (the next
	## one replaces them anyway); everything else is always sent.
	if state != State.LIVE or _transport == null:
		return false
	if message.get("t", "") in DROPPABLE and _tokens < 1.0:
		dropped_count += 1
		return false
	_tokens = maxf(_tokens - 1.0, 0.0)
	send_count += 1
	return _transport.send_text(JSON.stringify(message))


func send_state(message: Dictionary) -> bool:
	## A presenter's state message: `seq` (only ever goes up on this connection) is added.
	_seq += 1
	var stamped := message.duplicate()
	stamped["seq"] = _seq
	return send(stamped)


func send_raw_text(text: String) -> bool:
	## A message as it was written (tests send malformed ones to see what the hub does).
	if state != State.LIVE or _transport == null:
		return false
	return _transport.send_text(text)


func leave() -> void:
	## A clean goodbye (an observer; a presenter's leave ends the session at the hub): after this there is no reconnect.
	_say_goodbye({"t": "leave"}, "left", "You left the session.")


func end_session() -> void:
	## The presenter ends it for everyone.
	_say_goodbye({"t": "end"}, "ended", "You ended the session.")


func force_resume() -> bool:
	## Closes the socket on purpose and takes the resume path at once: the welcome that comes back carries the hub's CURRENT view token (an observer has no message to ask the
	## presenter for a fresh one with). False when there is nothing to resume (not live, or no resume token).
	if state != State.LIVE or resume_token == "" or _transport == null:
		return false
	_transport.close()
	_transport = null
	_opened = false
	_dropped_at = _clock
	_attempt = 1
	_next_attempt_at = _clock
	_set_state(State.RECONNECTING)
	reconnecting.emit(_attempt)
	return true


func stop() -> void:
	## Closes the socket quietly (no goodbye, no signal): the app is closing or switching.
	if _transport != null:
		_transport.close()
	_transport = null
	_final = true
	_set_state(State.IDLE)


# --- The clock ----------------------------------------------------------------------------------------------------------------

func tick(delta: float) -> void:
	_clock += delta
	_tokens = minf(SEND_RATE, _tokens + delta * SEND_RATE)
	match state:
		State.CONNECTING, State.AWAITING_WELCOME:
			_poll_transport()
			if state in [State.CONNECTING, State.AWAITING_WELCOME] and _clock - _state_since > CONNECT_TIMEOUT:
				_transport_lost("The hub did not answer in %d seconds." % int(CONNECT_TIMEOUT))
		State.LIVE:
			_poll_transport()
			if state == State.LIVE and _clock - _last_rx > SILENT_TIMEOUT:
				_transport_lost("The hub went quiet.")
		State.RECONNECTING:
			if _transport != null:
				_poll_transport()
				if state == State.RECONNECTING and _transport != null and _clock - _state_since > CONNECT_TIMEOUT:
					_transport_lost("No answer.") # (opened or not: the hub answers a resume at once)
			elif _clock >= _next_attempt_at:
				_try_resume()


# --- Internals ----------------------------------------------------------------------------------------------------------------

func _reset() -> void:
	if _transport != null:
		_transport.close()
	_transport = null
	role = ""
	me = {}
	room = {}
	participants = {}
	snapshot = {}
	backend_url = ""
	view_token = ""
	view_expires_at = 0.0
	resume_token = ""
	last_code = ""
	_final = false
	_seq = 0
	_attempt = 0
	_first_connect = true
	_tokens = SEND_RATE
	dropped_count = 0
	send_count = 0


func _connect() -> bool:
	_transport = transport_factory.call()
	_opened = false
	var headers := PackedStringArray()
	if _hub_key != "" and str(_first.get("t", "")) == "host":
		headers.append("X-API-Key: %s" % _hub_key)
	var error: int = _transport.open(Protocol.socket_url(hub_url), headers)
	if error != OK:
		_transport = null
		_fail("connect_failed", "Could not start a connection to the hub (error %d)." % error)
		return false
	_set_state(State.CONNECTING)
	return true


func _poll_transport() -> void:
	if _transport == null:
		return
	_transport.poll()
	if not _opened and _transport.is_open():
		_opened = true
		_last_rx = _clock
		_send_first()
	for packet in _transport.read():
		_last_rx = _clock
		if packet.has("text"):
			_on_text(str(packet["text"]))
		# binary frames are voice (P3): nothing here uses them yet
		if _transport == null or state == State.CLOSED:
			return
	if _transport != null and _transport.is_closed():
		_on_socket_closed()


func _send_first() -> void:
	var message := _first
	if state == State.RECONNECTING:
		message = {"t": "resume", "proto": Protocol.PROTO, "resume": resume_token}
	_transport.send_text(JSON.stringify(message))
	_set_state(State.RECONNECTING if state == State.RECONNECTING else State.AWAITING_WELCOME)


func _on_text(text: String) -> void:
	var json := JSON.new() # (parse(), not parse_string(): junk from a hub is ignored without an engine error in the log)
	if json.parse(text) != OK or not (json.data is Dictionary) or not (json.data as Dictionary).has("t"):
		return
	var message: Dictionary = json.data
	var kind := str(message["t"])
	if state in [State.AWAITING_WELCOME, State.RECONNECTING] and kind not in ["welcome", "error", "ping"]:
		return
	match kind:
		"welcome":
			_on_welcome(message)
		"error":
			last_code = str(message.get("code", ""))
			_fail("resume_failed" if last_code == "resume_expired" else "error", Protocol.error_text(last_code, str(message.get("message", ""))))
		"end":
			last_code = str(message.get("reason", "ended"))
			_fail("ended", Protocol.end_text(last_code))
		"ping":
			if state == State.LIVE or state == State.AWAITING_WELCOME or state == State.RECONNECTING:
				_transport.send_text(JSON.stringify({"t": "pong", "n": message.get("n")}))
		"pong":
			pass
		"joined":
			var p = message.get("participant")
			if p is Dictionary:
				participants[int(p.get("id", 0))] = p
				roster_changed.emit()
				if bool(message.get("resumed", false)) and str(p.get("role", "")) == "presenter":
					presenter_resumed.emit()
		"left":
			var id := int(message.get("id", 0))
			if str(message.get("reason", "")) == "dropped" and participants.has(id):
				participants[id]["connected"] = false
			else:
				participants.erase(id)
			roster_changed.emit()
		"roster":
			participants = {}
			for p in message.get("participants", []):
				if p is Dictionary:
					participants[int(p.get("id", 0))] = p
			roster_changed.emit()
		"lock":
			room["locked"] = bool(message.get("locked", false))
			roster_changed.emit()
		"token":
			view_token = str(message.get("view_token", ""))
			view_expires_at = float(message.get("view_expires_at", 0.0) if message.get("view_expires_at") != null else 0.0)
			token_changed.emit(view_token, view_expires_at)
		"presence":
			presence_received.emit(message)
		_:
			message_received.emit(message)


func _on_welcome(welcome: Dictionary) -> void:
	var resumed := state == State.RECONNECTING
	me = welcome.get("you", {})
	role = str(me.get("role", ""))
	room = welcome.get("room", {})
	resume_token = str(welcome.get("resume", ""))
	participants = {}
	for p in welcome.get("participants", []):
		if p is Dictionary:
			participants[int(p.get("id", 0))] = p
	snapshot = welcome.get("snapshot", {})
	if role == "observer":
		backend_url = str(welcome.get("backend_url", ""))
		view_token = str(welcome.get("view_token", ""))
		var expires = welcome.get("view_expires_at")
		view_expires_at = float(expires) if expires != null else 0.0
	_first_connect = false
	_attempt = 0
	_seq = 0 # a seq restarts with a resumed connection (the scope's section 4.1)
	_set_state(State.LIVE)
	welcomed.emit(welcome, resumed)
	roster_changed.emit()


func _on_socket_closed() -> void:
	if _final or state == State.CLOSED or state == State.IDLE:
		return
	var close_code: int = _transport.close_code() if _transport != null else -1
	var close_reason: String = _transport.close_reason() if _transport != null and _transport.has_method("close_reason") else ""
	if _closed_by_hub(close_code, close_reason):
		return
	_transport_lost("The connection to the hub closed.")


func _closed_by_hub(close_code: int, close_reason: String = "") -> bool:
	## Godot's WebSocketPeer gives NO packets once the close frame has been processed, and the hub sends its last message (`error`, `end`) and closes at once: the message is
	## usually lost and only the close code is left. The hub's codes are distinct (session-hub/app/hub.py, `_fail`, `_on_remove`, `_end_room`), so when no message came they say what
	## happened (and a hub from DIDSA-CAD P2 on also puts the error code or end reason in the close frame's reason, which is used first, and waits a moment before closing so the message itself usually arrives): 4003 removed, 4000 refused (which error is not known; what was being asked narrows it), 1000 while live the room ended. (If the message DID arrive it was handled first.)
	if close_code == 4000 and Protocol.ERROR_WORDS.has(close_reason):
		last_code = close_reason
		_fail("resume_failed" if close_reason == "resume_expired" else "error", Protocol.error_text(close_reason))
		return true
	if close_code == 1000 and state == State.LIVE and Protocol.END_WORDS.has(close_reason):
		last_code = close_reason
		_fail("ended", Protocol.end_text(close_reason))
		return true
	match close_code:
		4003:
			last_code = "removed"
			_fail("error", Protocol.error_text("removed"))
			return true
		4000:
			if state == State.RECONNECTING:
				last_code = "resume_expired"
				_fail("resume_failed", Protocol.error_text("resume_expired"))
			elif state == State.AWAITING_WELCOME:
				last_code = ""
				_fail("error", REFUSED_HOST if str(_first.get("t", "")) == "host" else REFUSED_JOIN)
			else:
				last_code = ""
				_fail("error", REFUSED_LIVE)
			return true
		1000:
			if state == State.LIVE:
				last_code = "ended"
				_fail("ended", Protocol.end_text("ended"))
				return true
	return false


func _transport_lost(why: String) -> void:
	## The socket closed or went quiet with no error, end or goodbye: a drop.
	var was_open := _opened
	if _transport != null:
		_transport.close()
	_transport = null
	_opened = false
	if _final:
		return
	if resume_token == "" or _first_connect and state != State.RECONNECTING:
		var hint: String = ServerProbe.NO_INTERNET_HINT if OS.get_name() == "Android" and _first_connect else ""
		var refused := "" if was_open else (" A hub refuses a host whose key is wrong before it answers: check the hub key (Servers), and the address." if str(_first.get("t", "")) == "host" else "")
		_fail("connect_failed", "Could not reach the session hub. %s%s%s" % [why, refused, hint])
		return
	if state != State.RECONNECTING:
		_dropped_at = _clock
	if _clock - _dropped_at > RESUME_WINDOW:
		_fail("resume_failed", Protocol.error_text("resume_expired"))
		return
	_attempt += 1
	_next_attempt_at = _clock + BACKOFF[mini(_attempt - 1, BACKOFF.size() - 1)]
	_set_state(State.RECONNECTING)
	reconnecting.emit(_attempt)


func _try_resume() -> void:
	if _clock - _dropped_at > RESUME_WINDOW:
		_fail("resume_failed", Protocol.error_text("resume_expired"))
		return
	_transport = transport_factory.call()
	_opened = false
	var headers := PackedStringArray()
	if role == "presenter" and _hub_key != "":
		headers.append("X-API-Key: %s" % _hub_key)
	if _transport.open(Protocol.socket_url(hub_url), headers) != OK:
		_transport = null
		_attempt += 1
		_next_attempt_at = _clock + BACKOFF[mini(_attempt - 1, BACKOFF.size() - 1)]
		return
	_state_since = _clock


func _say_goodbye(message: Dictionary, kind: String, text: String) -> void:
	_final = true
	if _transport != null:
		if state == State.LIVE:
			_transport.send_text(JSON.stringify(message))
		_transport.close()
	_transport = null
	_fail(kind, text, false)


func _fail(kind: String, text: String, close_socket: bool = true) -> void:
	_final = true
	if close_socket and _transport != null:
		_transport.close()
	_transport = null
	_set_state(State.CLOSED)
	closed.emit(kind, text)


func _set_state(new_state: int) -> void:
	if new_state == state:
		return
	state = new_state
	_state_since = _clock
	state_changed.emit(state)
