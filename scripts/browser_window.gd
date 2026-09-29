extends "res://scripts/diegetic_panel.gd"
## Milestone 3's Browser window - and, for free, its PDF reader too (see
## below). This is the generalized answer to a question John asked after
## seeing DIDSA-CAD run as a floating window: "if DIDSA-CAD can run in a
## floating window, can any app?" (docs/status.md has the full framing).
## The answer here is: yes, for anything that's really a web page,
## including headless Chrome's own built-in PDF viewer - confirmed for
## real, not assumed, against a live browser-relay + real Chromium
## instance in this repo's own dev sandbox (see docs/status.md's "Browser
## window" section for exactly what was run and what it proved).
##
## Unlike every other window in this repo, this one's content isn't drawn
## by Godot at all - it's a live JPEG screencast of a real headless
## Chromium tab, decoded frame-by-frame and shown on a TextureRect. The
## browser-relay service (DIDSA-CAD repo, browser-relay/) is a "dumb
## relay": every Chrome DevTools Protocol (CDP) message below is built and
## parsed entirely in this file, sent over a plain authenticated
## WebSocket, and the relay just forwards raw frames to/from the real CDP
## WebSocket of a Chrome tab it manages - see that service's own README
## for why the split is drawn there specifically (so the relay's own
## surface never has to grow just because this file starts using a new
## CDP domain).
##
## The CDP message-building/parsing functions below are all pure (no
## WebSocket, no live state) specifically so tests/browser_window.gd can
## exercise them directly, the same way calculator_window.gd's
## evaluate_expression()/_floatify() are tested - this file's own
## _poll_relay()/_send_cdp() are the only parts that touch a real
## WebSocketPeer, and aren't unit-tested (see docs/status.md for what WAS
## tested against a real relay+Chromium instead).

const _DEVICE_WIDTH := 800
const _DEVICE_HEIGHT := 600
const _SCREENCAST_QUALITY := 70

var _relay_url := "" ## e.g. "ws://your-relay-host:8100" - no trailing slash, no "/ws" (appended below)
var _relay_api_key := ""
var _start_url := "about:blank"

var _ws: WebSocketPeer
var _next_id := 1
var _connected := false

var _view: TextureRect
var _status_label: Label
var _url_bar: LineEdit
var _texture: ImageTexture
var _keyboard: Node ## main.gd's popup keyboard (set_keyboard()); the full layout types web addresses and page text


func setup_browser(left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	panel_title = "Browser"
	panel_size = Vector2(0.36, 0.26)
	viewport_size = Vector2i(640, 460)
	open_distance = 0.65
	open_lateral_offset = 0.15
	super.setup(left, right, camera)


func set_keyboard(keyboard: Node) -> void:
	_keyboard = keyboard


func configure_relay(relay_url: String, relay_api_key: String, start_url: String = "about:blank") -> void:
	_relay_url = relay_url
	_relay_api_key = relay_api_key
	_start_url = start_url


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 4)
	box.add_child(toolbar)

	var back := Button.new()
	back.text = "<"
	back.pressed.connect(func() -> void: _send_cdp("Runtime.evaluate", {"expression": "history.back()"}))
	toolbar.add_child(back)

	var forward := Button.new()
	forward.text = ">"
	forward.pressed.connect(func() -> void: _send_cdp("Runtime.evaluate", {"expression": "history.forward()"}))
	toolbar.add_child(forward)

	var refresh := Button.new()
	refresh.text = "↻"
	refresh.pressed.connect(func() -> void: _send_cdp("Page.reload", {}))
	toolbar.add_child(refresh)

	# The address bar shows where you are; poking it opens the full keyboard
	# pre-filled with the address (typing replaces it, like a browser's URL bar).
	# Not directly editable: there's no physical keyboard to type into a LineEdit.
	_url_bar = LineEdit.new()
	_url_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_url_bar.text = _start_url
	_url_bar.editable = false
	_url_bar.text_submitted.connect(_navigate)
	_url_bar.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			edit_address()
	)
	toolbar.add_child(_url_bar)

	var go := Button.new()
	go.text = "Go"
	go.pressed.connect(edit_address)
	toolbar.add_child(go)

	var type_button := Button.new()
	type_button.text = "Aa"
	type_button.tooltip_text = "Type into the page: click a text box on the page first, then use this keyboard"
	type_button.pressed.connect(type_into_page)
	toolbar.add_child(type_button)

	_view = TextureRect.new()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_SCALE
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.gui_input.connect(_on_view_gui_input)
	box.add_child(_view)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	_status_label.text = "Not connected"
	box.add_child(_status_label)

	return box


func _on_opened() -> void:
	if _relay_url.is_empty() or _relay_api_key.is_empty():
		_status_label.text = "No browser relay configured (see secrets.cfg.example)"
		return
	_connect_to_relay()


func _on_closed() -> void:
	## Disconnecting (rather than leaving the tab open in the background)
	## frees the relay's per-tab slot the moment the window closes - see
	## browser-relay/app/chrome.py's BROWSER_RELAY_MAX_SESSIONS cap, sized
	## for a 4GB Raspberry Pi shared with the OCCT backend. Reopening
	## reconnects fresh rather than trying to resume a session.
	if _ws != null:
		_ws.close()
		_ws = null
	_connected = false
	_status_label.text = "Not connected"


func _connect_to_relay() -> void:
	_ws = WebSocketPeer.new()
	_ws.handshake_headers = PackedStringArray(["X-API-Key: " + _relay_api_key])
	var err := _ws.connect_to_url(_relay_url.rstrip("/") + "/ws")
	if err != OK:
		_status_label.text = "Couldn't start connecting to relay (error %d)" % err
		_ws = null
		return
	_status_label.text = "Connecting..."
	_connected = false


func _process(delta: float) -> void:
	super._process(delta)
	_poll_relay()


func _poll_relay() -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			_status_label.text = "Connected"
			_send_startup_sequence()
		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			_handle_incoming(packet.get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connected or _status_label.text == "Connecting...":
			var code := _ws.get_close_code()
			_status_label.text = "Disconnected (code %d)" % code
		_connected = false
		_ws = null


func _send_startup_sequence() -> void:
	_send_cdp("Page.enable", {})
	_send_cdp("Emulation.setDeviceMetricsOverride", build_device_metrics_params(_DEVICE_WIDTH, _DEVICE_HEIGHT))
	_send_cdp("Page.navigate", {"url": _start_url})
	_send_cdp(
		"Page.startScreencast",
		build_start_screencast_params(_DEVICE_WIDTH, _DEVICE_HEIGHT, _SCREENCAST_QUALITY)
	)


func edit_address() -> void:
	## Opens the full keyboard on the current address; Go navigates (a bare
	## "example.com" gets https://, plain words become a web search — see
	## normalize_url()).
	if _keyboard == null:
		return
	if _keyboard.is_open():
		_keyboard.close()
	_keyboard.open_for(_url_bar.text if _url_bar.text != "about:blank" else "", func(text: String) -> void:
		var url := normalize_url(text)
		if url != "":
			_url_bar.text = url
			_navigate(url)
	, {"mode": "full", "title": "Web address or search", "confirm_label": "Go"})


func type_into_page() -> void:
	## Live typing into whatever text box you've clicked on the page: every
	## key goes straight to the browser (CDP Input.insertText / key events),
	## and the keyboard stays open until Done.
	if _keyboard == null:
		return
	if _keyboard.is_open():
		_keyboard.close()
	_keyboard.open_for("", Callable(), {"mode": "full", "live": true, "title": "Typing into the page — click a text box on the page first", "on_input": _on_typed})


func _on_typed(kind: String, value: String) -> void:
	if kind == "text":
		_send_cdp("Input.insertText", build_insert_text_params(value))
	else:
		for event in key_events_for(value):
			_send_cdp("Input.dispatchKeyEvent", event)


func _navigate(url: String) -> void:
	if url.is_empty():
		return
	_send_cdp("Page.navigate", {"url": url})


func _send_cdp(method: String, params: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var id := _next_id
	_next_id += 1
	_ws.send_text(JSON.stringify(build_message(id, method, params)))


func _handle_incoming(text: String) -> void:
	var parsed := parse_incoming(text)
	match parsed.get("kind"):
		"screencast_frame":
			_on_screencast_frame(parsed["params"])
		"frame_navigated":
			var url := extract_frame_url(parsed)
			if not url.is_empty() and _url_bar != null:
				_url_bar.text = url
		_:
			pass # response to a fire-and-forget command, or an event we don't act on


func _on_screencast_frame(params: Dictionary) -> void:
	var bytes := Marshalls.base64_to_raw(params.get("data", ""))
	var image := Image.new()
	if image.load_jpg_from_buffer(bytes) == OK:
		if _texture == null:
			_texture = ImageTexture.create_from_image(image)
			_view.texture = _texture
		else:
			_texture.update(image)
	var session_id = params.get("sessionId")
	if session_id != null:
		_send_cdp("Page.screencastFrameAck", {"sessionId": session_id})


func _on_view_gui_input(event: InputEvent) -> void:
	if _view.size.x <= 0.0 or _view.size.y <= 0.0:
		return
	var device_pos := scale_to_device(event.position, _view.size, Vector2i(_DEVICE_WIDTH, _DEVICE_HEIGHT))
	if event is InputEventMouseMotion:
		_send_cdp("Input.dispatchMouseEvent", build_mouse_event_params("mouseMoved", device_pos))
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var event_type := "mousePressed" if event.pressed else "mouseReleased"
		_send_cdp("Input.dispatchMouseEvent", build_mouse_event_params(event_type, device_pos, "left"))


# --- Pure functions (no WebSocket, no node state) - see this file's own
# docstring for why these are split out, and tests/browser_window.gd for
# what exercises them.

static func build_message(id: int, method: String, params: Dictionary) -> Dictionary:
	return {"id": id, "method": method, "params": params}


static func build_device_metrics_params(width: int, height: int) -> Dictionary:
	return {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": false}


static func build_start_screencast_params(width: int, height: int, quality: int) -> Dictionary:
	return {"format": "jpeg", "quality": quality, "maxWidth": width, "maxHeight": height}


static func build_mouse_event_params(event_type: String, device_pos: Vector2, button: String = "none") -> Dictionary:
	var params := {"type": event_type, "x": device_pos.x, "y": device_pos.y, "button": button}
	if event_type != "mouseMoved":
		params["clickCount"] = 1
	return params


static func build_insert_text_params(text: String) -> Dictionary:
	return {"text": text}


static func key_events_for(key: String) -> Array:
	## The CDP Input.dispatchKeyEvent params for a non-text key (Backspace,
	## Enter, Tab), down then up. Text keys go through Input.insertText instead
	## (works for any character, incl. ones with no physical key). Enter sends
	## its "\r" text so a focused form actually submits.
	match key:
		"Backspace":
			return [
				{"type": "rawKeyDown", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8},
				{"type": "keyUp", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8},
			]
		"Enter":
			return [
				{"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": "\r"},
				{"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13},
			]
		"Tab":
			return [
				{"type": "rawKeyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9},
				{"type": "keyUp", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9},
			]
	return []


static func normalize_url(text: String) -> String:
	## What typing into the address bar means: a full URL (has "://", or an
	## about:/data:/file: one) is used as typed; something that looks like a
	## host ("example.com", "localhost:8080", "10.0.0.5/page") gets https://;
	## anything else — words, or anything with a space — is a web search.
	var t := text.strip_edges()
	if t.is_empty():
		return ""
	if "://" in t or t.begins_with("about:") or t.begins_with("data:") or t.begins_with("file:"):
		return t
	var host := t.split("/")[0].split("?")[0]
	if not (" " in t) and ("." in host or host.begins_with("localhost")):
		return "https://" + t
	return "https://duckduckgo.com/?q=" + t.uri_encode()


static func scale_to_device(local_pos: Vector2, rect_size: Vector2, device_size: Vector2i) -> Vector2:
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return Vector2.ZERO
	return Vector2(
		clampf(local_pos.x / rect_size.x, 0.0, 1.0) * device_size.x,
		clampf(local_pos.y / rect_size.y, 0.0, 1.0) * device_size.y
	)


static func parse_incoming(text: String) -> Dictionary:
	## Classifies one incoming relay message into what _handle_incoming()
	## needs to act on, without touching any live state - a malformed or
	## irrelevant message (a bare command response, an event this window
	## doesn't act on) comes back as {"kind": "other"}, never an error, so
	## a relay/Chrome version sending one extra event type can't break this
	## window - it's just ignored.
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"kind": "other"}
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return {"kind": "other"}
	var method: String = data.get("method", "")
	if method == "Page.screencastFrame":
		return {"kind": "screencast_frame", "params": data.get("params", {})}
	if method == "Page.frameNavigated":
		return {"kind": "frame_navigated", "params": data.get("params", {})}
	return {"kind": "other"}


static func extract_frame_url(parsed: Dictionary) -> String:
	## Only the top-level frame's own navigation should update the URL bar -
	## a navigated *child* frame (Chrome's PDF viewer loads its renderer UI
	## into one, confirmed when this was run for real against a local PDF;
	## see docs/status.md) has a "parentId" and must not overwrite it.
	var frame: Dictionary = parsed.get("params", {}).get("frame", {})
	if frame.get("parentId", "") != "":
		return ""
	return frame.get("url", "")
