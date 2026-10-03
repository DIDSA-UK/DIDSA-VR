extends SceneTree
## Protecting work and keeping the apps apart (G1-G4 of docs/design-table-gaps.md). Pure: the X-Document-Session header helper
## (backend_session.gd), the OpenAPI check for the Build tree's glb parameters, and a source scan that no script builds its own
## API-key header (so every call carries the session). Scene (main.tscn, no backend): the dirty flag follows edits (undo stack,
## design-table edit, hide, new part, add component) and is cleared by loading and saving; anything that REPLACES the document asks
## first (a warning, then the same action again within a few seconds discards); the Files page says what is unsaved and where saves go.
## Run: "$GODOT" --headless --path . --script res://tests/work_loss.gd  (see tests/README.md)

const BackendSession := preload("res://scripts/backend_session.gd")
const CadApi := preload("res://scripts/design_table/cad_api.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _scripts_under(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_scripts_under(dir.path_join(d), out)


func _initialize() -> void:
	# --- the header helper
	BackendSession.session_id = ""
	var h: Array = BackendSession.headers("KEY")
	var again: Array = BackendSession.headers("KEY", true)
	print("SMOKE every call carries the API key and an X-Document-Session of this app's own ('vr-' and random hex): ", h.size() == 2 and h[0] == "X-API-Key: KEY" and str(h[1]).begins_with("X-Document-Session: vr-") and str(h[1]).length() == len("X-Document-Session: vr-") + 12)
	print("SMOKE ...the same id for the whole launch, with Content-Type added for a JSON body: ", again[1] == h[1] and again.size() == 3 and again[2] == "Content-Type: application/json")
	BackendSession.set_session_id("  shared-bench  ")
	print("SMOKE ...secrets.cfg can fix the id (to keep one document across restarts); an empty value keeps the one in use: ", BackendSession.headers("K")[1] == "X-Document-Session: shared-bench")
	BackendSession.set_session_id("")
	print("SMOKE ...(an empty value changes nothing): ", BackendSession.headers("K")[1] == "X-Document-Session: shared-bench")
	BackendSession.session_id = ""
	var raw_sites: Array = []
	var scripts: Array = []
	_scripts_under("res://scripts", scripts)
	for path in scripts:
		if path.ends_with("backend_session.gd") or path.ends_with("browser_window.gd"): # the browser relay is another service with its own key
			continue
		if FileAccess.get_file_as_string(path).contains("X-API-Key"):
			raw_sites.append(path)
	print("SMOKE no script builds its own API-key header: the one helper is the only source, so no call can leave out the session: ", raw_sites.is_empty(), " ", raw_sites)

	# --- the backend's OpenAPI document says whether Hide / Roll back can work
	var new_spec := {"paths": {"/document/parts/{part_id}/assembly-mesh.glb": {"get": {"parameters": [{"name": "quality"}, {"name": "hidden_feature_ids"}, {"name": "rollback_excluded_feature_ids"}]}}}}
	var old_spec := {"paths": {"/document/parts/{part_id}/assembly-mesh.glb": {"get": {"parameters": [{"name": "quality"}, {"name": "include_hidden"}]}}}}
	var half_spec := {"paths": {"/document/parts/{part_id}/assembly-mesh.glb": {"get": {"parameters": [{"name": "hidden_feature_ids"}]}}}}
	print("SMOKE a backend that lists both glb parameters supports the Build tree's view; one that lists neither, or only one, or has no such route, does not: ", CadApi.view_filters_in(new_spec) and not CadApi.view_filters_in(old_spec) and not CadApi.view_filters_in(half_spec) and not CadApi.view_filters_in({}))

	# --- the dirty flag
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await frames(2)
	var changes: Array = []
	main.dirty_changed.connect(func(d: bool) -> void: changes.append(d))
	print("SMOKE a freshly loaded model has nothing unsaved: ", not main.document_dirty)
	main.command_stack.push("Hide a part", func() -> void: pass, func() -> void: pass)
	main.command_stack.push("Whole-model move", func() -> void: pass, func() -> void: pass)
	print("SMOKE view-only undo entries (hide, moving or scaling the whole model) do not make the document unsaved: ", not main.document_dirty and changes.is_empty())
	main.command_stack.push("move Part", func() -> void: pass, func() -> void: pass, true)
	print("SMOKE moving a part (an entry that persists) marks the document unsaved, once: ", main.document_dirty and changes == [true])
	main.command_stack.push("move Part again", func() -> void: pass, func() -> void: pass, true)
	print("SMOKE ...further edits do not repeat the signal: ", changes == [true])
	main.mark_clean()
	main.command_stack.undo()
	print("SMOKE undoing a persisting entry changes the document again: ", main.document_dirty)
	main.mark_clean()
	main._mates_tool.document_changed.emit()
	print("SMOKE a mate made or deleted, or a part grounded, marks it: ", main.document_dirty)
	main.mark_clean()
	main._colour_tool.document_changed.emit()
	print("SMOKE a colour set marks it: ", main.document_dirty)
	main.mark_clean()
	main.design_table.notify_edited("PART_X", [])
	print("SMOKE a design-table edit marks it: ", main.document_dirty)
	main.mark_clean()
	main.set_feature_hidden("feat_a", true)
	print("SMOKE hiding a feature marks it (the hidden set is written into a save): ", main.document_dirty)
	main.mark_clean()
	main.add_blank_part("ROOT", "occ_new", Transform3D.IDENTITY)
	print("SMOKE a new part marks it: ", main.document_dirty)
	main._show_model(bytes, "", 0.001)
	print("SMOKE loading a model makes the loaded state the baseline (clean again): ", not main.document_dirty and changes.back() == false)

	# --- anything that replaces the document asks first
	var glb_path := "res://tests/fixtures/real_assembly_mesh.glb"
	var parts_before: int = get_nodes_in_group("grabbable_parts").size()
	print("SMOKE with nothing unsaved the confirmation lets a replace straight through: ", main.confirm_discard("Open x.glb"))
	main.mark_dirty()
	print("SMOKE with unsaved changes the first ask refuses and says what to do: ", not main.confirm_discard("Open x.glb") and main.status_text.contains("unsaved changes") and main.status_text.contains("Save first"))
	print("SMOKE ...a DIFFERENT action does not ride on that warning: ", not main.confirm_discard("New assembly"))
	print("SMOKE ...the same action again goes ahead: ", main.confirm_discard("New assembly") and not main.confirm_discard("New assembly"))
	main.load_glb_file(glb_path)
	await frames(2)
	print("SMOKE opening a file with unsaved changes first only warns (the model is untouched): ", main.document_dirty and get_nodes_in_group("grabbable_parts").size() == parts_before and main.status_text.contains("unsaved changes"))
	main.load_glb_file(glb_path)
	await frames(3)
	print("SMOKE ...and the second request within the few seconds loads it, discarding, and the document is clean: ", not main.document_dirty and main.status_text.begins_with("Loaded"))
	main.mark_dirty()
	main._discard_armed_until_ms = Time.get_ticks_msec() - 1
	main._discard_armed_for = "Open x.glb"
	print("SMOKE an old warning that ran out does not count: ", not main.confirm_discard("Open x.glb"))
	main.mark_clean()

	# --- stale-mate flags travel with a save
	var flagged: Node3D = null
	for node in get_nodes_in_group("grabbable_parts"):
		if str(node.get_meta("occurrence_id", "")) != "" and flagged == null:
			flagged = node
	var occ: String = str(flagged.get_meta("occurrence_id"))
	print("SMOKE with no flags a save adds no vr_stale_mates extra: ", not main.native_extras_to_add({}).has("vr_stale_mates") and main.stale_mate_occurrences().is_empty())
	var DirtyMates = load("res://scripts/design_table/dirty_mates.gd")
	DirtyMates.mark(flagged)
	var extras: Dictionary = main.native_extras_to_add({"schema_version": 1})
	print("SMOKE a part flagged 'mates need redoing' is written as vr_stale_mates (its occurrence id): ", extras.get("vr_stale_mates") == [occ])
	print("SMOKE ...as plain JSON text appended to the backend's own file, which the flat app ignores: ", main.append_to_json_object('{"schema_version": 1}', extras).contains('"vr_stale_mates": ["%s"]' % occ))
	DirtyMates.clear(flagged)
	main._native_extras = {"vr_stale_mates": [occ], "hidden_feature_ids": ["f"]}
	print("SMOKE ...a flag the file had but the parts no longer have is not written back (live flags win), other extras still are: ", not main.native_extras_to_add({}).has("vr_stale_mates") and main.native_extras_to_add({}).get("hidden_feature_ids") == ["f"])
	main.restore_stale_mates()
	print("SMOKE opening a file whose extras list that occurrence flags the part again, with its badge: ", DirtyMates.is_dirty(flagged) and flagged.get_node_or_null("DirtyBadge") != null)
	DirtyMates.clear(flagged)
	main._native_extras = {}

	# --- where saves go, and the Files page
	var target := "user://models/test-vr-save.didsa"
	var location: String = main.saved_location_text(target)
	print("SMOKE a save is reported with its real folder, not 'user://': ", location.begins_with("test-vr-save.didsa in ") and not location.contains("user://") and location.contains("models"))
	print("SMOKE ...an absolute path is shown as it is: ", main.saved_location_text("/storage/emulated/0/x/y.didsa") == "y.didsa in /storage/emulated/0/x")
	var tablet = main._tablet
	var pages = tablet.pages
	var label: Label = pages._dirty_label
	print("SMOKE the Files page has a line that says what is unsaved and where saves go: ", label != null and label.text.contains("Saves go to") and label.text.begins_with("Nothing unsaved"))
	main.mark_dirty()
	print("SMOKE ...and it turns to 'Unsaved changes' with the document: ", label != null and label.text.begins_with("Unsaved changes"))
	pages._on_new_assembly_pressed()
	print("SMOKE ...New assembly's armed text then says Unsaved: ", pages._new_assembly_button.text == "Unsaved! Press again to discard")
	pages._disarm_new_assembly()
	main.mark_clean()
	quit()
