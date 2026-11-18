extends SceneTree
## P2: scripts/session/session_client.gd against tests/fake_session_hub.gd (the hub's rules, no sockets): host with the hub key and without, join, the welcome
## and snapshot, who may send what, the relay, presence, the roster, ping / pong, every error code, the rate guard, a drop and resume (with the presenter
## shown as reconnecting meanwhile), a silent link, an expired resume, a presenter that never returns, leave, End, Remove, Lock and a renewed token.
## NOT covered: a real WebSocketPeer (tests/e2e_session_*.gd run the client against the real hub).
## Run: "$GODOT" --headless --path . --script res://tests/session_client.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Client := preload("res://scripts/session/session_client.gd")
const P := preload("res://scripts/session/session_protocol.gd")

var hub: RefCounted
var _clients: Array = [] ## every client made since the hub was made: all of them are ticked by _pump (each has its own clock)


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _client() -> Node:
	var c := Client.new()
	c.transport_factory = hub.make_transport
	root.add_child(c)
	_clients.append(c)
	return c


func _pump(_unused: Array, seconds: float, step: float = 0.1) -> void:
	var n := int(round(seconds / step))
	for i in n:
		hub.tick(step)
		for c in _clients:
			c.tick(step)


func _record(c: Node) -> Dictionary:
	var rec := {"welcomed": [], "messages": [], "presence": [], "closed": [], "reconnecting": [], "tokens": [], "roster": [0]}
	c.welcomed.connect(func(w: Dictionary, resumed: bool) -> void: rec["welcomed"].append({"w": w, "resumed": resumed}))
	c.message_received.connect(func(m: Dictionary) -> void: rec["messages"].append(m))
	c.presence_received.connect(func(m: Dictionary) -> void: rec["presence"].append(m))
	c.closed.connect(func(kind: String, text: String) -> void: rec["closed"].append([kind, text, c.last_code]))
	c.reconnecting.connect(func(n: int) -> void: rec["reconnecting"].append(n))
	c.token_changed.connect(func(tok: String, _e: float) -> void: rec["tokens"].append(tok))
	c.roster_changed.connect(func() -> void: rec["roster"][0] += 1)
	return rec


func _model() -> Dictionary:
	return {"kind": "backend", "root_part_id": "root-1", "rev": 4, "quality": 0.5, "tier": "full"}


func _host_info() -> Dictionary:
	return {"name": "Alex", "device": "quest", "client": "didsa-vr-test", "model": _model(), "backend_url": "https://cad.example.net", "view_token": "tok-1", "view_expires_at": 99999.0}


func _hosted() -> Array:
	## A hosting client, live; [client, record, code].
	var h := _client()
	var rec := _record(h)
	h.host("wss://hub.test", hub.key, _host_info())
	_pump([h], 0.5)
	return [h, rec, str(h.room.get("code", ""))]


func _joined(code: String, name: String) -> Array:
	var o := _client()
	var rec := _record(o)
	o.join("wss://hub.test", code, {"name": name, "device": "phone", "client": "t"})
	_pump([o], 0.5)
	return [o, rec]


func _initialize() -> void:
	hub = Hub.new()
	# --- hosting
	var h_all := _hosted()
	var host: Node = h_all[0]
	var host_rec: Dictionary = h_all[1]
	var code: String = h_all[2]
	_check(host.state == Client.State.LIVE and host.is_presenter() and host.is_live(), "host with the hub key: live, role presenter")
	_check(P.code_is_valid(code) and host.room["join_uri"].contains(code), "the welcome has a well-formed six-character code and the join link")
	_check(int(host.me["id"]) == 1 and host.me["name"] == "Alex" and str(host.me["colour"]) == "#E8590C" and host.resume_token != "", "the presenter is participant 1 with the first colour and a resume token")
	_check(host_rec["welcomed"].size() == 1 and not host_rec["welcomed"][0]["resumed"], "one welcome, not a resume")
	_check(host.backend_url == "" and host.view_token == "", "a presenter is not given the token back (it minted it)")
	var first: Dictionary = hub.only_room()
	_check(first["backend_url"] == "https://cad.example.net" and first["view_token"] == "tok-1", "the hub was told the backend address and the token")
	# the handshake header
	var key_header := false
	for t in hub.transports:
		for header in t.headers:
			key_header = key_header or str(header) == "X-API-Key: " + hub.key
	_check(key_header, "the hub key went in the handshake header, not in a message")
	_check(not JSON.stringify(hub.sent_by[1]).contains(hub.key) and not JSON.stringify(hub.received_by[1]).contains(hub.key), "...and never appears in any message")
	# --- a wrong or missing hub key
	var bad := _client()
	var bad_rec := _record(bad)
	bad.host("wss://hub.test", "not-the-key", _host_info())
	_pump([bad], 0.5)
	_check(bad.state == Client.State.CLOSED and bad_rec["closed"].size() == 1 and bad_rec["closed"][0][0] == "connect_failed", "a wrong hub key is refused before the upgrade: a failed connect")
	_check(str(bad_rec["closed"][0][1]).contains("key"), "...and the words say to check the hub key")
	var nokey := _client()
	var nokey_rec := _record(nokey)
	nokey.host("wss://hub.test", "", _host_info())
	_pump([nokey], 0.5)
	_check(nokey_rec["closed"].size() == 1 and nokey_rec["closed"][0][0] == "error" and nokey_rec["closed"][0][2] == "not_allowed", "no key at all: the hub accepts the socket and answers not_allowed")
	var badmodel := _client()
	var bm_rec := _record(badmodel)
	badmodel.host("wss://hub.test", hub.key, {"name": "A", "model": {"kind": "bag"}})
	_pump([badmodel], 0.5)
	_check(bm_rec["closed"].size() == 1 and bm_rec["closed"][0][2] == "bad_message", "a host without a usable model is bad_message")
	# --- joining
	var o1_all := _joined(code, "Blake")
	var o1: Node = o1_all[0]
	var o1_rec: Dictionary = o1_all[1]
	_check(o1.state == Client.State.LIVE and o1.role == "observer" and int(o1.me["id"]) == 2, "an observer joins by the code alone")
	_check(o1.backend_url == "https://cad.example.net" and o1.view_token == "tok-1", "an observer is handed the backend address and the view token")
	_check(o1.snapshot["model"]["root_part_id"] == "root-1" and int(o1.snapshot["rev"]) == 4, "the welcome's snapshot names the model and revision")
	_check(o1.participants.size() == 2 and o1.presenter()["name"] == "Alex" and o1.presenter_connected(), "the observer knows who the presenter is")
	_check(host.participants.size() == 2 and host.others().size() == 1 and host.others()[0]["name"] == "Blake", "the presenter saw the observer arrive")
	_check(o1.me["colour"] != host.me["colour"], "each person has their own colour")
	var typed := _client()
	var typed_rec := _record(typed)
	typed.join("wss://hub.test", " " + code.to_lower().insert(3, "-") + " ", {"name": "Casey", "device": "quest", "client": "t"})
	_pump([typed], 0.5)
	_check(typed.state == Client.State.LIVE and typed.me["name"] == "Casey", "a code typed in lower case with a dash is accepted")
	# --- who may send what, and the relay
	var a_xf := [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 10.0, 20.0, 30.0]
	_check(host.send_state({"t": "poses", "full": true, "items": [{"path": "occ-1", "xf": a_xf}]}), "the presenter sends a pose table")
	_pump([host, o1, typed], 0.3)
	_check(o1_rec["messages"].size() == 1 and o1_rec["messages"][0]["t"] == "poses" and o1_rec["messages"][0]["items"][0]["xf"] == a_xf, "an observer receives the pose table")
	_check(int(o1_rec["messages"][0]["seq"]) == 1 and int(o1_rec["messages"][0]["from"]) == 1 and o1_rec["messages"][0].has("at"), "it carries a seq that goes up, the sender id and the hub's time")
	host.send_state({"t": "visibility", "hidden": ["occ-2"]})
	_pump([host, o1, typed], 0.2)
	_check(int(o1_rec["messages"][1]["seq"]) == 2, "the next state message has the next seq")
	_check(host_rec["messages"].is_empty(), "the presenter is not sent its own messages back")
	o1.send({"t": "poses", "full": true, "items": [{"path": "occ-9", "xf": a_xf}]})
	o1.send({"t": "doc_changed", "rev": 99, "all": true})
	o1.send({"t": "end"})
	_pump([host, o1, typed], 0.3)
	_check(int(hub.ignored.get(2, 0)) == 3 and host_rec["messages"].is_empty() and host.is_live() and hub.rooms.size() == 1, "an observer's poses, doc_changed and end are dropped by the hub and counted: the presenter hears nothing and the room stays")
	o1.send({"t": "presence", "head": [0, 0, 0, 0, 0, 0, 1], "hands": [null, null], "laser": null, "cursor": null, "mode": "free"})
	_pump([host, o1, typed], 0.2)
	_check(host_rec["presence"].size() == 1 and int(host_rec["presence"][0]["from"]) == 2, "an observer's presence reaches the presenter, stamped with who it is from")
	_check(o1_rec["presence"].is_empty(), "the hub does not echo presence back")
	# --- late join: the snapshot
	host.send_state({"t": "place", "xf": [0.001, 0, 0, 0, 0.001, 0, 0, 0, 0.001, 0.5, 1.0, -1.0]})
	host.send_state({"t": "section", "on": true, "point": [0, 0, 0], "normal": [0, 1, 0]})
	host.send_state({"t": "status", "activity": "design_table", "detail": "Shaft"})
	host.send_state({"t": "poses", "items": [{"path": "occ-1", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 11.0, 20.0, 30.0]}, {"path": "occ-3", "xf": a_xf}]})
	_pump([host], 0.2)
	var late_all := _joined(code, "Late")
	var late: Node = late_all[0]
	var snap: Dictionary = late.snapshot
	_check(snap["place"]["xf"][0] == 0.001 and snap["section"]["on"] == true and snap["status"]["activity"] == "design_table", "a late joiner's snapshot has the place, section and status")
	_check(snap["visibility"]["hidden"] == ["occ-2"], "...the hidden list")
	var by_path := {}
	for item in snap["poses"]:
		by_path[item["path"]] = item["xf"]
	_check(by_path.size() == 2 and by_path["occ-1"][9] == 11.0 and by_path["occ-3"] == a_xf, "...and the pose table with the partial update applied over the full one")
	# --- ping / pong
	var before: int = hub.messages_of(2, "pong").size()
	hub.ping_all()
	_pump([host, o1], 0.2)
	_check(hub.messages_of(2, "pong").size() == before + 1 and hub.messages_of(1, "pong").size() >= 1, "the hub's ping is answered with a pong, by observer and presenter")
	# --- the roster, hand, lock
	o1.send({"t": "hand", "up": true})
	_pump([host, o1], 0.2)
	_check(host.participants[2]["hand"] == true, "a raised hand reaches the presenter's roster")
	host.send({"t": "lock", "locked": true})
	_pump([host, o1, late], 0.2)
	_check(o1.room["locked"] == true, "the lock reaches the observers")
	var locked := _client()
	var locked_rec := _record(locked)
	locked.join("wss://hub.test", code, {"name": "X", "device": "quest", "client": "t"})
	_pump([locked], 0.3)
	_check(locked_rec["closed"].size() == 1 and locked_rec["closed"][0][2] == "room_locked" and locked_rec["closed"][0][0] == "error", "a locked room refuses a new joiner: room_locked")
	host.send({"t": "lock", "locked": false})
	# --- the other errors
	var wrong := _client()
	var wrong_rec := _record(wrong)
	wrong.join("wss://hub.test", "ZZZZZZ", {"name": "X", "device": "quest", "client": "t"})
	_pump([wrong], 0.3)
	_check(wrong_rec["closed"].size() == 1 and wrong_rec["closed"][0][2] == "bad_code" and str(wrong_rec["closed"][0][1]).contains("No session has that code") and wrong.state == Client.State.CLOSED, "a wrong code is bad_code, in plain words")
	_pump([wrong], 120.0, 1.0)
	_check(hub.open_count == hub.transports.size() and wrong_rec["closed"].size() == 1, "an error is final: no retry, no second report")
	hub.max_participants = 4
	var full := _client()
	var full_rec := _record(full)
	full.join("wss://hub.test", code, {"name": "X", "device": "quest", "client": "t"})
	_pump([full], 0.3)
	_check(full_rec["closed"].size() == 1 and full_rec["closed"][0][2] == "room_full", "a full room: room_full")
	hub.max_participants = 7
	var old := _client()
	var old_rec := _record(old)
	old._first = {"t": "join", "proto": 2, "code": code}
	old._hub_key = ""
	old.hub_url = "wss://hub.test"
	old._connect()
	_pump([old], 0.3)
	_check(old_rec["closed"].size() == 1 and old_rec["closed"][0][2] == "proto_unsupported", "a protocol the hub does not speak: proto_unsupported")
	# --- an unreachable hub, and a hub that never answers
	hub.connect_failures = 1
	var down := _client()
	var down_rec := _record(down)
	down.join("wss://hub.test", code, {"name": "X", "device": "quest", "client": "t"})
	_pump([down], 1.0)
	_check(down_rec["closed"].size() == 1 and down_rec["closed"][0][0] == "connect_failed" and down.state == Client.State.CLOSED, "a hub that cannot be reached is a failed connect (no retry: there is no place to resume)")
	# --- a drop, and a resume
	var opens_before: int = hub.open_count
	var welcomes_before: int = host_rec["welcomed"].size()
	hub.drop(1)
	_pump([host, o1, late], 0.2)
	_check(host.state == Client.State.RECONNECTING and host_rec["reconnecting"] == [1], "the presenter's socket drops: reconnecting, attempt 1")
	_check(not o1.presenter_connected() and o1.participants[1]["connected"] == false, "observers are told the presenter dropped (they show Presenter reconnecting and keep the last state)")
	_check(o1.is_live() and o1_rec["closed"].is_empty(), "...and stay in the session")
	_check(not host.send_state({"t": "status", "activity": "model", "detail": ""}), "nothing can be sent while reconnecting")
	_pump([host, o1, late], 0.5)
	_check(host.state == Client.State.RECONNECTING, "it waits out the first second before trying again")
	_pump([host, o1, late], 1.5)
	_check(host.state == Client.State.LIVE and host_rec["welcomed"].size() == welcomes_before + 1 and host_rec["welcomed"][-1]["resumed"] == true, "it resumes: a welcome flagged resumed")
	_check(int(host.me["id"]) == 1 and host.role == "presenter" and hub.open_count == opens_before + 1, "...as the same participant on one new connection")
	_check(o1.presenter_connected() and o1.participants[1]["connected"] == true, "observers see the presenter back")
	_check(host.send_state({"t": "status", "activity": "model", "detail": "back"}) and int(hub.messages_of(1, "status")[-1]["seq"]) == 1, "a resumed connection's seq starts again from 1")
	var resume_key := false
	for header in hub.transports[-1].headers:
		resume_key = resume_key or str(header) == "X-API-Key: " + hub.key
	_check(resume_key, "a presenter's resume carries the hub key again")
	# an observer's drop and resume
	hub.drop(2)
	_pump([host, o1], 0.2)
	_check(o1.state == Client.State.RECONNECTING and host.participants[2]["connected"] == false, "an observer's drop shows in the presenter's roster")
	_pump([host, o1], 2.5)
	_check(o1.is_live() and o1_rec["welcomed"][-1]["resumed"] == true and host.participants[2]["connected"] == true and o1.view_token == "tok-1", "an observer resumes with no key and is given the token again")
	# backoff: 1, 2, 4, 8, then every 10 s
	hub.connect_failures = 6
	var opens: Array = []
	var seen_opens: int = hub.open_count
	hub.drop(2)
	var elapsed := 0.0
	while elapsed < 90.0 and not (o1.state == Client.State.LIVE and elapsed > 1.0):
		_pump([], 0.1)
		elapsed += 0.1
		if hub.open_count != seen_opens:
			opens.append(elapsed)
			seen_opens = hub.open_count
	var gaps: Array = []
	for i in range(1, opens.size()):
		gaps.append(snappedf(opens[i] - opens[i - 1], 0.1))
	_check(opens.size() == 7 and absf(opens[0] - 1.0) < 0.3, "after a drop the first retry comes after 1 s (%s)" % str(opens.slice(0, 1)))
	var expected := [2.0, 4.0, 8.0, 10.0, 10.0, 10.0]
	var schedule_ok := gaps.size() == expected.size()
	for i in mini(gaps.size(), expected.size()):
		schedule_ok = schedule_ok and absf(gaps[i] - expected[i]) < 0.45
	_check(schedule_ok, "...then it waits 2, 4, 8, then 10 s between tries, inside the window (gaps %s)" % str(gaps))
	_check(o1.state == Client.State.LIVE and o1_rec["welcomed"][-1]["resumed"], "...and it gets back in the moment the hub answers")
	# a resume the hub no longer knows
	hub.forget_resume_tokens()
	hub.drop(2)
	_pump([o1], 3.0)
	var last: Array = o1_rec["closed"][-1]
	_check(o1.state == Client.State.CLOSED and last[0] == "resume_failed" and last[2] == "resume_expired" and str(last[1]).contains("Join again"), "a resume the hub does not know: the session is gone, say so")
	# a presenter that never comes back: observers are told the session ended
	hub.end_by_timeout(code)
	_pump([late], 0.3)
	_check(late.state == Client.State.CLOSED and late.last_code == "presenter_gone", "the hub ending the room after the presenter's 10 minutes ends the observers' session")
	# --- a fresh room for the rest
	hub = Hub.new()
	_clients.clear()
	var h2 := _hosted()
	var host2: Node = h2[0]
	var host2_rec: Dictionary = h2[1]
	var code2: String = h2[2]
	var a2 := _joined(code2, "Dana")
	var b2 := _joined(code2, "Eli")
	var dana: Node = a2[0]
	var dana_rec: Dictionary = a2[1]
	var eli: Node = b2[0]
	var eli_rec: Dictionary = b2[1]
	# the presenter's 10-minute window runs out on the client too
	hub.connect_failures = 1000
	hub.drop(1)
	_pump([host2], 700.0, 1.0)
	_check(host2.state == Client.State.CLOSED and host2_rec["closed"][-1][0] == "resume_failed", "a drop that outlasts the 10 minutes ends in resume_failed")
	hub.connect_failures = 0
	host2 = _client()
	host2_rec = _record(host2)
	host2.host("wss://hub.test", hub.key, _host_info())
	_pump([host2], 0.3)
	var code3 := str(host2.room["code"])
	dana = _joined(code3, "Dana")[0]
	eli = _joined(code3, "Eli")[0]
	dana_rec = _record(dana)
	# a silent link
	hub.silence(int(dana.me["id"]))
	_pump([dana, host2, eli], 20.0, 0.5)
	_check(dana.is_live(), "20 s of silence is not yet a drop")
	_pump([dana, host2, eli], 10.5, 0.5)
	_check(dana.state == Client.State.RECONNECTING, "30 s with no packet at all is a drop")
	_pump([dana, host2, eli], 3.0)
	_check(dana.is_live() and int(dana.me["id"]) == int(hub.room_of(code3)["participants"].keys()[1]), "...and it resumes on a fresh socket, as the same participant")
	# the rate guard
	var sent_before: int = host2.send_count
	for i in 300:
		host2.send({"t": "presence", "head": [0, 0, 0, 0, 0, 0, 1], "hands": [null, null], "laser": null, "cursor": null, "mode": "free"})
	_check(host2.send_count - sent_before <= 56 and host2.dropped_count >= 240, "a burst of presence is cut to the send rate (%d sent, %d dropped)" % [host2.send_count - sent_before, host2.dropped_count])
	var status_ok := true
	for i in 100:
		status_ok = status_ok and host2.send_state({"t": "status", "activity": "model", "detail": str(i)})
	_check(status_ok, "...but a state message is never dropped")
	# a renewed token
	var eli_rec2 := _record(eli)
	host2.send({"t": "token", "view_token": "tok-2", "view_expires_at": 12345.0})
	_pump([host2, eli, dana], 0.2)
	_check(eli.view_token == "tok-2" and eli_rec2["tokens"] == ["tok-2"] and dana.view_token == "tok-2", "a renewed view token replaces the old one at every observer")
	# remove
	var eli_closed := _record(eli)
	host2.send({"t": "remove", "id": int(eli.me["id"])})
	_pump([host2, eli, dana], 0.3)
	_check(eli.state == Client.State.CLOSED and eli_closed["closed"].size() == 1 and eli_closed["closed"][0][2] == "removed" and str(eli_closed["closed"][0][1]).contains("removed you"), "Remove: the person is told, in words, and is out")
	_check(not dana.participants.has(int(eli.me["id"])), "...and gone from everyone's roster")
	# leave
	var dana_closed := _record(dana)
	dana.leave()
	_pump([host2, dana], 0.3)
	_check(dana.state == Client.State.CLOSED and dana_closed["closed"][0][0] == "left" and not host2.participants.has(int(dana.me["id"])), "an observer's leave is a clean goodbye: nobody tries to resume it")
	_pump([dana], 30.0, 1.0)
	_check(dana_closed["closed"].size() == 1, "...and it stays left")
	# end
	var fay: Node = _joined(code3, "Fay")[0]
	var fay_rec := _record(fay)
	host2.end_session()
	_pump([host2, fay], 0.3)
	_check(host2.state == Client.State.CLOSED and host2_rec["closed"][-1][0] == "ended" and fay_rec["closed"][0][0] == "ended" and str(fay_rec["closed"][0][1]).contains("presenter ended"), "End: everyone is told the session is over")
	_check(not hub.rooms.has(code3), "...and the hub forgot the room")
	# --- Godot's WebSocketPeer loses the hub's last message when the hub closes at once (an error, an end): only the close code is left
	hub = Hub.new()
	hub.lose_final = true
	_clients.clear()
	var lh := _hosted()
	var lcode: String = lh[2]
	var lo := _joined(lcode, "Lena")
	var lobs: Node = lo[0]
	var lobs_rec: Dictionary = lo[1]
	var lhost: Node = lh[0]
	var lhost_rec: Dictionary = lh[1]
	_check(lobs.is_live() and lhost.is_live(), "with the hub's final messages lost (as Godot does), a normal host and join still work")
	var lwrong := _client()
	var lwrong_rec := _record(lwrong)
	lwrong.join("wss://hub.test", "ZZZZZZ", {"name": "X", "device": "quest", "client": "t"})
	_pump([], 1.0)
	_check(lwrong.state == Client.State.CLOSED and lwrong_rec["closed"].size() == 1 and lwrong_rec["closed"][0][0] == "error" and str(lwrong_rec["closed"][0][1]).contains("no session has that code"), "a refused join (close code 4000, the message lost): an error that lists what it can be, final, no retry")
	var lbadhost := _client()
	var lbadhost_rec := _record(lbadhost)
	lbadhost.host("wss://hub.test", "", _host_info())
	_pump([], 1.0)
	_check(lbadhost_rec["closed"].size() == 1 and lbadhost_rec["closed"][0][0] == "error" and str(lbadhost_rec["closed"][0][1]).contains("key"), "a refused host: the words say the key may be wrong")
	var lobs_closed: Array = []
	lobs.closed.connect(func(kind: String, text: String) -> void: lobs_closed.append([kind, text, lobs.last_code]))
	lhost.send({"t": "remove", "id": int(lobs.me["id"])})
	_pump([], 1.0)
	_check(lobs_closed.size() == 1 and lobs_closed[0][2] == "removed" and str(lobs_closed[0][1]).contains("removed you"), "Remove (close code 4003, the message lost): still told 'removed'")
	var lo2 := _joined(lcode, "Mo")
	var lobs2: Node = lo2[0]
	var lend: Array = []
	lobs2.closed.connect(func(kind: String, text: String) -> void: lend.append([kind, text]))
	var lopens: int = hub.open_count
	lhost.end_session()
	_pump([], 40.0)
	_check(lend.size() == 1 and lend[0][0] == "ended" and str(lend[0][1]).contains("ended") and hub.open_count == lopens, "End (close code 1000, the message lost): the observer knows the session ended and does NOT reconnect in a loop")
	hub = Hub.new()
	hub.lose_final = true
	hub.send_reason = true
	_clients.clear()
	var sh := _hosted()
	var scode: String = sh[2]
	var swrong := _client()
	var swrong_rec := _record(swrong)
	swrong.join("wss://hub.test", "ZZZZZZ", {"name": "X", "device": "quest", "client": "t"})
	_pump([], 1.0)
	_check(swrong_rec["closed"].size() == 1 and swrong_rec["closed"][0][2] == "bad_code" and str(swrong_rec["closed"][0][1]).contains("No session has that code"), "with the code in the close frame's reason (a hub from DIDSA-CAD P2), a lost refusal still gets its exact words")
	var sobs: Array = _joined(scode, "Oz")
	var send_text: Array = []
	sobs[0].closed.connect(func(kind: String, text: String) -> void: send_text.append([kind, text, sobs[0].last_code]))
	sh[0].end_session()
	_pump([], 1.0)
	_check(send_text.size() == 1 and send_text[0][2] == "ended" and send_text[0][1] == "The presenter ended the session.", "...and a lost end gets 'The presenter ended the session.'")
	hub.end_by_timeout("NONE00")
	hub = Hub.new()
	hub.lose_final = true
	_clients.clear()
	var rh := _hosted()
	var rcode: String = rh[2]
	var ro := _joined(rcode, "Ned")
	var robs: Node = ro[0]
	var robs_rec: Dictionary = ro[1]
	hub.drop(int(robs.me["id"]))
	_pump([], 0.3)
	hub.forget_resume_tokens()
	_pump([], 3.0)
	_check(robs.state == Client.State.CLOSED and robs_rec["closed"].size() == 1 and robs_rec["closed"][0][0] == "resume_failed" and str(robs_rec["closed"][0][1]).contains("Join again"), "a resume the hub refuses (4000, message lost): the session is gone, say so")

	# --- garbage from the hub is ignored
	hub = Hub.new()
	_clients.clear()
	var g := _hosted()
	g[0].transport_factory = hub.make_transport
	var gt = hub.transports[-1]
	gt.inbox.append({"text": "this is not json"})
	gt.inbox.append({"text": "[1,2,3]"})
	gt.inbox.append({"text": "{\"no_t\": 1}"})
	gt.inbox.append({"bytes": PackedByteArray([1, 2, 3])})
	_pump([g[0]], 0.3)
	_check(g[0].is_live(), "text that is not a message, and a binary frame, are ignored")
	quit()
