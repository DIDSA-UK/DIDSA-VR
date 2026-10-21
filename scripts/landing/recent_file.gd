extends RefCounted
## The last file opened, for the landing's Continue tile: user://recent.cfg ([recent] path, name, when). Written by main.gd after a
## model loads, read by the landing. One file only for now (a list is "Recent" in docs/landing-scope.md, suggested later).

const PATH := "user://recent.cfg"
const PATH_ENV := "DIDSA_RECENT_PATH" ## set to read and write a different file (tests/run_all.sh does, so a test run never touches the real one)


static func path() -> String:
	var override := OS.get_environment(PATH_ENV)
	return override if override != "" else PATH


static func remember(file_path: String) -> void:
	var config := ConfigFile.new()
	config.set_value("recent", "path", file_path)
	config.set_value("recent", "name", file_path.get_file())
	config.set_value("recent", "when", Time.get_unix_time_from_system())
	var err := config.save(path())
	if err != OK:
		push_warning("DIDSA VR: couldn't save %s (error %d)" % [path(), err])


static func last() -> Dictionary:
	## {path, name} of the last file, or {} when there is none or it is gone from disk.
	var config := ConfigFile.new()
	if config.load(path()) != OK:
		return {}
	var file_path := str(config.get_value("recent", "path", ""))
	if file_path == "" or not FileAccess.file_exists(file_path):
		return {}
	return {"path": file_path, "name": str(config.get_value("recent", "name", file_path.get_file()))}


static func needs_server(file_path: String) -> bool:
	## A glb opens with no server; a native file (and STEP / STL / OBJ) is meshed by the backend.
	return file_path.get_extension().to_lower() not in ["glb", "gltf"]
