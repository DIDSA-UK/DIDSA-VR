extends RefCounted
## A fake session hub for the headless tests: the rules of DIDSA-CAD session-hub/app/hub.py that the client depends on (host / join / resume, the
## roles and who may send what, the relay, the snapshot, drop and resume, remove / lock / token / end, the error codes), behind the same surface as
## scripts/session/session_transport.gd, with no sockets. Not the real hub: tests/e2e_session_*.gd run against that.
##
## A test gives the client `transport_factory = hub.make_transport`, then calls client.tick(0.1) in a loop (or `pump(client, n)`); the hub answers
## synchronously when the client sends, and what it sends back is read at the client's next poll.
##
##   var hub := FakeSessionHub.new()
##   host.transport_factory = hub.make_transport
##   host.host("wss://hub.test", hub.key, {...})
##   hub.sent_by[id] / hub.received_by[id] hold every JSON message each participant sent / was sent (their `t` and fields), for assertions.

const PALETTE := ["#E8590C", "#1C7ED6", "#2F9E44", "#AE3EC9", "#F08C00", "#0CA678", "#E03131", "#5C7CFA"]
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const PRESENTER_ONLY := ["model", "doc_changed", "poses", "visibility", "section", "place", "status", "scene", "gather", "marks_clear", "mute_all", "lock", "remove", "token", "end"]
const ANYONE := ["presence", "hand", "mark", "mark_clear", "voice_state", "leave", "ping", "pong"]
const STATE_KEYS := ["visibility", "section", "place", "status", "scene"]

var key := "fake-hub-key"
var public_url := ""
var max_participants := 7
var rooms: Dictionary = {} ## code -> room
var resume_map: Dictionary = {} ## token -> {room, participant}
var sent_by: Dictionary = {} ## participant id -> Array of the messages it sent (after its first)
var received_by: Dictionary = {} ## participant id -> Array of the messages the hub sent it
var ignored: Dictionary = {} ## participant id -> count of messages dropped (not allowed for the role)
var connect_failures := 0 ## the next this-many transports never open (an unreachable hub)
var send_reason := false ## like the hub from DIDSA-CAD P2: the error code / end reason also goes in the close frame's reason
var lose_final := false ## like Godot's WebSocketPeer: what the hub sent in the same moment as it closed is never delivered (only the close code is)
var transports: Array = []
var open_count := 0
var _clock_ms := 1000
var _since_ping := 0.0
var _next_room := 0


class Transport:
	extends RefCounted
	var hub: RefCounted
	var state := WebSocketPeer.STATE_CLOSED
	var inbox: Array = []
	var headers := PackedStringArray()
	var refuse := false
	var participant: Dictionary = {}
	var room: Dictionary = {}
	var first_seen := false
	var closed_by_hub := false
	var code := 1000
	var reason := ""
	var dead := false

	func open(_url: String, p_headers: PackedStringArray) -> int:
		headers = p_headers
		state = WebSocketPeer.STATE_CONNECTING
		hub.open_count += 1
		refuse = hub.connect_failures > 0
		if refuse:
			hub.connect_failures -= 1
		return OK

	func poll() -> void:
		if state == WebSocketPeer.STATE_CONNECTING:
			state = WebSocketPeer.STATE_CLOSED if (refuse or hub.rejects_key(self)) else WebSocketPeer.STATE_OPEN

	func is_open() -> bool:
		return state == WebSocketPeer.STATE_OPEN

	func is_connecting() -> bool:
		return state == WebSocketPeer.STATE_CONNECTING

	func is_closed() -> bool:
		return state == WebSocketPeer.STATE_CLOSED

	func read() -> Array:
		var out := inbox.duplicate()
		inbox.clear()
		return out

	func send_text(text: String) -> bool:
		if state != WebSocketPeer.STATE_OPEN:
			return false
		if not dead:
			hub.on_text(self, text)
		return true

	func send_bytes(_bytes: PackedByteArray) -> bool:
		return state == WebSocketPeer.STATE_OPEN

	func close(_code: int = 1000, _reason: String = "") -> void:
		if state != WebSocketPeer.STATE_CLOSED:
			state = WebSocketPeer.STATE_CLOSED
			if not closed_by_hub:
				hub.on_closed(self)

	func close_code() -> int:
		return code

	func close_reason() -> String:
		return reason

	func deliver(message: Dictionary) -> void:
		if dead:
			return
		inbox.append({"text": JSON.stringify(message)})
		if not participant.is_empty():
			hub.received_by[int(participant["id"])].append(message)


func make_transport() -> RefCounted:
	var t := Transport.new()
	t.hub = self
	transports.append(t)
	return t


func rejects_key(t: Transport) -> bool:
	## A handshake that carries a WRONG key is refused before the upgrade; one with no key is accepted (an observer's).
	for header in t.headers:
		if str(header).begins_with("X-API-Key:"):
			return str(header).substr(10).strip_edges() != key
	return false


func has_key(t: Transport) -> bool:
	for header in t.headers:
		if str(header).begins_with("X-API-Key:"):
			return true
	return false


# --- The rules ----------------------------------------------------------------------------------------------------------------

func on_text(t: Transport, text: String) -> void:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("t"):
		if not t.first_seen:
			_fail(t, "not_allowed", "The first message must be host, join or resume.")
		return
	var msg: Dictionary = parsed
	var kind := str(msg["t"])
	if not t.first_seen:
		if kind not in ["host", "join", "resume"]:
			_fail(t, "not_allowed", "The first message must be host, join or resume.")
			return
		if int(msg.get("proto", 0)) != 1:
			_fail(t, "proto_unsupported", "This hub speaks protocol 1.")
			return
		t.first_seen = true
		match kind:
			"host":
				_host(t, msg)
			"join":
				_join(t, msg)
			"resume":
				_resume(t, msg)
		return
	var p: Dictionary = t.participant
	var id := int(p["id"])
	sent_by[id].append(msg)
	var allowed: bool = kind in ANYONE or (kind in PRESENTER_ONLY and p["role"] == "presenter")
	if not allowed:
		ignored[id] = int(ignored.get(id, 0)) + 1
		return
	_clock_ms += 7
	var room: Dictionary = t.room
	match kind:
		"model":
			room["model"] = (msg.get("source", {}) as Dictionary).duplicate()
			room["model"]["title"] = str(msg.get("title", ""))
			room["rev"] = int(msg.get("rev", (msg.get("source", {}) as Dictionary).get("rev", 0)))
			room["poses"] = {}
			room["state"].erase("visibility")
			room["state"].erase("scene")
			_relay(room, p, msg)
		"doc_changed":
			room["rev"] = maxi(int(msg.get("rev", 0)), int(room["rev"] if room["rev"] != null else 0))
			_relay(room, p, msg)
		"poses":
			if bool(msg.get("full", false)):
				room["poses"] = {}
			for item in msg.get("items", []):
				room["poses"][str(item["path"])] = item["xf"]
			_relay(room, p, msg)
		"visibility", "section", "place", "status", "scene":
			room["state"][kind] = _stamp(p, msg)
			_relay(room, p, msg)
		"gather", "marks_clear":
			_relay(room, p, msg)
		"lock":
			room["locked"] = bool(msg.get("locked", false))
			_relay(room, p, {"t": "lock", "locked": room["locked"]})
		"remove":
			var target: Dictionary = room["participants"].get(int(msg.get("id", -1)), {})
			if not target.is_empty() and int(target["id"]) != id:
				var tt: Transport = target.get("transport")
				if tt != null:
					tt.deliver({"t": "error", "code": "removed", "message": "removed"})
					_close_from_hub(tt, 4003, "removed")
				room["participants"].erase(int(target["id"]))
				resume_map.erase(target["resume"])
				_broadcast(room, {"t": "left", "id": int(target["id"]), "reason": "removed"})
		"token":
			room["view_token"] = str(msg.get("view_token", ""))
			room["view_expires_at"] = msg.get("view_expires_at")
			_relay(room, p, {"t": "token", "view_token": room["view_token"], "view_expires_at": room["view_expires_at"]})
		"end":
			_end_room(room, "ended")
		"presence":
			room["presence"][id] = _stamp(p, msg)
			for other in _connected(room):
				if int(other["id"]) != id:
					other["transport"].deliver(_stamp(p, msg))
		"hand":
			p["hand"] = bool(msg.get("up", false))
			_roster(room)
		"leave":
			if p["role"] == "presenter":
				_end_room(room, "ended")
			else:
				_close_from_hub(t, 1000)
				room["participants"].erase(id)
				resume_map.erase(p["resume"])
				_broadcast(room, {"t": "left", "id": id, "reason": "left"})
		"ping":
			t.deliver({"t": "pong", "n": msg.get("n")})


func on_closed(t: Transport) -> void:
	## The socket went away without a leave: a drop (resume is possible).
	if t.participant.is_empty():
		return
	var p: Dictionary = t.participant
	if p.get("transport") != t:
		return
	var room: Dictionary = t.room
	if not room["participants"].has(int(p["id"])):
		return
	p["transport"] = null
	room["presence"].erase(int(p["id"]))
	_broadcast(room, {"t": "left", "id": int(p["id"]), "reason": "dropped"}, int(p["id"]))


func drop(id: int) -> void:
	## Test helper: the network under participant `id` breaks (the socket closes, no leave).
	for room in rooms.values():
		var p: Dictionary = room["participants"].get(id, {})
		if not p.is_empty() and p.get("transport") != null:
			var t: Transport = p["transport"]
			t.code = -1 # a network drop: no close frame, Godot's close code is -1
			t.state = WebSocketPeer.STATE_CLOSED
			on_closed(t)


func silence(id: int) -> void:
	## Test helper: a dead link nobody noticed. The client's socket stays "open", the hub neither hears it nor can reach it.
	for room in rooms.values():
		var p: Dictionary = room["participants"].get(id, {})
		if not p.is_empty() and p.get("transport") != null:
			(p["transport"] as Transport).dead = true


func tick(delta: float) -> void:
	## The real hub pings every connection every 10 s (a test that lets a lot of time pass calls this from its pump).
	_since_ping += delta
	if _since_ping >= 10.0:
		_since_ping = 0.0
		ping_all()


func ping_all() -> void:
	for room in rooms.values():
		for p in _connected(room):
			p["transport"].deliver({"t": "ping", "n": 1})


func room_of(code: String) -> Dictionary:
	return rooms.get(code, {})


func only_room() -> Dictionary:
	return rooms.values()[0] if rooms.size() == 1 else {}


func messages_of(id: int, kind: String) -> Array:
	## What participant `id` sent, of one type.
	return (sent_by.get(id, []) as Array).filter(func(m: Dictionary) -> bool: return m.get("t", "") == kind)


func received_of(id: int, kind: String) -> Array:
	return (received_by.get(id, []) as Array).filter(func(m: Dictionary) -> bool: return m.get("t", "") == kind)


# --- Host, join, resume -------------------------------------------------------------------------------------------------------

func _host(t: Transport, msg: Dictionary) -> void:
	if not has_key(t):
		_fail(t, "not_allowed", "Hosting needs the hub key.")
		return
	var model = msg.get("model")
	if not (model is Dictionary) or str(model.get("kind", "")) not in ["backend", "demo"]:
		_fail(t, "bad_message", "host needs a model whose kind is backend or demo.")
		return
	if model["kind"] == "backend" and (str(msg.get("backend_url", "")) == "" or str(msg.get("view_token", "")) == ""):
		_fail(t, "bad_message", "A backend model needs backend_url and view_token.")
		return
	_next_room += 1
	var code := _code_for(_next_room)
	var room := {"code": code, "backend_url": str(msg.get("backend_url", "")), "view_token": str(msg.get("view_token", "")), "view_expires_at": msg.get("view_expires_at"),
		"locked": false, "next_id": 1, "participants": {}, "presenter_id": 0, "model": model, "rev": model.get("rev"), "poses": {}, "state": {}, "presence": {}}
	rooms[code] = room
	var p := _add(t, room, msg, "presenter")
	room["presenter_id"] = int(p["id"])
	_welcome(t, room, p)


func _join(t: Transport, msg: Dictionary) -> void:
	var code := _normalise(str(msg.get("code", "")))
	var room: Dictionary = rooms.get(code, {})
	if room.is_empty():
		_fail(t, "bad_code", "No session has that code.")
		return
	if room["locked"]:
		_fail(t, "room_locked", "locked")
		return
	if room["participants"].size() >= max_participants:
		_fail(t, "room_full", "full")
		return
	var p := _add(t, room, msg, "observer")
	_welcome(t, room, p)
	_broadcast(room, {"t": "joined", "participant": _public(p)}, int(p["id"]))


func _resume(t: Transport, msg: Dictionary) -> void:
	var found: Dictionary = resume_map.get(str(msg.get("resume", "")), {})
	if found.is_empty():
		_fail(t, "resume_expired", "gone")
		return
	var room: Dictionary = found["room"]
	var p: Dictionary = found["participant"]
	if p["role"] == "presenter" and not has_key(t):
		_fail(t, "not_allowed", "Resuming as the presenter needs the hub key.")
		return
	if p.get("transport") != null and p["transport"] != t:
		var old: Transport = p["transport"]
		_close_from_hub(old, 1000)
	p["transport"] = t
	t.participant = p
	t.room = room
	_welcome(t, room, p)
	_broadcast(room, {"t": "joined", "participant": _public(p), "resumed": true}, int(p["id"]))


func _add(t: Transport, room: Dictionary, msg: Dictionary, role: String) -> Dictionary:
	var used: Array = []
	for existing in room["participants"].values():
		used.append(existing["colour"])
	var colour := ""
	for c in PALETTE:
		if not used.has(c):
			colour = c
			break
	var id := int(room["next_id"])
	room["next_id"] = id + 1
	var p := {"id": id, "name": str(msg.get("name", "")).strip_edges().left(40) if str(msg.get("name", "")).strip_edges() != "" else "Guest %d" % id,
		"colour": colour if colour != "" else PALETTE[0], "role": role, "device": str(msg.get("device", "desktop")), "resume": "resume-%s-%d" % [room["code"], id],
		"hand": false, "muted": false, "talking": false, "transport": t}
	room["participants"][id] = p
	resume_map[p["resume"]] = {"room": room, "participant": p}
	t.participant = p
	t.room = room
	sent_by[id] = []
	received_by[id] = []
	return p


func _welcome(t: Transport, room: Dictionary, p: Dictionary) -> void:
	var welcome := {"t": "welcome", "proto": 1, "you": {"id": p["id"], "name": p["name"], "colour": p["colour"], "role": p["role"]},
		"room": {"code": room["code"], "join_uri": "didsa-join:1?c=%s" % room["code"] if public_url == "" else "didsa-join:1?h=%s&c=%s" % [public_url.uri_encode(), room["code"]], "locked": room["locked"]},
		"resume": p["resume"], "participants": room["participants"].values().map(func(q: Dictionary) -> Dictionary: return _public(q)),
		"snapshot": _snapshot(room)}
	if p["role"] == "observer":
		welcome["backend_url"] = room["backend_url"]
		welcome["view_token"] = room["view_token"]
		welcome["view_expires_at"] = room["view_expires_at"]
	t.deliver(welcome)


func _snapshot(room: Dictionary) -> Dictionary:
	var poses: Array = []
	for path in room["poses"]:
		poses.append({"path": path, "xf": room["poses"][path]})
	var out := {"model": room["model"], "rev": room["rev"], "hidden_feature_ids": null, "poses": poses, "marks": [], "presence": {}}
	for k in STATE_KEYS:
		out[k] = room["state"].get(k)
	for pid in room["presence"]:
		out["presence"][str(pid)] = room["presence"][pid]
	return out


# --- Helpers ------------------------------------------------------------------------------------------------------------------

func _public(p: Dictionary) -> Dictionary:
	return {"id": p["id"], "name": p["name"], "colour": p["colour"], "role": p["role"], "device": p["device"], "hand": p["hand"], "muted": p["muted"], "talking": p["talking"],
		"connected": p.get("transport") != null}


func _connected(room: Dictionary) -> Array:
	return room["participants"].values().filter(func(p: Dictionary) -> bool: return p.get("transport") != null)


func _stamp(p: Dictionary, msg: Dictionary) -> Dictionary:
	var out := msg.duplicate()
	out["from"] = p["id"]
	out["at"] = _clock_ms
	return out


func _relay(room: Dictionary, p: Dictionary, msg: Dictionary) -> void:
	for other in _connected(room):
		if int(other["id"]) != int(p["id"]):
			other["transport"].deliver(_stamp(p, msg))


func _broadcast(room: Dictionary, msg: Dictionary, exclude: int = -1) -> void:
	for other in _connected(room):
		if int(other["id"]) != exclude:
			other["transport"].deliver(msg)


func _roster(room: Dictionary) -> void:
	_broadcast(room, {"t": "roster", "participants": room["participants"].values().map(func(q: Dictionary) -> Dictionary: return _public(q))})


func _end_room(room: Dictionary, reason: String) -> void:
	for p in room["participants"].values():
		var tt: Transport = p.get("transport")
		if tt != null:
			tt.deliver({"t": "end", "reason": reason})
			_close_from_hub(tt, 1000, reason)
		resume_map.erase(p["resume"])
	rooms.erase(room["code"])


func end_by_timeout(code: String) -> void:
	## Test helper: the presenter did not come back in time.
	var room: Dictionary = rooms.get(code, {})
	if not room.is_empty():
		_end_room(room, "presenter_gone")


func forget_resume_tokens() -> void:
	## Test helper: the hub restarted (every resume token is unknown now).
	resume_map.clear()


func _fail(t: Transport, code: String, message: String) -> void:
	t.deliver({"t": "error", "code": code, "message": message})
	_close_from_hub(t, 4000, code)


func _close_from_hub(t: Transport, code: int, reason: String = "") -> void:
	t.closed_by_hub = true
	t.code = code
	t.reason = reason if send_reason else ""
	t.state = WebSocketPeer.STATE_CLOSED
	if lose_final:
		t.inbox.clear() # (unread packets die with the close: what Godot's WebSocketPeer does)


func _normalise(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch := text[i].to_upper()
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


func _code_for(n: int) -> String:
	var out := ""
	var v := n * 7919 + 13
	for i in 6:
		out += CODE_ALPHABET[v % CODE_ALPHABET.length()]
		v = v / 3 + i * 5 + 11
	return out if not rooms.has(out) else _code_for(n + 1000)
