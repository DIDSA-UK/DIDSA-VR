extends SceneTree
## Pure-logic test for browser_window.gd's CDP message building/parsing and
## coordinate scaling - no scene, no WebSocket, no live Chrome. See
## docs/status.md for the separate real end-to-end pass (a real
## browser-relay + real Chromium instance) that covers what this file
## can't: the actual network round trip.
## Run: "$GODOT" --headless --path . --script res://tests/browser_window.gd

const BrowserWindow := preload("res://scripts/browser_window.gd")


func _initialize() -> void:
	var msg := BrowserWindow.build_message(7, "Page.navigate", {"url": "https://example.com"})
	print("SMOKE build_message carries id/method/params through untouched: ",
		msg["id"] == 7 and msg["method"] == "Page.navigate" and msg["params"]["url"] == "https://example.com")

	var metrics := BrowserWindow.build_device_metrics_params(800, 600)
	print("SMOKE device metrics params are non-mobile at the requested size: ",
		metrics["width"] == 800 and metrics["height"] == 600 and metrics["mobile"] == false)

	var screencast := BrowserWindow.build_start_screencast_params(800, 600, 70)
	print("SMOKE startScreencast params request jpeg at the given size/quality: ",
		screencast["format"] == "jpeg" and screencast["maxWidth"] == 800
		and screencast["maxHeight"] == 600 and screencast["quality"] == 70)

	var move := BrowserWindow.build_mouse_event_params("mouseMoved", Vector2(12, 34))
	print("SMOKE a mouseMoved event carries no clickCount: ", not move.has("clickCount"))

	var press := BrowserWindow.build_mouse_event_params("mousePressed", Vector2(12, 34), "left")
	print("SMOKE a mousePressed event carries button and clickCount: ",
		press["button"] == "left" and press["clickCount"] == 1)

	var centre := BrowserWindow.scale_to_device(Vector2(320, 230), Vector2(640, 460), Vector2i(800, 600))
	print("SMOKE scale_to_device maps the view's centre to the device's centre: ",
		centre.is_equal_approx(Vector2(400, 300)))

	var corner := BrowserWindow.scale_to_device(Vector2(-50, 5000), Vector2(640, 460), Vector2i(800, 600))
	print("SMOKE scale_to_device clamps out-of-bounds local positions into range: ",
		corner.x == 0.0 and corner.y == 600.0)

	print("SMOKE scale_to_device on a zero-size view returns zero, not a divide-by-zero crash: ",
		BrowserWindow.scale_to_device(Vector2(10, 10), Vector2.ZERO, Vector2i(800, 600)) == Vector2.ZERO)

	var frame_json := JSON.stringify({
		"method": "Page.screencastFrame",
		"params": {"data": "abc123", "sessionId": 5},
	})
	var parsed_frame := BrowserWindow.parse_incoming(frame_json)
	print("SMOKE parse_incoming recognises a screencast frame: ",
		parsed_frame["kind"] == "screencast_frame" and parsed_frame["params"]["sessionId"] == 5)

	var top_nav_json := JSON.stringify({
		"method": "Page.frameNavigated",
		"params": {"frame": {"id": "F1", "url": "https://example.com/page"}},
	})
	var parsed_top_nav := BrowserWindow.parse_incoming(top_nav_json)
	print("SMOKE a top-level frameNavigated's URL is extracted: ",
		BrowserWindow.extract_frame_url(parsed_top_nav) == "https://example.com/page")

	var child_nav_json := JSON.stringify({
		"method": "Page.frameNavigated",
		"params": {"frame": {"id": "F2", "parentId": "F1", "url": "chrome-extension://pdf-viewer/index.html"}},
	})
	var parsed_child_nav := BrowserWindow.parse_incoming(child_nav_json)
	print("SMOKE a child frame's navigation (e.g. the PDF viewer's own iframe) doesn't override the URL bar: ",
		BrowserWindow.extract_frame_url(parsed_child_nav) == "")

	var response_json := JSON.stringify({"id": 3, "result": {}})
	var parsed_response := BrowserWindow.parse_incoming(response_json)
	print("SMOKE a plain command response (no 'method') is classified as 'other', not misparsed: ",
		parsed_response["kind"] == "other")

	print("SMOKE malformed JSON doesn't crash parse_incoming: ",
		BrowserWindow.parse_incoming("not json{{{").get("kind") == "other")

	# --- typing: address normalisation and the CDP key/text events the full keyboard drives
	print("SMOKE a bare host gets https://: ", BrowserWindow.normalize_url("example.com") == "https://example.com")
	print("SMOKE a host with a path/query gets https://: ", BrowserWindow.normalize_url("news.bbc.co.uk/sport?x=1") == "https://news.bbc.co.uk/sport?x=1")
	print("SMOKE a full URL is left exactly as typed: ", BrowserWindow.normalize_url("http://10.0.0.5:8000/a") == "http://10.0.0.5:8000/a")
	print("SMOKE localhost:port is a host, not a search: ", BrowserWindow.normalize_url("localhost:8080") == "https://localhost:8080")
	print("SMOKE about:/file: addresses pass through: ", BrowserWindow.normalize_url("about:blank") == "about:blank" and BrowserWindow.normalize_url("file:///tmp/a.pdf") == "file:///tmp/a.pdf")
	print("SMOKE words become a web search: ", BrowserWindow.normalize_url("spur gear module") == "https://duckduckgo.com/?q=spur%20gear%20module")
	print("SMOKE a single word with no dot is a search too: ", BrowserWindow.normalize_url("gears").begins_with("https://duckduckgo.com/?q="))
	print("SMOKE surrounding spaces are trimmed and empty stays empty: ", BrowserWindow.normalize_url("  example.com  ") == "https://example.com" and BrowserWindow.normalize_url("   ") == "")
	print("SMOKE Input.insertText params carry the text: ", BrowserWindow.build_insert_text_params("h€llo") == {"text": "h€llo"})
	var enter := BrowserWindow.key_events_for("Enter")
	print("SMOKE Enter is keyDown (with its \\r text, so forms submit) then keyUp: ", enter.size() == 2 and enter[0]["type"] == "keyDown" and enter[0]["text"] == "\r" and enter[1]["type"] == "keyUp" and enter[0]["windowsVirtualKeyCode"] == 13)
	var back := BrowserWindow.key_events_for("Backspace")
	print("SMOKE Backspace is rawKeyDown then keyUp, vk 8: ", back.size() == 2 and back[0]["type"] == "rawKeyDown" and back[0]["windowsVirtualKeyCode"] == 8)
	print("SMOKE Tab is vk 9: ", BrowserWindow.key_events_for("Tab")[0]["windowsVirtualKeyCode"] == 9)
	print("SMOKE an unknown key sends nothing: ", BrowserWindow.key_events_for("F13").is_empty())

	# The relay address as WebSocketPeer needs it (it refuses http(s):// with error 31, Godot 4.7.2): bug report 10 Nov 2026.
	print("SMOKE relay address: ws:// kept, trailing slash and /ws dropped: ", BrowserWindow.relay_ws_url(" ws://192.168.1.9:8100/ws/ ") == "ws://192.168.1.9:8100")
	print("SMOKE relay address: http(s):// becomes ws(s)://: ", BrowserWindow.relay_ws_url("http://192.168.1.9:8100") == "ws://192.168.1.9:8100" and BrowserWindow.relay_ws_url("HTTPS://relay.example.net/") == "wss://relay.example.net")
	# A blank window with "Connected" (owner's report, 11 Nov 2026): Chrome refused Page.startScreencast mid-navigation, and a real page's frame
	# was bigger than WebSocketPeer's default 64 KiB message limit. Run against a live relay + Chromium: before, no frame at all; after, about:blank
	# and an 800x600 busy page both shown (the live run is not in this suite: it needs Chromium and the relay).
	print("SMOKE a page finishing loading restarts the screencast (loadEventFired and frameStoppedLoading): ", BrowserWindow.parse_incoming('{"method":"Page.loadEventFired","params":{}}')["kind"] == "page_loaded" and BrowserWindow.parse_incoming('{"method":"Page.frameStoppedLoading","params":{"frameId":"F"}}')["kind"] == "page_loaded")
	var refused := BrowserWindow.parse_incoming('{"id":4,"error":{"code":-32000,"message":"Not attached to an active page"}}')
	print("SMOKE a refused command is read as an error with its id: ", refused["kind"] == "error" and refused["id"] == 4 and "Not attached" in refused["message"])
	print("SMOKE ...a plain command response is still not an error: ", BrowserWindow.parse_incoming('{"id":5,"result":{}}')["kind"] == "other")
	print("SMOKE the relay connection takes a 1 MB message (a real page's frame is ~200 KB; the default limit is 64 KiB): ", BrowserWindow.RELAY_INBOUND_BUFFER >= 1024 * 1024)
	print("SMOKE a relay that never opened says what to check (key, port, network): ", "BROWSER_RELAY_API_KEY" in BrowserWindow.relay_failure_text("ws://a:8100", false, -1) and "8100" in BrowserWindow.relay_failure_text("ws://a:8100", false, -1))

	quit()
