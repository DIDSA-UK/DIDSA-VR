extends SceneTree
## Talks to a real backend (DIDSA-CAD main, with GET /parts/{id}/assembly-tree; tests/ci_e2e.sh runs it, it is in tests/e2e_ci_list.txt). The Assembly Tree window against a
## real two-level assembly (A5 of docs/assembly-tree-overhaul-scope.md; "e2e_assembly_tree.gd" of docs/feature-tree-review-2026-11-11.md):
##   a STEP file with a two-level assembly (tests/fixtures/assembly_two_level.step: a top with a part, two placements of a sub-assembly and a mirrored part; a pin inside the
##   sub-assembly) is imported as an assembly; the window reads the whole hierarchy with the tree call (the structure, then ?status=true), the nested rows exist under BOTH
##   placements of the sub-assembly; a nested part is fixed from the tree (the bottom bar's Fix, PATCHed on the sub-assembly's own Part), the tree shows it fixed under both
##   placements after its refresh, the backend agrees, and a grip on that part is refused with the "Part is fixed" words.
##   B7: with the document given a file key, the open rows are stored (a viewport-style reveal of the nested part) and come back when the document is read again (a reopen: the
##   same tree call against the real backend), and Find narrows the real tree: a name finds both placements of the nested part, ":fixed" finds the fixed row and nothing is
##   changed in the open rows by it.
## Writes nothing to disk but the throwaway secrets copy and settings under user://.
## Run: DIDSA_NO_LANDING=1 DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_assembly_tree.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend (tools/start_backend.sh).

const BackendSession := preload("res://scripts/backend_session.gd")
const Model := preload("res://scripts/tree/occurrence_tree_model.gd")
const FIXTURE := "res://tests/fixtures/assembly_two_level.step"

var main
var window
var url := ""
var key := ""


func _api(method: int, path: String) -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request(url + "/document" + path, BackendSession.headers(key), method)
	var result: Array = await req.request_completed
	req.queue_free()
	var text := (result[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(result[1]), "json": JSON.parse_string(text) if text != "" else null}


func _wait_for(cond: Callable, timeout_ms: int = 90000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func _nested_rows() -> Array:
	var out: Array = []
	var index := Model.index_rows(window._tree[0]["children"] as Array)
	for k in index:
		var row: Dictionary = index[k]
		if (row["path"] as Array).size() == 2 and not bool(row["missing"]):
			out.append(row)
	return out


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	secrets.save("user://e2e_assembly_tree_secrets.cfg")
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "user://e2e_assembly_tree_secrets.cfg"
	root.add_child(main)
	await process_frame
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed")) # (the start-up import of assembly.didsa first)
	var step_path := ProjectSettings.globalize_path(FIXTURE)
	main._import_external_file(step_path, "step")
	await _wait_for(func() -> bool: return not main.pending_import.is_empty())
	await main.resolve_import_choice("assembly")
	await _wait_for(func() -> bool: return main.status_text.contains("Imported ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"))
	check("the two-level assembly is imported (%s)" % main.status_text, main.status_text.begins_with("Imported 3 of 3 parts as an assembly"))
	var root_id: String = main.current_root_part_id()
	main.document_dirty = false

	# --- the tree: one call, then the same with status
	window = main._assembly_tree_window
	window.open()
	await _wait_for(func() -> bool: return not window._stale and bool(window._resp.get("status_included", false)))
	check("the window read the tree call (not the per-level fallback): the structure, then the status merged in", not window._endpoint_missing and not window._resp.is_empty() and bool(window._resp.get("status_included", false)))
	var top_rows: Array = window._tree[0]["children"]
	var subs := top_rows.filter(func(r): return r["node_kind"] == "assembly")
	check("the top lists its placed occurrences: a part, two placements of the sub-assembly (told apart as <1> and <2>), and the mirrored part", top_rows.size() == 4 and subs.size() == 2 and str(subs[0]["name"]).ends_with("<1>") and str(subs[1]["name"]).ends_with("<2>"))
	var live: Dictionary = (await _api(HTTPClient.METHOD_GET, "/parts/%s/assembly-tree" % root_id))["json"]
	check("the window's tree is what the backend answers (same occurrences at every depth)", live is Dictionary and (live["children"] as Array).size() == top_rows.size() and not (live["children"][1]["children"] as Array).is_empty())

	# --- the nested rows under both placements, then Fix from the tree
	var nested := _nested_rows()
	var target: Dictionary = nested[0] if not nested.is_empty() else {}
	var twins := nested.filter(func(r): return not target.is_empty() and r["id"] == target["id"] and r["path"] != target["path"])
	check("rows exist below the sub-assembly at depth 2, under each placement: distinct paths, the same occurrence id", not target.is_empty() and twins.size() == 1)
	if twins.size() != 1:
		quit(1)
		return
	var other: Dictionary = twins[0]
	for r in subs:
		r["expanded"] = true
	window._rebuild_rows()
	window._on_row_selected(target)
	await process_frame
	check("a nested row selects by its path (the bar acts on it)", window._has_selected and window._selected == target["path"])
	var owner := str(target["parent_part_id"])
	var was_fixed := bool(target["fixed"])
	await window._on_bar_action("fix", target, {})
	var occ_after: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner)
	var fixed_on_server := false
	for o in (occ_after["json"] if occ_after["json"] is Array else []):
		if str(o.get("id", "")) == str(target["id"]):
			fixed_on_server = bool(o.get("fixed", false))
	check("Fix PATCHed the occurrence on the sub-assembly's own Part: the backend holds it fixed (it was not before)", not was_fixed and fixed_on_server)
	await _wait_for(func() -> bool:
		var t: Dictionary = Model.find_row(window._tree, target["path"])
		return not t.is_empty() and bool(t["fixed"]) and bool(window._resp.get("status_included", false)), 20000)
	var t1: Dictionary = Model.find_row(window._tree, target["path"])
	var t2: Dictionary = Model.find_row(window._tree, other["path"])
	check("after the refresh both placements show it fixed (one occurrence, two placements), as a pin", not t1.is_empty() and not t2.is_empty() and t1["state"] == "fixed" and t2["state"] == "fixed" and Model.state_icon(t1) == "pin")
	check("the refresh kept what was open and the selection", bool(Model.find_row(window._tree, [str(subs[0]["id"])])["expanded"]) and window._has_selected and window._selected == target["path"])

	# --- a grip on that part is refused
	var node: Node3D = null
	for n in get_nodes_in_group("grabbable_parts"):
		if (n.get_meta("group_path", []) as Array) == target["path"]:
			node = n
			break
	check("the part is in the world under that path", node != null)
	var hand = main.get_node("XROrigin3D/RightController")
	if hand.mates_tool == null:
		hand.mates_tool = main._mates_tool
	var refusal: Dictionary = hand.refusal_for({"depth": (target["path"] as Array).size(), "prefix": target["path"], "label": str(target["name"])}, node) if node != null else {}
	check("a grip on the part just fixed in the tree is refused with the 'Part is fixed' words (%s)" % str(refusal.get("short", "")), str(refusal.get("short", "")).begins_with("Part is fixed"))

	# --- Float again from the tree: the refusal goes
	await window._on_bar_action("fix", Model.find_row(window._tree, target["path"]), {})
	var refusal_after: Dictionary = hand.refusal_for({"depth": (target["path"] as Array).size(), "prefix": target["path"], "label": str(target["name"])}, node) if node != null else {"short": "no node"}
	check("Float from the tree lifts the refusal", str(refusal_after.get("short", "")) == "")
	var floated: Dictionary = Model.find_row(window._tree, target["path"])
	check("Tree A5.1: straight after the Float the row is not a pin and not a guess (it says 'updating' until status arrives)", not bool(floated["fixed"]) and floated["state"] != "fixed")
	await _wait_for(func() -> bool:
		var t: Dictionary = Model.find_row(window._tree, target["path"])
		return not t.is_empty() and t["state"] != "pending" and bool(window._resp.get("status_included", false)), 20000)
	for i in 120: # (long enough for any read that was already in flight to land: a stale one must not put the pin back)
		await process_frame
	var occ_float: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner)
	var floating_on_server := false
	for o in (occ_float["json"] if occ_float["json"] is Array else []):
		if str(o.get("id", "")) == str(target["id"]):
			floating_on_server = not bool(o.get("fixed", false))
	var settled: Dictionary = Model.find_row(window._tree, target["path"])
	check("Tree A5.1: the backend says floating and the settled row agrees: no pin, a real state from the fresh status (%s)" % str(settled.get("state")), floating_on_server and settled["state"] != "fixed" and settled["state"] != "pending")

	# --- B7: remembered open rows across a reopen, and Find, against the real tree
	var settings = main._settings
	var doc := "user://e2e_assembly_tree_doc.didsa"
	settings.tree_open_docs = []
	main._opened_native_path = doc
	window.mark_stale() # (what opening the file again does: the same tree call, a new load)
	await _wait_for(func() -> bool: return not window._stale and bool(window._resp.get("status_included", false)))
	check("B7: the document with a file key loads with nothing stored for it and the default rows (only the root open)", window._doc_key == doc and window._spec_open_keys().is_empty() and settings.tree_open_keys(doc) == null)
	window._selected = target["path"]
	window._has_selected = true
	await window.expand_to_selection()
	var stored: Variant = settings.tree_open_keys(doc)
	check("B7: To selection opens the row's ancestors and stores them (%s)" % str(stored), stored is Array and (stored as Array).has(str(target["path"][0])) and window.row_count() > top_rows.size() + 1)
	var open_before: Array = window._spec_open_keys()
	window.mark_stale() # reopen
	await _wait_for(func() -> bool: return not window._stale and bool(window._resp.get("status_included", false)))
	check("B7: read again from the real backend, the remembered rows are open again and the selection is not touched", window._spec_open_keys() == open_before and not Model.find_row(window._tree, target["path"]).is_empty() and window._restored_any)
	window.set_query(str(target["name"]).get_slice(" ", 0))
	var found: Array = window._descs.filter(func(d): return str(d["kind"]) == "row" and (d["row"] as Dictionary).get("path", []).size() == 2 and (d["row"] as Dictionary)["id"] == target["id"])
	check("B7: Find on the real tree lists the nested part under both placements", found.size() == 2 and window.current_query() != "" and window._spec_open_keys() == open_before)
	window.set_query(":fixed")
	check("B7: ':fixed' lists rows (the fixed flag, whatever the state) and leaves the open rows alone", window.row_count() >= 1 and window._spec_open_keys() == open_before)
	window.clear_query()
	await _wait_for(func() -> bool: return true)
	check("B7: clearing it gives back the rows that were open", window._spec_open_keys() == open_before and window.row_count() > top_rows.size() + 1)
	window.collapse_all()
	check("B7: Collapse stores the empty set", window._spec_open_keys().is_empty() and settings.tree_open_keys(doc) == [])
	settings.tree_open_docs = []
	window._set_grouping(true)
	quit(0)
