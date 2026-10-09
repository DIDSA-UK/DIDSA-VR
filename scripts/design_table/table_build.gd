extends RefCounted
## The design table's BUILD tree: what the window's Build tab shows and does (table_tree_window.gd is only the view). It is the
## ordered feature list of the PART ON THE TABLE (the flat app's part design lens: planes, sketches, extrudes, fillets...), read
## from the backend whenever the part changes, plus what you can do to a row:
##   select      lights up what the feature made on the table's copy (no backend write);
##   Edit        changes an extrude's depth / a fillet's radius / a chamfer's distance (a PATCH, any feature, not just the last),
##               typed on the numeric pad, and can be taken back with the table's Undo;
##   Delete      the feature AND everything built on it (the backend's cascade, which also removes the sketches they owned), after
##               a second press that names what will go; not undoable, as in the flat app;
##   Hide / Show a feature's body is left out of the table's picture (cosmetic: the part is still built from its real history);
##   Roll back   to here: every later feature is skipped, as if the part had been built only that far. Roll forward undoes it.
## Hide and rollback change only the TABLE'S COPY: the real part in the arena always shows everything. Hidden ids are the flat
## app's `hidden_feature_ids` (kept in main.gd's native extras, so a save writes them and the flat app reads them); rollback is not
## saved, like the flat app's. Both reach the backend as the two query params of assembly-mesh.glb (DIDSA-CAD, 2026-10-03).

signal changed ## the list, the selection or a state flag changed: the window redraws

const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const Visibility := preload("res://scripts/design_table/visibility.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const ARM_MS := 4000 ## how long a Delete stays armed

var features: Array = [] ## the backend's rows, build order
var names: Array = [] ## "Sketch 1", "Extrude 1"... one per row
var selected_id := ""
var selected_body := ""
var _last_reference_warning := "" ## what the status line was last told about flagged references
var rollback_to := "" ## feature id: everything after this row is rolled back ("" = not rolled back)
var delete_armed_id := ""
var loaded_part := ""
var view_filters_ok := true ## false once the backend said it cannot hide or roll back (an older DIDSA-CAD): the buttons are off and the tree says why

var auto_hidden := {} ## sketch feature id -> [the ids of the features that hid it]: sketches hidden BECAUSE a feature consumed them (session only, never saved)
var _edit_shown: Array = [] ## the seed sketches of the feature being edited: shown while the edit is open
var visibility := Visibility.new() ## the session-only switches (reference planes, origin and axes...): never saved
var _table ## design_table.gd
var _probed := false
var _token := 0
var _armed_until_ms := 0


func setup(table) -> void:
	_table = table
	table.editor.state_changed.connect(func(_state: String) -> void: _maybe_reload())
	table.editor.geometry_changed.connect(reload)


func clear() -> void:
	## The part left the table.
	_token += 1
	features = []
	names = []
	selected_id = ""
	selected_body = ""
	rollback_to = ""
	delete_armed_id = ""
	loaded_part = ""
	_last_reference_warning = ""
	changed.emit()


func _maybe_reload() -> void:
	var pid: String = _table.editor.part_id
	if pid == "" or _table.seated == null:
		return
	if pid != loaded_part:
		reload()
	elif pid != "" and _table.editor.state == "sketch":
		reload() # a sketch was just opened: it is a feature now


func reference_warning() -> String:
	## One line naming what the backend flagged in the feature list: which sketches (and other features) lost a reference to the part or have one that
	## may have moved. "" when all is well.
	var bits: Array = []
	for i in features.size():
		var note := BuildTree.reference_note(features[i])
		if note != "":
			bits.append("%s: %s" % [names[i], note])
	if bits.is_empty():
		return ""
	return "Build tree: %s. Edit a sketch and use Fix to re-pick." % "; ".join(bits)


func _warn_references() -> void:
	## The status line says so once when the list first shows a flagged reference (and again if the flags change), not on every refresh.
	var warning := reference_warning()
	if warning == _last_reference_warning:
		return
	_last_reference_warning = warning
	if warning != "":
		_table.set_status(warning)


func probe_backend() -> void:
	## Asks the backend once whether Hide / Show and Roll back can work at all (see cad_api.gd supports_view_filters()).
	if _probed or _table.api == null or not _table.api.has_method("supports_view_filters"):
		return
	_probed = true
	var ok: bool = await _table.api.supports_view_filters()
	if ok != view_filters_ok:
		view_filters_ok = ok
		changed.emit()


func reload() -> void:
	## Reads the feature list again (coroutine; a slower earlier answer never overwrites a newer one).
	var pid: String = _table.editor.part_id
	if pid == "" or _table.seated == null:
		clear()
		return
	probe_backend()
	_token += 1
	var mine := _token
	var r: Dictionary = await _table.editor.features.list_features(pid)
	if mine != _token or _table.editor.part_id != pid or _table.seated == null:
		return
	if not r["ok"]:
		_table.set_status("Couldn't read the build tree: %s" % str(r["error"]))
		return
	features = r["features"]
	names = BuildTree.names(features)
	var first_time := loaded_part != pid
	loaded_part = pid
	if index_of(selected_id) < 0:
		selected_id = ""
	if rollback_to != "" and index_of(rollback_to) < 0:
		rollback_to = ""
	if delete_armed_id != "" and index_of(delete_armed_id) < 0:
		delete_armed_id = ""
	changed.emit()
	_warn_references()
	if not _table._main.visibility_ruled_parts.has(pid):
		_table._main.visibility_ruled_parts.append(pid)
		apply_load_rule()
	if first_time and _table.editor.view_is_filtered():
		await _table.editor.refresh_view() # a part seated with features already hidden: the copy shows it that way


# --- Reading ---------------------------------------------------------------------------

func index_of(feature_id: String) -> int:
	for i in features.size():
		if str(features[i].get("id", "")) == feature_id:
			return i
	return -1


func row(feature_id: String) -> Dictionary:
	var i := index_of(feature_id)
	return features[i] if i >= 0 else {}


func part_name() -> String:
	return str(_table.seated.name) if _table.seated != null else ""


func hidden_ids() -> Array:
	## The hidden features of THIS part (the saved list also holds other parts' ids; the backend would ignore them, but they must not
	## count as "something is hidden here"). A sketch an applied feature hid shows again while every feature that consumed it is rolled
	## back, and while one of them is open for editing.
	var mine := features.map(func(f): return str(f.get("id", "")))
	return _table._main.hidden_feature_ids().filter(func(id): return mine.has(str(id)) and not _shown_for_now(str(id)))


func _shown_for_now(sketch_id: String) -> bool:
	if _edit_shown.has(sketch_id):
		return true
	if not auto_hidden.has(sketch_id):
		return false
	return (auto_hidden[sketch_id] as Array).all(func(cause): return is_rolled_back(str(cause)))


func auto_note(sketch_id: String) -> String:
	## "seed of Extrude 1" for a sketch hidden because a feature consumed it, else "".
	if not auto_hidden.has(sketch_id) or _shown_for_now(sketch_id):
		return ""
	for cause in auto_hidden[sketch_id]:
		var i := index_of(str(cause))
		if i >= 0:
			return "seed of %s" % names[i]
	return ""


func mesh_hidden_ids() -> Array:
	## The hidden ids that change the PICTURE: bodies, surfaces and curves come back from the backend flagged hidden. A sketch or a created plane
	## is not in the mesh, so hiding one (the load rule hides most sketches) must not cost a second glb fetch or mark the copy filtered.
	var drawn := {}
	for f in features:
		if Visibility.category_of(f) in [Visibility.BODIES, Visibility.SURFACES, Visibility.CURVES]:
			drawn[str(f.get("id", ""))] = true
	return hidden_ids().filter(func(id): return drawn.has(str(id)))


func is_hidden(feature_id: String) -> bool:
	return hidden_ids().has(feature_id)


func apply_load_rule() -> void:
	## Once per part per loaded file: sketches nothing consumes are shown, created planes hidden, other hides in the file kept (visibility.gd).
	var saved: Array = _table._main.hidden_feature_ids()
	var ruled := Visibility.load_hidden(features, saved, rollback_excluded())
	var causes := Visibility.seed_causes(features, rollback_excluded())
	for f in features:
		auto_hidden.erase(str(f.get("id", ""))) # this part's sketches are re-read from the rule
	for sketch in causes:
		if ruled.has(sketch):
			auto_hidden[sketch] = causes[sketch]
	if ruled.size() != saved.size() or ruled.any(func(id): return not saved.has(id)):
		_table._main.set_hidden_feature_ids(ruled, false)


func category_state(category: String) -> Dictionary:
	return Visibility.category_state(features, hidden_ids(), category, rollback_excluded())


func toggle_category(category: String) -> void:
	## A category button (batch rule in visibility.gd): all visible -> hide all, otherwise show all.
	if not view_filters_ok or category_state(category)["total"] == 0:
		return
	_table._main.set_hidden_feature_ids(Visibility.toggle_category(features, _table._main.hidden_feature_ids(), category, rollback_excluded()))
	_forget_shown(_table._main.hidden_feature_ids())
	await _table.editor.refresh_view()
	changed.emit()


func set_all_visible(show: bool) -> void:
	## The drawer's Show all / Hide all: every feature category (hidden ids) and every session switch.
	visibility.set_all(show)
	if view_filters_ok and not features.is_empty():
		_table._main.set_hidden_feature_ids(Visibility.set_all_features(features, _table._main.hidden_feature_ids(), not show, rollback_excluded()))
		_forget_shown(_table._main.hidden_feature_ids())
		await _table.editor.refresh_view()
	changed.emit()


func rollback_excluded() -> Array:
	## The ids the table's copy is built without: everything after the rollback row.
	if rollback_to == "" or index_of(rollback_to) < 0:
		return []
	return BuildTree.rolled_back_ids(features, index_of(rollback_to))


func is_rolled_back(feature_id: String) -> bool:
	return rollback_excluded().has(feature_id)


func is_rolled_back_any() -> bool:
	return rollback_to != "" and not rollback_excluded().is_empty()


func body_ids() -> Array:
	## The bodies of the part as the table shows it now (a hidden feature's body is not among them).
	return _table.editor.body_ids()


func armed(feature_id: String) -> bool:
	return delete_armed_id == feature_id and Time.get_ticks_msec() < _armed_until_ms


# --- Select and light up ------------------------------------------------------------------

func select(feature_id: String) -> void:
	selected_id = feature_id
	selected_body = ""
	delete_armed_id = ""
	_light_feature(feature_id)
	changed.emit()


func select_body(body_id: String) -> void:
	selected_id = ""
	selected_body = body_id
	delete_armed_id = ""
	var copy: MeshInstance3D = _table.table_copy
	var entities: Array = []
	if copy != null and copy.has_meta("body_ids"):
		for f in BuildTree.faces_of("", copy.get_meta("body_ids"), copy.get_meta("face_ids"), body_id):
			entities.append(BuildTree.entity("face", f["body_id"], f["index"]))
	_show(entities)
	_table.set_status("%s." % BuildTree.body_names(copy.get_meta("body_ids") if copy != null and copy.has_meta("body_ids") else []).get(body_id, "Body"))
	changed.emit()


func _light_feature(feature_id: String) -> void:
	var f := row(feature_id)
	if f.is_empty():
		_show([])
		return
	var entities: Array = []
	var copy: MeshInstance3D = _table.table_copy
	var type := str(f.get("type", ""))
	match type:
		"extrude":
			if copy != null and copy.has_meta("body_ids"):
				for face in BuildTree.faces_of(feature_id, copy.get_meta("body_ids"), copy.get_meta("face_ids")):
					entities.append(BuildTree.entity("face", face["body_id"], face["index"]))
		"fillet", "chamfer":
			for ref in f.get("edge_refs", []):
				entities.append(BuildTree.entity("edge", str((ref as Dictionary).get("body_id", "")), int((ref as Dictionary).get("index", -1))))
		"create_plane":
			entities = _plane_faces(f)
		"sketch":
			var plane_id = f.get("plane_feature_id")
			if plane_id != null and row(str(plane_id)).size() > 0:
				entities = _plane_faces(row(str(plane_id)))
	_show(entities)
	var text := "%s: %s." % [names[index_of(feature_id)], BuildTree.summary(features, index_of(feature_id))]
	if type == "sketch" and entities.is_empty():
		text = "%s is on a reference plane. (Opening an existing sketch to change it isn't built yet.)" % names[index_of(feature_id)]
	_table.set_status(text)


func _plane_faces(plane_feature: Dictionary) -> Array:
	var out: Array = []
	for ref in plane_feature.get("face_refs", []):
		var inner: Dictionary = (ref as Dictionary).get("face_ref", ref)
		out.append(BuildTree.entity("face", str(inner.get("body_id", "")), int(inner.get("index", -1))))
	return out


func _show(entities: Array) -> void:
	var editor = _table.editor
	if editor.highlight != null and _table.table_copy != null:
		editor.highlight.set_set(_table.table_copy, entities)


# --- Edit values ----------------------------------------------------------------------------

func can_edit(feature_id: String) -> bool:
	var type := str(row(feature_id).get("type", ""))
	var tool = FeatureTools.for_type(type)
	return BuildTree.EDITABLE.has(type) or (type == "sketch" and str(row(feature_id).get("sketch_id", "")) != "") or (tool != null and tool.edits_in_tool())


func edit_selected() -> void:
	var f := row(selected_id)
	if f.is_empty() or not can_edit(selected_id):
		return
	if str(f.get("type", "")) == "sketch":
		await _table.editor.reopen_sketch(selected_id) # a sketch is edited on the sheet, not with a number
		return
	var in_tool = FeatureTools.for_type(str(f.get("type", "")))
	if in_tool != null and in_tool.edits_in_tool():
		await _table.editor.begin_tool_edit(selected_id)
		return
	_table._main.open_keyboard_for("%.2f" % BuildTree.value_of(f), func(text: String) -> void: edit_typed(selected_id, text), {"title": BuildTree.value_title(str(f["type"]))})


func fix_selected() -> void:
	## The Fix button of a flagged row: show the part as the feature saw it and let the laser pick the replacement edge / face (the editor's fix mode).
	if selected_id == "" or BuildTree.fix_target(row(selected_id)).is_empty():
		return
	await _table.editor.begin_fix(selected_id)


func edit_typed(feature_id: String, text: String) -> void:
	## The numeric pad's answer: PATCH the feature, show the result, remember how to take it back.
	var f := row(feature_id)
	var cleaned := text.strip_edges()
	if f.is_empty() or not cleaned.is_valid_float() or cleaned.to_float() <= 0.0 or (str(f.get("type", "")) == "revolve" and cleaned.to_float() > 360.0):
		_table.set_status("Enter a number bigger than zero (an angle: up to 360)." if str(f.get("type", "")) == "revolve" else "Enter a number bigger than zero.")
		UiFeedback.haptic(_table._right, "error")
		return
	var editor = _table.editor
	var payload := BuildTree.edit_payload(f, cleaned.to_float())
	var undo_payload := BuildTree.edit_payload(f, BuildTree.value_of(f))
	_table.set_status("Working...")
	var result: Dictionary = await editor.features.update_feature(editor.part_id, str(f["type"]), feature_id, payload)
	if not result["ok"]:
		_table.set_status("Couldn't change it: %s" % str(result["error"]))
		UiFeedback.haptic(_table._right, "error")
		return
	editor.feature_stack.append({"kind": "edit", "id": feature_id, "type": str(f["type"]), "payload": undo_payload, "redo_payload": payload})
	editor.redo_stack.clear() # a new action: what was taken back can't be put back any more
	var refreshed: bool = await editor.refresh_geometry()
	_table.notify_edited(editor.part_id, editor._edited_nodes)
	await reload()
	editor.sync_undo_redo()
	UiFeedback.haptic(_table._right, "confirm")
	_table.set_status(("%s is now %s mm." % [names[index_of(feature_id)], BuildTree.number(cleaned.to_float())]) if refreshed else "Changed, but the new shape couldn't be fetched.")


# --- Hide / Show, roll back -----------------------------------------------------------------

func note_applied(feature_id: String) -> void:
	## A feature was applied: the sketches it consumes hide themselves (a sketch the user already hid by hand is left alone: it is never
	## auto-shown later). Nothing is done for a feature that is not an extrude, revolve, loft or sweep.
	await reload()
	var seeds := Visibility.seeds_of_feature(features, feature_id)
	if seeds.is_empty():
		return
	var stored: Array = _table._main.hidden_feature_ids()
	var hid := false
	for sketch in seeds:
		if auto_hidden.has(sketch):
			if not (auto_hidden[sketch] as Array).has(feature_id):
				(auto_hidden[sketch] as Array).append(feature_id)
		elif not stored.has(sketch):
			stored.append(sketch)
			auto_hidden[sketch] = [feature_id]
			hid = true
	if hid:
		_table._main.set_hidden_feature_ids(stored)
	changed.emit()


func note_removed(feature_id: String) -> void:
	## A feature is gone (Undo, or the Build tree's Delete): a sketch only it had hidden comes back; one a hand had hidden stays hidden.
	var stored: Array = _table._main.hidden_feature_ids()
	var shown := false
	for sketch in auto_hidden.keys():
		var causes: Array = auto_hidden[sketch]
		causes.erase(feature_id)
		if causes.is_empty():
			auto_hidden.erase(sketch)
			if stored.has(sketch):
				stored.erase(sketch)
				shown = true
	if shown:
		_table._main.set_hidden_feature_ids(stored)
	changed.emit()


func edit_begun(feature_id: String) -> void:
	## A feature is opened for editing: its seed sketches show while the edit is open.
	_edit_shown = Visibility.seeds_of_feature(features, feature_id)
	changed.emit()


func edit_ended() -> void:
	if not _edit_shown.is_empty():
		_edit_shown = []
		changed.emit()


func _forget_shown(stored: Array) -> void:
	## The user showed a sketch by hand: it is no longer auto-hidden, so nothing re-hides it until the next feature is applied with it.
	for sketch in auto_hidden.keys():
		if not stored.has(sketch):
			auto_hidden.erase(sketch)


func toggle_hidden_selected() -> void:
	await toggle_hidden(selected_id)


func toggle_hidden(feature_id: String) -> void:
	## Hide or show one feature (the strip's button, or the eye on its row, which needs no selecting first).
	if feature_id == "" or not view_filters_ok or index_of(feature_id) < 0:
		return
	var now_hidden := not is_hidden(feature_id)
	_table._main.set_feature_hidden(feature_id, now_hidden)
	_forget_shown(_table._main.hidden_feature_ids())
	await _table.editor.refresh_view()
	_table.set_status("%s %s." % [names[index_of(feature_id)], "hidden on the table" if now_hidden else "shown again"])
	changed.emit()


func toggle_rollback_selected() -> void:
	if selected_id == "" or not view_filters_ok:
		return
	if rollback_to == selected_id:
		rollback_to = ""
		await _table.editor.refresh_view()
		_table.set_status("Rolled forward: the whole part is built again.")
	else:
		var i := index_of(selected_id)
		if i < 0 or i >= features.size() - 1:
			return # nothing after the last row to roll back
		rollback_to = selected_id
		await _table.editor.refresh_view()
		_table.set_status("Rolled back to %s: the %d later feature(s) are skipped. Roll forward to carry on." % [names[i], features.size() - 1 - i])
	changed.emit()


func roll_forward() -> void:
	if rollback_to != "":
		rollback_to = ""
		await _table.editor.refresh_view()
		changed.emit()


# --- Delete ---------------------------------------------------------------------------------

func delete_selected() -> void:
	## First press arms it and says what will go; a second press within a few seconds does it.
	var id := selected_id
	var i := index_of(id)
	if i < 0:
		return
	var now := Time.get_ticks_msec()
	if delete_armed_id != id or now > _armed_until_ms:
		delete_armed_id = id
		_armed_until_ms = now + ARM_MS
		var also := BuildTree.dependents(features, id).map(func(d): return names[index_of(d)])
		_table.set_status("Sure? Deleting %s%s. This can't be undone. Press Delete again." % [names[i], (" also removes " + ", ".join(also)) if not also.is_empty() else ""])
		changed.emit()
		return
	delete_armed_id = ""
	var editor = _table.editor
	_table.set_status("Deleting...")
	var result: Dictionary = await editor.features.delete_cascade(editor.part_id, id)
	if not result["ok"]:
		_table.set_status("Couldn't delete it: %s" % str(result["error"]))
		UiFeedback.haptic(_table._right, "error")
		changed.emit()
		return
	var gone: Array = result["deleted"]
	for gone_id in gone:
		_table._main.set_feature_hidden(str(gone_id), false)
		await note_removed(str(gone_id))
	if rollback_to != "" and gone.has(rollback_to):
		rollback_to = ""
	editor.forget_features(gone)
	selected_id = ""
	var refreshed: bool = await editor.refresh_geometry()
	await editor.refresh_view()
	_table.notify_edited(editor.part_id, editor._edited_nodes)
	await reload()
	UiFeedback.haptic(_table._right, "confirm")
	_table.set_status(("Deleted %d feature(s)." % gone.size()) if refreshed else "Deleted %d feature(s), but the new shape couldn't be fetched." % gone.size())
