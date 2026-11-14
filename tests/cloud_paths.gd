extends SceneTree
## S3: where server projects live and how the headset is told about the store, pure logic with temp folders (no scene, no network):
##  * the mirror folder: Documents/DIDSA-Cloud/<server host>/<project>/ , VISIBLE (no dot-folder) and a SIBLING of Documents/DIDSA, not nested in it; one setting; the fallback to
##    user://DIDSA-Cloud when All files access is off on Android or the folder can't be written, with the reason in words; the private state elsewhere (user://);
##  * the pairing code's p= (store address) and pk= (store key) (NOT s / sk), unknown keys still ignored, a refused store address refusing the code;
##  * servers.cfg and the settings file carrying the store address / key, the device name and the mirror folder;
##  * a file project_save.gd writes in the mirror is a queued save, and the mirror reads like any folder to file_index.gd (dot-folders skipped) and does not show in the local Files list.
## NOT covered: a real Android permission prompt or Documents folder (headless cannot judge either).
## Run: "$GODOT" --headless --path . --script res://tests/cloud_paths.gd  (see tests/README.md)

const CloudPaths := preload("res://scripts/cloud/cloud_paths.gd")
const CloudManager := preload("res://scripts/cloud/cloud_manager.gd")
const CloudState := preload("res://scripts/cloud/cloud_state.gd")
const Payload := preload("res://scripts/landing/pairing_payload.gd")
const ServerStore := preload("res://scripts/landing/server_store.gd")
const AppSettings := preload("res://scripts/app_settings.gd")
const ProjectFolder := preload("res://scripts/project_folder.gd")
const ProjectSave := preload("res://scripts/project_save.gd")
const FileIndex := preload("res://scripts/file_index.gd")
const Rig := preload("res://tests/cloud_rig.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _initialize() -> void:
	OS.set_environment("DIDSA_SERVERS_PATH", "user://cloud_servers_test.cfg")
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://cloud_settings_test.cfg")
	_folders()
	_pairing()
	_servers_and_settings()
	await _mirror_reads_like_a_folder()
	quit(0)


func _folders() -> void:
	var docs := "/storage/emulated/0/Documents"
	_check(CloudPaths.default_root(docs) == docs + "/DIDSA-Cloud" and ProjectFolder.default_folder(docs) == docs + "/DIDSA", "the default root is Documents/DIDSA-Cloud, beside Documents/DIDSA")
	_check(not CloudPaths.default_root(docs).begins_with(ProjectFolder.default_folder(docs) + "/") and not CloudPaths.DIR_NAME.begins_with("."), "...not nested in the local project folder and not a dot-folder (the moved-files index skips dot-folders; the local Files list would show a nested one)")
	_check(CloudPaths.mirror_dir(docs + "/DIDSA-Cloud", "https://store.example.com", "Gearbox") == docs + "/DIDSA-Cloud/store.example.com/Gearbox", "a mirror is <root>/<server host>/<project>")
	_check(CloudPaths.host_folder("http://192.168.1.5:8200") == "192.168.1.5_8200" and CloudPaths.host_folder("https://Store.Example.com:443/") == "Store.Example.com" and CloudPaths.host_folder("https://u:p@host.net/x") == "host.net" and CloudPaths.host_folder("") == "server", "the host folder keeps a port other than 80 / 443 (no colon in a file name), drops a login and a path")
	_check(CloudPaths.safe_segment(".hidden/..") == "hidden_.." .rstrip(".") and not CloudPaths.safe_segment("a:b*c").contains(":") and CloudPaths.safe_segment("Gearbox ") == "Gearbox", "a project name can't make a dot-folder or escape the mirror root")
	_check(CloudPaths.state_dir("https://s.net", "Gearbox").begins_with("user://") and CloudPaths.state_dir("https://s.net", "Gearbox") != CloudPaths.state_dir("https://s.net", "Other") and CloudPaths.state_dir("https://s.net", "Gearbox") == CloudPaths.state_dir("https://S.net/", "Gearbox"), "the sync state is in PRIVATE storage (user://), one folder per store and project")
	# the root: the one setting, and its fallback
	var tmp := ProjectSettings.globalize_path("user://cloud_test/paths_docs")
	Rig.wipe(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	var ok := CloudPaths.resolve_root("", false, false, tmp)
	_check(ok["path"] == tmp + "/DIDSA-Cloud" and not ok["fallback"] and DirAccess.dir_exists_absolute(tmp + "/DIDSA-Cloud"), "with Documents usable the mirrors live in Documents/DIDSA-Cloud")
	var moved := CloudPaths.resolve_root(tmp + "/elsewhere", false, false, tmp)
	_check(moved["path"] == tmp + "/elsewhere" and not moved["fallback"], "...and the root is one setting: another folder moves it")
	var no_permission := CloudPaths.resolve_root("", true, false, "/storage/emulated/0/Documents")
	_check(no_permission["path"] == "user://DIDSA-Cloud" and no_permission["fallback"] and no_permission["note"].contains("All files access"), "on Android without All files access the mirror falls back to user://DIDSA-Cloud and the note says why")
	var with_permission := CloudPaths.resolve_root("", true, true, tmp)
	_check(with_permission["path"] == tmp + "/DIDSA-Cloud" and not with_permission["fallback"], "...with it, Documents is used")
	var unwritable := CloudPaths.resolve_root("/proc/cannot-make-this", false, false, tmp)
	_check(unwritable["path"] == "user://DIDSA-Cloud" and unwritable["fallback"] and unwritable["note"].contains("can't"), "a folder that can't be made or written falls back too, with the reason")
	_check(CloudPaths.resolve_root("", false, false, "")["path"] == "user://DIDSA-Cloud", "no Documents folder at all: the fallback")
	_check(CloudPaths.relative("/a/b", "/a/b/c/d.didsa") == "c/d.didsa" and CloudPaths.relative("/a/b", "/a/bc/d") == "" and CloudPaths.relative("/a/b", "/x/y") == "", "a path is made relative to its mirror, or reported outside it")


func _pairing() -> void:
	var code := Payload.build("Workshop", "https://cad.example.net", "cad-key", "https://store.example.net", "store key&1")
	_check(code.contains("&p=https%3A%2F%2Fstore.example.net&pk=store+key%261") and not code.contains("&s=") and not code.contains("&sk="), "the code carries p= and pk= (not s / sk: s is the document session)")
	var parsed := Payload.parse(code)
	_check(parsed["ok"] and parsed["store_url"] == "https://store.example.net" and parsed["store_api_key"] == "store key&1" and parsed["url"] == "https://cad.example.net" and parsed["api_key"] == "cad-key", "...and parses back: the store address and key beside the backend's")
	_check(parsed["document_session"] == "" and parsed["relay_url"] == "", "...without disturbing the document session or the relay keys")
	var both := Payload.parse("didsa-vr:1?n=X&u=https%3A%2F%2Fa.example.net&k=k&s=sess&r=wss%3A%2F%2Frelay.example.net&rk=rk&p=https%3A%2F%2Fp.example.net&pk=pk")
	_check(both["ok"] and both["document_session"] == "sess" and both["relay_url"] == "wss://relay.example.net" and both["store_url"] == "https://p.example.net" and both["store_api_key"] == "pk", "s, r, rk, p and pk together each land where they belong")
	var old := Payload.parse("didsa-vr:1?n=Old&u=https%3A%2F%2Fa.example.net&k=k")
	_check(old["ok"] and old["store_url"] == "" and old["store_api_key"] == "", "a code from an older DIDSA-CAD (no p / pk) still pairs, with no store")
	var future := Payload.parse("didsa-vr:1?n=X&u=https%3A%2F%2Fa.example.net&k=k&zz=1&sk=nope")
	_check(future["ok"] and future["store_url"] == "", "unknown keys (sk, a future one) are still ignored")
	var lan := Payload.parse("didsa-vr:1?n=X&u=https%3A%2F%2Fa.example.net&k=k&p=http%3A%2F%2F192.168.1.9%3A8200&pk=pk")
	_check(lan["ok"] and lan["store_url"] == "http://192.168.1.9:8200", "a store on the local network may be plain http, like a server")
	var refused := Payload.parse("didsa-vr:1?n=X&u=https%3A%2F%2Fa.example.net&k=k&p=http%3A%2F%2Fstore.example.com&pk=pk")
	_check(not refused["ok"] and refused["error"].contains("project store address") and refused["store_url"] == "", "a store address the headset refuses (plain http to the internet) refuses the whole code")
	var no_key := Payload.parse("didsa-vr:1?n=X&u=https%3A%2F%2Fa.example.net&k=k&p=https%3A%2F%2Fstore.example.net")
	_check(no_key["ok"] and no_key["store_url"] == "https://store.example.net" and no_key["store_api_key"] == "", "a store address with no key is kept as it is (the card says there is no key)")


func _servers_and_settings() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://cloud_servers_test.cfg"))
	var store := ServerStore.new()
	var entry := store.add({"name": "Workshop", "url": "https://cad.example.net", "api_key": "k", "store_url": "https://store.example.net/", "store_key": "sk"}, true)
	_check(entry["store_url"] == "https://store.example.net" and entry["store_key"] == "sk", "a saved server carries the store's address (trailing slash dropped) and its own key")
	var again := ServerStore.new()
	again.load_from_disk()
	_check(again.current()["store_url"] == "https://store.example.net" and again.current()["store_key"] == "sk", "...kept in servers.cfg across a restart")
	again.set_store(str(entry["id"]), "https://other.example.net", "k2")
	var third := ServerStore.new()
	third.load_from_disk()
	_check(third.current()["store_url"] == "https://other.example.net" and third.current()["store_key"] == "k2", "set_store changes it")
	third.set_store(str(entry["id"]), "", "")
	_check(third.find(str(entry["id"]))["store_url"] == "" and third.find(str(entry["id"]))["store_key"] == "", "...and clears it")
	var scanned := store.add({"name": "Workshop", "url": "https://cad.example.net", "api_key": "k"}, true)
	_check(str(scanned["store_url"]) == "https://store.example.net", "adding the same server again from a code with no store does not wipe the store it has")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://cloud_settings_test.cfg"))
	var settings := AppSettings.new()
	_check(settings.cloud_folder == "" and settings.device_name == "", "by default the mirror folder is the default root and the device name the platform's")
	settings.set_cloud_folder("  /somewhere/else  ")
	settings.set_device_name("Quest 3 in the workshop")
	var loaded := AppSettings.new()
	loaded.load_from_disk()
	_check(loaded.cloud_folder == "/somewhere/else" and loaded.device_name == "Quest 3 in the workshop", "the mirror folder and the device name are settings that survive a restart")
	var manager := CloudManager.new()
	manager.settings = loaded
	_check(manager.device_name() == "Quest 3 in the workshop", "a named device sends its name")
	manager.settings = AppSettings.new()
	_check(manager.device_name() != "" and manager.device_name() == CloudManager.default_device_name() and manager.device_name().length() <= 40, "an unnamed one sends the platform's name (%s), never anything about a person" % manager.device_name())
	manager.free()


func _mirror_reads_like_a_folder() -> void:
	var r := Rig.new("paths_mirror")
	# project_save.gd writes in the mirror as to any folder; the sync sees that as a queued save
	var text := Rig.native("p-saved", "by project_save")
	var failure := ProjectSave.write_atomic(r.local("Saved.didsa"), text)
	_check(failure == "" and r.local_exists("Saved.didsa") and not r.local_exists("Saved.didsa.saving"), "project_save.gd writes a file into the mirror like into any folder")
	var scanned: Dictionary = r.project.scan()
	_check(scanned["new"] == ["Saved.didsa"] and r.project.state.queue["Saved.didsa"]["base"] == null, "...and the next scan queues it as a new file")
	await r.project.sync()
	_check(r.fake.has_file(r.name, "Saved.didsa") and r.remote_text("Saved.didsa") == text, "...which then goes to the store")
	# the private state is not in the visible folder
	_check(not r.state_dir.begins_with(r.mirror) and FileAccess.file_exists(r.state_dir + "/state.json") and not r.local_exists("state.json"), "the sync state is private storage, outside the mirror: nothing about the queue is in the visible folder")
	# deleting the whole mirror cannot delete the queue
	r.write_local("Unsent.didsa", Rig.native("p-unsent", "offline"))
	r.fake.offline = true
	await r.project.sync()
	Rig.wipe(r.mirror)
	r.restart()
	_check(r.project.state.queue.has("Unsent.didsa") and r.project.summary()["missing"] == [] and (r.project.scan() as Dictionary).has("new") and r.project.summary()["missing"] == ["Unsent.didsa"], "deleting the whole mirror does not delete the queue: it warns that the save is unsent and its file is gone")
	# the mirror read as a folder by the moved-files index: native files, subfolders, dot-folders skipped
	var s := Rig.new("paths_index")
	s.write_local("A.didsa", Rig.native("p-a", ""))
	s.write_local("sub/B.didsa", Rig.native("p-b", ""))
	s.write_local(".trash/C.didsa", Rig.native("p-c", ""))
	var index: Array = FileIndex.build([s.mirror])
	var found := {}
	for e in index:
		found[e["path"]] = e["part_id"]
	_check(found == {"A.didsa": "p-a", "sub/B.didsa": "p-b"}, "file_index.gd reads the mirror unchanged: native files at any depth with their Part ids, a dot-folder skipped")
	var docs := ProjectSettings.globalize_path("user://cloud_test/local_docs")
	Rig.wipe(docs)
	DirAccess.make_dir_recursive_absolute(docs + "/DIDSA")
	DirAccess.make_dir_recursive_absolute(docs + "/DIDSA-Cloud/store.example.com/Gearbox")
	var f := FileAccess.open(docs + "/DIDSA-Cloud/store.example.com/Gearbox/X.didsa", FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	_check(ProjectFolder.model_files(ProjectFolder.default_folder(docs)).is_empty() and ProjectFolder.subfolders(ProjectFolder.default_folder(docs)).is_empty(), "the local project folder (Documents/DIDSA) does not list the mirror: it is a sibling, not nested")
