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

	quit()
