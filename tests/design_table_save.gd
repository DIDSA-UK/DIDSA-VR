extends SceneTree
## Saving what was edited in VR (main.gd's save_native_snapshot and helpers), the parts that need no backend: the flat app's extra
## top-level keys of the opened file are written back (never overriding a key the export has), the snapshot path is a NEW file in
## a folder the Files tab scans and never the file the session came from, and saving with no backend says so instead of writing.
## The real export / write / re-import is in tests/e2e_design_table.gd.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_save.gd  (see tests/README.md)

func _initialize() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame

	main._remember_native_extras({"schema_version": 1, "document": {}, "sketches": [], "hidden_feature_ids": ["a", "b"], "section_planes": [{"x": 1}]})
	print("SMOKE only the keys the backend would drop are remembered: ", main._native_extras.keys().size() == 2 and main._native_extras.has("hidden_feature_ids") and main._native_extras.has("section_planes"))
	var export := {"schema_version": 1, "document": {"root_part_id": "R"}, "sketches": []}
	var extras: Dictionary = main.native_extras_to_add(export)
	print("SMOKE a save writes the flat app's own extra keys back beside the backend's export: ", extras.keys().size() == 2 and extras["hidden_feature_ids"] == ["a", "b"] and extras["section_planes"] == [{"x": 1}])
	print("SMOKE ...but never over a key the export already has: ", not main.native_extras_to_add({"schema_version": 1, "hidden_feature_ids": ["from-backend"]}).has("hidden_feature_ids"))
	var raw := '{"schema_version":1,"document":{"id":"d","parts":[]},"sketches":[{"rotation_quarter_turns":0,"flip":false,"points":[{"x":1.5}]}]}'
	var appended: String = main.append_to_json_object(raw, extras)
	var reparsed = JSON.parse_string(appended)
	print("SMOKE the extras are added to the backend's own text, which stays valid JSON: ", reparsed is Dictionary and reparsed["hidden_feature_ids"] == ["a", "b"] and reparsed["sketches"].size() == 1 and reparsed["schema_version"] == 1)
	print("SMOKE ...with its integers still integers (Godot would write 0 as 0.0, which the backend rejects): ", appended.contains('"rotation_quarter_turns":0,') and not appended.contains("0.0"))
	print("SMOKE ...and nothing else touched: ", appended.begins_with(raw.substr(0, raw.length() - 1)))
	print("SMOKE with nothing to add the text is returned as it came: ", main.append_to_json_object(raw + "\n", {}) == raw)
	print("SMOKE text that isn't an object is refused: ", main.append_to_json_object("[1, 2]", extras) == "")
	print("SMOKE an empty object still takes extras: ", JSON.parse_string(main.append_to_json_object("{}", {"k": 1})) == {"k": 1.0})
	main._remember_native_extras({"schema_version": 1, "document": {}})
	print("SMOKE opening a different file replaces the remembered keys: ", main._native_extras.is_empty())

	var path: String = main.snapshot_path()
	print("SMOKE the snapshot is a new .didsa in a folder the Files tab scans: ", path.get_extension() == "didsa" and path.begins_with("user://models") and "-vr-" in path)
	print("SMOKE ...never the file the session came from: ", path != main.native_file_path and path.get_file() != main.native_file_path.get_file())
	var stamped := RegEx.create_from_string("^.+-vr-\\d{8}-\\d{6}\\.didsa$")
	print("SMOKE ...named after the file it came from plus the time it was saved: ", stamped.search(path.get_file()) != null and path.get_file().begins_with(main.native_file_path.get_file().get_basename()))
	var written: String = await main.save_native_snapshot()
	print("SMOKE saving with no backend writes nothing and says why: ", written == "" and main.status_text.contains("needs a backend"))
	quit()
