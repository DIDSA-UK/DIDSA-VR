extends SceneTree
## Unsaved changes and the landing (docs/quest-first-run-fixes.md B4, Quest 3 report): a handled demo model never asks before it is replaced (it is
## read-only, and offline there is nowhere to save it); with real unsaved work the Discard / Save first / Cancel choice is shown on the monolith (not
## only on the wrist tablet), Cancel keeps the work and goes back to the page you were on, and Discard loads the demo AND places it as asked
## (full size ahead), not just loads it. Full scene (main.tscn, no backend).
## Run: "$GODOT" --headless --path . --script res://tests/landing_unsaved.gd

const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const SETTINGS := "user://settings_landing_unsaved_test.cfg"
const RECENT := "user://recent_landing_unsaved_test.cfg"
const MY_FILE := "user://landing_unsaved_test_model.glb"
const LISTED_GLB := "user://models/landing_open_test.glb"
const LISTED_NATIVE := "user://models/landing_open_test.didsa"

var main


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_RECENT_PATH", RECENT)
	for path in [SETTINGS, RECENT, MY_FILE]:
		DirAccess.remove_absolute(path)
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await frames(1)
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)
	var landing = main.landing
	var launcher = landing.launcher
	var crafts: Array[Dictionary] = DemoCatalog.models("spacecraft")
	var first: Dictionary = crafts[0]
	var second: Dictionary = crafts[1]

	# --- a handled demo is replaced without asking ----------------------------------------------------------------------------------
	await landing.show_demo(first, false)
	await frames(2)
	check("a demo loaded from the landing is marked as a demo", main.document_is_demo)
	main.mark_dirty() # what a grab-move does (command_stack.changed)
	main.go_home()
	await frames(2)
	await landing.show_demo(second, false)
	await frames(2)
	check("moving a demo then picking another demo loads it without asking (nothing waits, the landing is left)", main.pending_discard() == "" and not landing.is_active() and recent_last() == second["path"])

	# --- real work: the choice is on the monolith ------------------------------------------------------------------------------------
	DirAccess.copy_absolute(ProjectSettings.globalize_path(str(first["path"])), ProjectSettings.globalize_path(MY_FILE))
	check("a file of your own is not a demo", main.load_glb_file(MY_FILE) and not main.document_is_demo)
	main.mark_dirty()
	main.go_home()
	await frames(2)
	launcher.show_page("models")
	await frames(1)
	await landing.show_demo(second, false)
	await frames(2)
	check("with unsaved work a demo waits, and the monolith shows the choice", main.pending_discard() != "" and launcher.page == "discard" and launcher._body.find_child("DiscardContinue", true, false) != null)
	check("...the wrist tablet is not opened for it, and the status line points at the monolith", not main._tablet.is_open() and "on the monolith" in main.status_text)
	var save: Button = launcher._body.find_child("DiscardSave", true, false)
	check("...Save first is offered but needs a server (offline here)", save != null and save.disabled)
	(launcher._body.find_child("DiscardCancel", true, false) as Button).pressed.emit()
	await frames(2)
	check("Cancel keeps the work (still your file, still unsaved) and goes back to the Demo models page", main.pending_discard() == "" and main.document_dirty and not main.document_is_demo and launcher.page == "models" and landing.is_active())

	await landing.show_demo(second, false)
	await frames(2)
	(launcher._body.find_child("DiscardContinue", true, false) as Button).pressed.emit()
	for i in 10:
		await process_frame
	check("Discard loads the demo and leaves the landing", main.document_is_demo and not main.document_dirty and not landing.is_active() and recent_last() == second["path"])
	check("...and places it as asked: full size, on the floor ahead (not where a plain load would put it)", main.assembly_root.scale.is_equal_approx(Vector3.ONE) and main.assembly_root.global_position.z < -2.0 and absf(main.assembly_root.global_position.y - main.get_node("XROrigin3D").global_position.y) < 0.01)

	# --- Open... stays on the monolith (Quest 3 report: it threw you onto the wrist tablet) -----------------------------------------------
	DirAccess.make_dir_recursive_absolute("user://models")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(str(first["path"])), ProjectSettings.globalize_path(LISTED_GLB))
	var native := FileAccess.open(LISTED_NATIVE, FileAccess.WRITE)
	native.store_string("{}")
	native.close()
	main.go_home()
	await frames(2)
	launcher.press_tile("open")
	await frames(2)
	check("Open shows a file list on the monolith and leaves the wrist tablet shut", launcher.page == "open" and not main._tablet.is_open())
	var glb_row: Node = launcher._body.find_child("File_" + LISTED_GLB.get_file().validate_node_name(), true, false)
	var native_row: Node = launcher._body.find_child("File_" + LISTED_NATIVE.get_file().validate_node_name(), true, false)
	check("...listing the models folder's files, the last opened one first", glb_row != null and native_row != null and "Recent" in _all_text(launcher._body.get_child(1)))
	check("...a .didsa offline says it needs a server instead of failing", (native_row.find_child("Open", true, false) as Button).disabled and (native_row.find_child("Open", true, false) as Button).text == "Needs a server")
	check("...and the tablet is one press away for saving and references", launcher._body.find_child("OpenOnTablet", true, false) != null)
	main.mark_clean()
	(glb_row.find_child("Open", true, false) as Button).pressed.emit()
	await frames(4)
	check("pressing Open loads that file and leaves the landing", not landing.is_active() and recent_last() == LISTED_GLB and not main.document_is_demo)

	main.queue_free()
	await frames(2)
	for path in [LISTED_GLB, LISTED_NATIVE]:
		DirAccess.remove_absolute(path)
	for path in [SETTINGS, RECENT, MY_FILE]:
		DirAccess.remove_absolute(path)
	print("SMOKE PASSED")
	quit()


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in node.get_children():
		out += _all_text(child)
	return out


func recent_last() -> String:
	return str(preload("res://scripts/landing/recent_file.gd").last().get("path", ""))
