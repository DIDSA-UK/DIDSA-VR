extends SceneTree
## S3: scripts/cloud/cloud_manager.gd, what main.gd and the screens use: the store's address and key, the mirror root as one setting, listing the store's projects (and the
## ones saved here when it can't be reached), opening a project (a sync, then the active project's timer), opening a file (what it places downloaded), which project a path
## belongs to, what is waiting to sync (from the saved state, no network), the timer's sync, the words for a report, and the session's files never being refreshed under it.
## Headless against tests/fake_project_store.gd. NOT covered: the real HTTP transport (tests/e2e_cloud_store.gd), the screens (tests/cloud_ui.gd).
## Run: "$GODOT" --headless --path . --script res://tests/cloud_manager.gd  (see tests/README.md)

const Rig := preload("res://tests/cloud_rig.gd")
const FakeStore := preload("res://tests/fake_project_store.gd")
const CloudManager := preload("res://scripts/cloud/cloud_manager.gd")
const AppSettings := preload("res://scripts/app_settings.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://cloud_settings_test2.cfg")
	var base := ProjectSettings.globalize_path("user://cloud_test/manager")
	Rig.wipe(base)
	var fake := FakeStore.new()
	fake.add_project("Gearbox")
	fake.add_project("Frames")
	fake.put_direct("Gearbox", "Asm.didsa", Rig.native("p-asm", "", [{"ref": "Shaft.didsa", "id": "p-shaft"}]), "Desktop")
	fake.put_direct("Gearbox", "Shaft.didsa", Rig.native("p-shaft", "v1"), "Desktop")
	var settings := AppSettings.new()
	settings.cloud_folder = base + "/DIDSA-Cloud"
	settings.device_name = "Quest 3"
	var held := []
	var m := CloudManager.new()
	m.settings = settings
	m.transport = fake
	m.state_root = base + "/state"
	m.held_provider = func() -> Array: return held
	root.add_child(m)
	await process_frame
	_check(not m.is_configured() and m.waiting_text() == "" and m.waiting()["projects"].is_empty(), "with no store set the manager says so and nothing is waiting")
	var none: Dictionary = await m.refresh_projects()
	_check(not none["ok"] and none["error"].contains("No project store"), "listing projects with no store set says there is no store")
	m.configure("http://store.test/", fake.key)
	_check(m.is_configured() and m.store_url == "http://store.test", "the store address is kept without its trailing slash")
	_check(m.root_info()["path"] == base + "/DIDSA-Cloud" and not m.root_info()["fallback"] and m.mirror_path("Gearbox") == base + "/DIDSA-Cloud/store.test/Gearbox", "the mirror root is the one setting; a project's mirror is <root>/<host>/<project>")
	var listed: Dictionary = await m.refresh_projects()
	_check(listed["ok"] and m.all_project_names() == ["Frames", "Gearbox"], "the store's projects are listed")
	# open a project
	var report: Dictionary = await m.open_project("Gearbox")
	_check(m.active != null and m.active.project == "Gearbox" and report["reachable"] and report["text"].begins_with("Synced"), "opening a project makes it active and syncs it (%s)" % report["text"])
	_check(not m._timer.is_stopped() and m._timer.wait_time == 20.0, "...a 20 s timer syncs it while it is open")
	_check(fake.requests.any(func(q: Dictionary) -> bool: return q["device"] == "Quest 3"), "...and the device name is sent")
	# open a file: it and what it places
	var opened: Dictionary = await m.open_file("Gearbox", "Asm.didsa")
	_check(opened["ok"] and opened["full_path"] == base + "/DIDSA-Cloud/store.test/Gearbox/Asm.didsa" and FileAccess.file_exists(opened["full_path"]) and FileAccess.file_exists(base + "/DIDSA-Cloud/store.test/Gearbox/Shaft.didsa"), "opening a file downloads it and the file it places into the mirror")
	# which project does a path belong to
	_check(m.project_for_path(opened["full_path"]) == m.project("Gearbox") and m.project_for_path("/somewhere/else/File.didsa") == null and m.project_for_path("") == null, "a path inside a mirror belongs to its project; any other path to none")
	m.deactivate()
	_check(m.active == null and m._timer.is_stopped(), "no project active stops the timer")
	m.note_path(opened["full_path"])
	_check(m.active == m.project("Gearbox") and not m._timer.is_stopped(), "opening a file of a mirror makes its project the active one")
	m.note_path("/not/in/a/mirror.didsa")
	_check(m.active == null, "opening any other file ends it")
	m.note_path(opened["full_path"])
	# the timer's sync sends what was saved in the mirror
	var gearbox = m.project("Gearbox")
	var f := FileAccess.open(gearbox.abs_path("Shaft.didsa"), FileAccess.WRITE)
	f.store_string(Rig.native("p-shaft", "edited in VR"))
	f.close()
	await m._on_timer()
	_check(fake.file_bytes("Gearbox", "Shaft.didsa").get_string_from_utf8() == Rig.native("p-shaft", "edited in VR") and fake.version_of("Gearbox", "Shaft.didsa") == 2, "the timer's sync sends a save written into the mirror")
	# held files: the session's files are not refreshed under it
	held.append(gearbox.abs_path("Shaft.didsa")) # (a lambda captures the array, so it is changed in place)
	fake.put_direct("Gearbox", "Shaft.didsa", Rig.native("p-shaft", "from the desktop"), "Desktop")
	await m.sync_active()
	_check(FileAccess.get_file_as_string(gearbox.abs_path("Shaft.didsa")) == Rig.native("p-shaft", "edited in VR") and gearbox.state.behind.has("Shaft.didsa"), "a file the open session holds (main.gd's absolute path, made relative) is not refreshed under it")
	held.clear()
	# offline: the queue and the landing's line
	fake.offline = true
	f = FileAccess.open(gearbox.abs_path("Asm.didsa"), FileAccess.WRITE)
	f.store_string(Rig.native("p-asm", "offline edit"))
	f.close()
	report = await m.sync_active()
	_check(not report["reachable"] and report["text"].contains("can't be reached") and report["text"].contains("1 save kept"), "offline: '%s'" % report["text"])
	_check(m.waiting_text() == "1 save waiting to sync" and m.waiting()["to_send"] == 1 and m.waiting()["projects"][0]["name"] == "Gearbox", "the landing's line says what is waiting, from the saved state")
	var relisted: Dictionary = await m.refresh_projects()
	_check(not relisted["ok"] and relisted["error"].contains("saved on this headset") and m.all_project_names().has("Gearbox"), "the store can't be reached: the projects saved on this headset stay listed, with the reason")
	fake.offline = false
	report = await m.sync_active()
	_check(report["sent"] == ["Asm.didsa"] and m.waiting_text() == "", "back online the save goes and nothing is waiting")
	# a clash is counted and worded
	var asm = gearbox
	f = FileAccess.open(asm.abs_path("Asm.didsa"), FileAccess.WRITE)
	f.store_string(Rig.native("p-asm", "mine again"))
	f.close()
	fake.put_direct("Gearbox", "Asm.didsa", Rig.native("p-asm", "theirs"), "Phone")
	report = await m.sync_active()
	_check(report["text"].begins_with("1 file changed on the server") and m.waiting_text() == "1 clash to settle", "a clash is worded and counted: '%s' / '%s'" % [report["text"], m.waiting_text()])
	# the words
	_check(CloudManager.report_text({"busy": true}) == "Syncing..." and CloudManager.report_text({"reachable": true, "sent": [], "refreshed": [], "conflicts": [], "error": "", "warnings": []}) == "Synced: up to date." and CloudManager.report_text({"reachable": true, "sent": ["a", "b"], "refreshed": ["c"], "conflicts": [], "error": "", "warnings": []}) == "Synced: sent 2 files, updated 1 from the server." and CloudManager.report_text({"reachable": true, "error": "The project store refused the key (401). Check the store key under Servers.", "conflicts": []}).contains("401"), "the status words: syncing / up to date / sent and updated / an error as the store said it")
	# a key that is refused is named
	m.configure("http://store.test", "wrong")
	m.project("Gearbox").client.api_key = "wrong"
	var refused: Dictionary = await m.refresh_projects()
	_check(not refused["ok"] and refused["error"].contains("refused the key"), "a wrong key is named")
	# create a project
	m.configure("http://store.test", fake.key)
	var made: Dictionary = await m.create_project("Fresh")
	_check(made["ok"] and fake.projects.has("Fresh") and m.all_project_names().has("Fresh"), "a new project can be made on the store")
	var again: Dictionary = await m.create_project("Fresh")
	_check(not again["ok"] and again["error"].contains("already exists"), "...and a name that is taken says so")
	# another store drops the open projects but not their saved state
	m.configure("http://other.test", "k")
	_check(m.active == null and m.all_project_names().is_empty(), "a different store drops the open projects (its list is its own)")
	m.configure("http://store.test", fake.key)
	_check(m.known_projects().has("Gearbox"), "...and the first store's saved projects are still known when it is back")
	quit(0)
