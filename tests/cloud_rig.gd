extends RefCounted
## Shared by the cloud (server project) tests: a fake store (tests/fake_project_store.gd), a client on it, one CloudProject over a temp mirror folder and a temp state
## folder under user://, and small helpers to write fixture files. `restart()` is "the app was closed and opened again": a new CloudProject over the same folders.

const FakeStore := preload("res://tests/fake_project_store.gd")
const CloudStoreClient := preload("res://scripts/cloud/cloud_store_client.gd")
const CloudProject := preload("res://scripts/cloud/cloud_project.gd")
const CloudState := preload("res://scripts/cloud/cloud_state.gd")
const CloudFiles := preload("res://scripts/cloud/cloud_files.gd")

var fake
var client
var project
var name := "Gearbox"
var mirror := ""
var state_dir := ""
var device := "Quest 3"
var held: Array = []


func _init(test_name: String, p_name: String = "Gearbox") -> void:
	name = p_name
	var base := ProjectSettings.globalize_path("user://cloud_test").path_join(test_name)
	wipe(base)
	mirror = base.path_join("mirror")
	state_dir = base.path_join("state")
	DirAccess.make_dir_recursive_absolute(mirror)
	fake = FakeStore.new()
	fake.add_project(name)
	restart()


func restart() -> void:
	client = CloudStoreClient.new(fake, "http://store.test", fake.key, device)
	project = CloudProject.new(client, name, mirror, CloudState.open(state_dir))
	project.held_provider = func() -> Array: return held
	project.clock = func() -> int: return 1763000000000


func local(path: String) -> String:
	return mirror.path_join(path)


func write_local(path: String, text: String) -> void:
	CloudFiles.write_bytes_atomic(local(path), text.to_utf8_buffer())


func read_local(path: String) -> String:
	return FileAccess.get_file_as_string(local(path))


func local_exists(path: String) -> bool:
	return FileAccess.file_exists(local(path))


func remove_local(path: String) -> void:
	DirAccess.remove_absolute(local(path))


func put_remote(path: String, text: String, as_device: String = "Desktop") -> int:
	return fake.put_direct(name, path, text.to_utf8_buffer(), as_device)


func remote_text(path: String) -> String:
	return fake.file_bytes(name, path).get_string_from_utf8()


func puts() -> Array:
	return fake.requests_matching("PUT", "/files/")


func commits() -> Array:
	return fake.requests_matching("POST", "/commit")


static func native(root_id: String, extra := "", refs: Array = []) -> String:
	## A small native file: one Part `root_id`, its occurrences placing the files in `refs` ([{ref, id}]), `extra` as a marker in the part's name.
	var occ := []
	for r in refs:
		occ.append({"id": "occ-" + str(r["id"]), "resolved_part_id": str(r["id"]), "external_ref": str(r["ref"]), "ref_part_id": str(r["id"]), "transform": {"translation": [0.0, 0.0, 20.0]}})
	var doc := {"schema_version": 1, "document": {"id": "doc-" + root_id, "root_part_id": root_id, "parts": [{"id": root_id, "name": "Part " + extra, "occurrences": occ}]}, "sketches": []}
	return JSON.stringify(doc)


static func wipe(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	for sub in dir.get_directories():
		wipe(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
