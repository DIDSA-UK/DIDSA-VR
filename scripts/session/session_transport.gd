extends RefCounted
## One WebSocket to the session hub, behind the few calls session_client.gd needs, so a test can put a fake in its place (tests/fake_session_hub.gd
## makes transports with this same surface). Text frames are the JSON messages; binary frames are voice (P3) and are handed on as bytes.
##
## The hub's address is wss:// (or ws:// on a local network). A presenter sends the hub key as X-API-Key on the handshake (set_handshake_headers is how
## browser_window.gd sends the relay's); an observer sends none. Messages are at most 64 KB at the hub, but a welcome carries the whole snapshot, so
## the inbound buffer is generous (the relay's lesson, 11 Nov 2026: Godot's default 64 KiB closes the connection on a bigger frame).

const BUFFER_BYTES := 4 * 1024 * 1024

var _peer := WebSocketPeer.new()
var _opened := false


func open(url: String, headers: PackedStringArray) -> int:
	## Starts connecting. OK, or the engine's error.
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = BUFFER_BYTES
	_peer.outbound_buffer_size = BUFFER_BYTES / 4
	_peer.max_queued_packets = 4096
	_peer.handshake_headers = headers
	_opened = false
	return _peer.connect_to_url(url)


func poll() -> void:
	_peer.poll()


func is_open() -> bool:
	return _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_connecting() -> bool:
	return _peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING


func is_closed() -> bool:
	return _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED


func read() -> Array:
	## Every packet that has arrived: {text: String} or {bytes: PackedByteArray}.
	var out: Array = []
	while _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if _peer.was_string_packet():
			out.append({"text": packet.get_string_from_utf8()})
		else:
			out.append({"bytes": packet})
	return out


func send_text(text: String) -> bool:
	return _peer.send_text(text) == OK


func send_bytes(bytes: PackedByteArray) -> bool:
	return _peer.send(bytes, WebSocketPeer.WRITE_MODE_BINARY) == OK


func close(code: int = 1000, reason: String = "") -> void:
	_peer.close(code, reason)


func close_code() -> int:
	return _peer.get_close_code()
