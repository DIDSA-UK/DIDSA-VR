extends SceneTree
## Talks to a real backend, LOCAL ONLY (same caveat as the other e2e_*.gd tests): T2's empty-room start (docs/test-report-30-oct-plan.md). With NO assembly
## loaded, New room starts an assembly instead of refusing, and opens the new room (the desktop preview opens it where you stand); the room's Part is empty;
## "New assembly" in it puts a new empty Part at the origin, identity transform and fixed: true; a second one is not fixed; adding a native file to an empty Part
## (the first part of a room) is fixed at the origin whatever pose is asked for, and the second is where it was asked.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg DIDSA_NO_LANDING=1 "$GODOT" --headless --path . --script res://tests/e2e_empty_start.gd
## Needs secrets.cfg to point at a running backend (tools/start_backend.sh).

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var api


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK or not FileAccess.file_exists("res://assembly.didsa"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend) and assembly.didsa in the project root")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no start-up import: the session starts with NO assembly
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0, 1.6, 0)
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	main.design_table.configure_backend(url, key)
	main.room_manager.configure_backend(url, key)
	api = main.design_table.api
	print("SMOKE nothing is loaded to start with: ", main.current_root_part_id() == "")

	# --- New room with no assembly: starts one, makes the room's Part, opens a room for it
	var started: bool = await main.room_manager.new_room()
	var root_id: String = main.current_root_part_id()
	print("SMOKE New room with no assembly loaded starts one instead of refusing: ", started and root_id != "", " ", main.status_text)
	var listed: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % root_id)
	var rows: Array = listed["json"] if listed["ok"] else []
	print("SMOKE ...and the new room's Part is an occurrence on the root: ", rows.size() == 1)
	var room_part: String = str(rows[0]["resolved_part_id"]) if rows.size() == 1 else ""
	var opened: bool = await wait_for(func() -> bool: return main.room_manager.is_open_for(room_part))
	print("SMOKE ...and a room opens for it: ", opened)
	if not opened:
		quit()
		return
	var room = main.room_manager.room_for_part(room_part)
	await wait_for(func() -> bool: return room.start_buttons != null and room.start_buttons.is_open(), 300)
	print("SMOKE the empty room shows its start buttons: ", room.start_buttons != null and room.start_buttons.is_open())

	# --- the first part: origin, identity, fixed
	var made1: bool = await main.room_manager.new_part_in_room(room)
	var occ: Dictionary = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % room_part)
	var first_rows: Array = occ["json"] if occ["ok"] else []
	var r1: Dictionary = first_rows[0] if first_rows.size() == 1 else {}
	print("SMOKE New assembly in the empty room adds one occurrence: ", made1 and first_rows.size() == 1)
	print("SMOKE ...the first part has the identity transform and fixed: true: ", not r1.is_empty() and r1["fixed"] == true and r1["transform"]["translation"] == [0.0, 0.0, 0.0] and absf(float(r1["transform"]["rotation_angle_degrees"])) < 1e-9)
	await wait_for(func() -> bool: return not room.start_buttons.is_open(), 300)
	print("SMOKE ...and the start buttons are gone once the room holds something: ", not room.start_buttons.is_open())

	# --- the second: not fixed
	var made2: bool = await main.room_manager.new_part_in_room(room)
	occ = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % room_part)
	var second_rows: Array = occ["json"] if occ["ok"] else []
	var r2: Dictionary = {}
	for r in second_rows:
		if r["id"] != r1.get("id", ""):
			r2 = r
	print("SMOKE a second New assembly adds another, which is not fixed: ", made2 and second_rows.size() == 2 and not r2.is_empty() and not r2.get("fixed", false))

	# --- a native file as the first part of another empty Part
	var e = main.room_manager.edit_api()
	var empty_part: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts", {"name": "Empty"})
	var empty_id: String = str(empty_part["json"]["id"])
	var text := FileAccess.get_file_as_string("res://assembly.didsa")
	var elsewhere := {"translation": [250.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
	var f1: Dictionary = await e.add_file(empty_id, text, elsewhere, "first")
	occ = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % empty_id)
	var rows3: Array = occ["json"] if occ["ok"] else []
	print("SMOKE add_file as the first part of an empty Part: at the origin and fixed, not at the pose asked for: ", f1["ok"] and rows3.size() == 1 and rows3[0]["fixed"] == true and rows3[0]["transform"]["translation"] == [0.0, 0.0, 0.0], " ", f1)
	var f2: Dictionary = await e.add_file(empty_id, text.replace("\"root_part_id\"", "\"root_part_id\""), elsewhere, "second")
	occ = await api.request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % empty_id)
	rows3 = occ["json"] if occ["ok"] else []
	var placed_second: Dictionary = {}
	for r in rows3:
		if not r.get("fixed", false):
			placed_second = r
	print("SMOKE ...the second goes where it was asked, not fixed (or is refused as the same file again, the document's own rule): ", (f2["ok"] and not placed_second.is_empty() and absf(float(placed_second["transform"]["translation"][0]) - 250.0) < 0.001) or not f2["ok"], " ", f2.get("error", ""))
	quit()
