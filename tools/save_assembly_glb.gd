extends SceneTree
## Saves an assembly as the glb the headset would load: composes a native file with every file it references (the app's own
## native_compose.gd, so multi-file assemblies work), imports it into a CAD backend in a throwaway document session, and writes
## `GET .../assembly-mesh.glb` to disk. For the P0 Cardboard spike (docs/live-sessions-spikes.md, "Spike C"), which loads glbs the
## owner serves from the PC; useful for any test that wants a real assembly as a glb.
##
## Usage (from the project root; the backend from secrets.cfg, or CAD_URL / CAD_KEY in the environment):
##   godot --headless --path . --script res://tools/save_assembly_glb.gd -- <native file> <out.glb> [quality 0..1, default 0.5]
## e.g. -- demo/assemblies/gear_train/Gear_train.didsa build/gear_train.glb

const NativeCompose := preload("res://scripts/native_compose.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		_fail("usage: -- <native file> <out.glb> [quality]")
		return
	var source := _absolute(args[0])
	var out := _absolute(args[1])
	var quality := float(args[2]) if args.size() > 2 else 0.5
	var url := OS.get_environment("CAD_URL")
	var key := OS.get_environment("CAD_KEY")
	if url.is_empty() or key.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load("res://secrets.cfg") == OK:
			url = str(cfg.get_value("backend", "url", url))
			key = str(cfg.get_value("backend", "api_key", key))
	if url.is_empty() or key.is_empty():
		_fail("no backend: set CAD_URL and CAD_KEY, or fill in secrets.cfg")
		return
	var composed: Dictionary = NativeCompose.compose(source, [source.get_base_dir()])
	if not composed.get("ok", false):
		_fail("could not compose %s: %s" % [source, composed.get("error", "?")])
		return
	var root_id := str((composed["parsed"] as Dictionary).get("document", {}).get("root_part_id", ""))
	var headers := ["X-API-Key: " + key, "X-Document-Session: glb-export-%d" % Time.get_ticks_usec(), "Content-Type: application/json"]
	var imported: Array = await _request(url + "/document/import/native", headers, HTTPClient.METHOD_POST, composed["text"])
	if int(imported[1]) != 200:
		_fail("import failed: HTTP %d %s" % [imported[1], (imported[3] as PackedByteArray).get_string_from_utf8().left(300)])
		return
	var glb: Array = await _request("%s/document/parts/%s/assembly-mesh.glb?quality=%s" % [url, root_id, str(quality)], headers.slice(0, 2), HTTPClient.METHOD_GET, "")
	if int(glb[1]) != 200:
		_fail("glb failed: HTTP %d" % glb[1])
		return
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		_fail("cannot write %s" % out)
		return
	file.store_buffer(glb[3])
	file.close()
	var note := NativeCompose.unresolved_note(composed)
	print("saved %s: %d KB from %s%s" % [out, (glb[3] as PackedByteArray).size() / 1024, source, note])
	quit(0)


func _request(url: String, headers: Array, method: int, body: String) -> Array:
	var req := HTTPRequest.new()
	req.timeout = 600
	root.add_child(req)
	await process_frame # a node added in _initialize is in the tree only from the next frame
	var err := req.request(url, PackedStringArray(headers), method, body)
	if err != OK:
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
	var result: Array = await req.request_completed
	req.queue_free()
	return result


func _absolute(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path("res://").path_join(path)


func _fail(text: String) -> void:
	printerr("save_assembly_glb: ", text)
	quit(1)
