extends SceneTree
## T1 (docs/test-report-30-oct-plan.md): the project folder. scripts/project_folder.gd (default, probe on a good / unmakeable / read-only folder, listing,
## New folder, the short names), the "asked" flag in app_settings.gd (an empty folder is not "not asked"), main.gd's use / keep / save_dir and that
## snapshot_path() follows them, the folder chooser and the landing's first-run page, and the Android preset's All files access line (tests/android_config.gd).
## NOT checked: what Horizon OS lets the app see, that Documents/DIDSA is visible in the Files app, the permission page.
## Run: "$GODOT" --headless --path . --script res://tests/project_folder.gd

const ProjectFolder := preload("res://scripts/project_folder.gd")
const AppSettings := preload("res://scripts/app_settings.gd")
const FolderChooser := preload("res://scripts/ui/folder_chooser.gd")
const SETTINGS := "user://settings_project_folder_test.cfg"
const RECENT := "user://recent_project_folder_test.cfg"
const TMP := "user://project_folder_test"


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_RECENT_PATH", RECENT)
	for path in [SETTINGS, RECENT]:
		DirAccess.remove_absolute(path)
	_wipe(TMP)
	DirAccess.make_dir_recursive_absolute(TMP)

	# --- default and short names ---
	check("default folder is Documents/DIDSA under a given Documents", ProjectFolder.default_folder("/home/u/Documents") == "/home/u/Documents/DIDSA")
	check("...and user://models when there is no Documents folder", ProjectFolder.default_folder("") == "user://models")
	check("short name of a Documents folder", ProjectFolder.short_name(ProjectFolder.documents_dir().path_join("DIDSA")) == "Documents/DIDSA" or ProjectFolder.documents_dir().is_empty())
	check("short name of the empty path is app storage", ProjectFolder.short_name("") == "app storage")
	check("parent_of", ProjectFolder.parent_of("/a/b/c") == "/a/b" and ProjectFolder.parent_of("/a") == "/" and ProjectFolder.parent_of("/") == "")

	# --- probe ---
	var good := TMP + "/good"
	var made := ProjectFolder.probe(good) # missing: made for the user
	check("probe makes a missing folder and reports it usable", made["exists"] and made["readable"] and made["writable"] and made["error"] == "")
	check("probe leaves no temp file behind", DirAccess.open(good).get_files().size() == 0)
	var blocked := ProjectFolder.probe("/proc/didsa_no_such_folder/x")
	check("probe of a folder that can't be made: not exists, with a reason", not blocked["exists"] and not blocked["writable"] and str(blocked["error"]) != "")
	check("probe of an empty path is refused", str(ProjectFolder.probe("")["error"]) != "")
	var as_file := TMP + "/a_file"
	FileAccess.open(as_file, FileAccess.WRITE).store_string("x")
	check("probe of a path that is a file is refused", not ProjectFolder.usable(as_file))
	var ro := ProjectFolder.full_path(TMP) + "/readonly"
	DirAccess.make_dir_recursive_absolute(ro)
	var uid_out: Array = []
	OS.execute("id", ["-u"], uid_out)
	if str(uid_out[0] if uid_out.size() > 0 else "").strip_edges() == "0":
		check("read-only folder refused: not testable as root (root writes anywhere); the mode is checked on a normal user's run", true)
	else:
		OS.execute("chmod", ["555", ro])
		var r := ProjectFolder.probe(ro)
		check("probe of a read-only folder: readable, not writable, with a reason", r["readable"] and not r["writable"] and str(r["error"]) != "")
		OS.execute("chmod", ["755", ro])

	# --- listing and New folder ---
	FileAccess.open(good + "/a.didsa", FileAccess.WRITE).store_string("{}")
	FileAccess.open(good + "/b.txt", FileAccess.WRITE).store_string("x")
	DirAccess.make_dir_recursive_absolute(good + "/sub")
	DirAccess.make_dir_recursive_absolute(good + "/.hidden")
	check("subfolders lists folders, sorted, hidden ones left out", ProjectFolder.subfolders(good) == PackedStringArray(["sub"]))
	check("model_files counts model files by extension only", ProjectFolder.model_files(good) == PackedStringArray(["a.didsa"]))
	var nf := ProjectFolder.make_subfolder(good, " ../New one ")
	check("make_subfolder cleans the name and makes the folder", nf["ok"] and nf["path"].ends_with("/New one") and DirAccess.dir_exists_absolute(nf["path"]))
	check("make_subfolder refuses an empty name", not ProjectFolder.make_subfolder(good, "  ")["ok"])
	check("status_line gives the real path, writable and the file count", "can be written" in ProjectFolder.status_line(good) and "1 model file" in ProjectFolder.status_line(good) and not "user://" in ProjectFolder.status_line(good))
	check("start_dir keeps an existing current folder", ProjectFolder.start_dir(good) == good)

	# --- the asked flag ---
	var fresh = AppSettings.new()
	fresh.load_from_disk()
	check("a fresh settings file has not been asked", fresh.folder_asked == false and fresh.project_folder == "")
	fresh.set_project_folder("")
	var reloaded = AppSettings.new()
	reloaded.load_from_disk()
	check("choosing app storage (an empty folder) counts as asked, and is remembered", reloaded.folder_asked == true and reloaded.project_folder == "")
	DirAccess.remove_absolute(SETTINGS)
	var legacy := ConfigFile.new() # a settings file from before the flag, with a folder already chosen
	legacy.set_value("files", "project_folder", good)
	legacy.save(ProjectSettings.globalize_path(SETTINGS))
	var old = AppSettings.new()
	old.load_from_disk()
	check("an older settings file that already has a folder counts as asked", old.folder_asked == true and old.project_folder == good)
	DirAccess.remove_absolute(SETTINGS)

	# --- main.gd: use / keep / save_dir / snapshot_path ---
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await frames(2)
	check("a new install needs asking", main.folder_needs_asking())
	check("with no folder, saves go to the app's own user://models", main.save_dir() == "user://models" and main.snapshot_path().begins_with("user://models/"))
	var refused: Dictionary = main.use_project_folder("/proc/didsa_no_such_folder/x")
	check("use_project_folder refuses a folder it can't use and changes nothing", not refused["ok"] and main.project_folder() == "" and main.folder_needs_asking())
	var used: Dictionary = main.use_project_folder(good)
	check("use_project_folder accepts a usable folder; saves go there; it is no longer asked", used["ok"] and main.project_folder() == good and not main.folder_needs_asking() and main.snapshot_path().begins_with(good + "/"))
	check("the Files header names the folder", main.folder_label().begins_with("Project folder: ") and not main.folder_label().ends_with("app storage"))
	main.keep_in_app_storage()
	check("keep_in_app_storage: no folder, saves to user://models, still not asked again", main.project_folder() == "" and main.save_dir() == "user://models" and not main.folder_needs_asking())
	check("the Files header then says app storage", main.folder_label() == "Project folder: app storage")
	check("All files access says it is not needed off Android", "not needed" in main.all_files_access_text())

	# --- the folder chooser ---
	var chooser = FolderChooser.new()
	root.add_child(chooser)
	chooser.setup(main, good)
	await frames(1)
	check("the chooser lists the folders inside the one it opens at", chooser.find_child("Folder_sub", true, false) != null and chooser.find_child("Folder_New one", true, false) != null)
	var picked := []
	chooser.chosen.connect(func(p: String) -> void: picked.append(p))
	chooser._enter("sub")
	await frames(1)
	check("going into a folder shows it", chooser.current == good + "/sub" and chooser.find_child("Up", true, false) != null)
	chooser._go_up()
	check("Up goes back", chooser.current == good)
	chooser._use_current()
	check("Use this folder probes, sets the project folder and says so", picked == [good] and main.project_folder() == good)
	main.keep_in_app_storage()
	chooser.current = "/proc/didsa_no_such_folder/x"
	chooser._use_current()
	await frames(1)
	check("a folder that can't be written is refused in the chooser with a message, and not chosen", picked.size() == 1 and str(chooser.find_child("Message", true, false).text).begins_with("Can't use"))

	# --- the landing's first-run page ---
	var launcher = main.landing.launcher
	check("the landing is on", main.landing.is_active())
	main._settings.folder_asked = false
	launcher.close()
	launcher.open()
	await frames(3)
	check("a first run opens the launcher on the folder page", launcher.page == "folder" and launcher.find_child("FolderUse", true, false) != null and launcher.find_child("FolderChoose", true, false) != null and launcher.find_child("FolderKeep", true, false) != null)
	launcher.find_child("FolderKeep", true, false).pressed.emit()
	await frames(3)
	check("Keep in app storage answers it and goes home", not main.folder_needs_asking() and launcher.page == "home")
	launcher.close()
	launcher.open()
	await frames(3)
	check("once answered the launcher opens on home", launcher.page == "home")
	launcher.show_page("folder")
	await frames(2)
	launcher.find_child("FolderChoose", true, false).pressed.emit()
	await frames(2)
	check("Choose another... shows the chooser", launcher.find_child("FolderChooser", true, false) != null)

	_wipe(TMP)
	for path in [SETTINGS, RECENT]:
		DirAccess.remove_absolute(path)
	quit()


func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_wipe(path.path_join(sub))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
