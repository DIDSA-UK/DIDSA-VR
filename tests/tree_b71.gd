extends SceneTree
## Tree B7.1: the follow-ups to B7's review round, against a fake backend (full scene, no real backend).
##   1. Find's words survive a re-read of the same document (a component added, a session observer's refetch) and go for a different one
##   2. Save As moves the words' document key with the file, so the next refresh does not clear them
##   6. Find's words are split on the model's whitespace
##   4. one failed ?status=true call does not leave "unavailable" standing for the next load
##   5. a To selection / selection reveal still fetching a level when the document switches stops there: the new document is not "touched", it opens nothing in it
##   B8 carry-over:
##   7. a status answer dropped for a Fix / Float followed by a failed refresh says "unavailable" whatever the flag was; a floated row does not stay on "updating"
##   8. a Refresh of the same document does not end a reveal still fetching a level; a failed level fetch leaves the row's children not fetched and is no change
##   (3, the store's character cap, and the delayed write are in tests/tree_open_settings.gd.)
## NOT covered: how any of it looks or feels in the headset.
## Run: "$GODOT" --headless --path . --script res://tests/tree_b71.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")

var main
var window
var mode := "tree" ## "tree": the fake serves the tree call; "404": it does not (the per-level fallback)
var status_fails := false
var hold_status := false ## the ?status=true call waits until this clears
var structure_fails := false ## the structure call (no ?status=true) fails
var hold_part := "" ## a /occurrences read for this Part waits until it is cleared
var fail_part := "" ## a /occurrences read for this Part fails
var occurrences := {
	"R": [{"id": "s1", "resolved_part_id": "S"}, {"id": "s2", "resolved_part_id": "S"}],
	"S": [{"id": "k1", "resolved_part_id": "K"}],
	"K": [{"id": "kb", "resolved_part_id": "B"}],
}
const PART_NAMES := {"R": "Rig", "S": "Drive", "K": "Bracket", "B": "Bolt"}


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func settle() -> void:
	for i in 80:
		await process_frame


func nodes(part: String, prefix: Array) -> Array:
	var out: Array = []
	for o in occurrences.get(part, []):
		var resolved: String = o["resolved_part_id"]
		var is_assembly := occurrences.has(resolved)
		var node_path: Array = prefix + [o["id"]]
		out.append({
			"occurrence_id": o["id"], "path": node_path, "external_ref": null, "ref_part_id": resolved, "resolved_part_id": resolved,
			"part_name": PART_NAMES.get(resolved, resolved), "name_override": null, "kind": "assembly" if is_assembly else "part",
			"fixed": false, "hidden": false, "suppressed": false, "color": null, "constraint": null,
			"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false,
			"mates": null, "patterns": null, "problems": null, "children": nodes(resolved, node_path) if is_assembly else [],
		})
	return out


func answer(method: int, path: String, _body) -> Dictionary:
	var bits := path.trim_prefix("/parts/").split("/")
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1].begins_with("assembly-tree"):
		if mode == "404":
			return {"ok": false, "json": null, "code": 404, "detail": "Not Found", "error": "{ \"detail\": \"Not Found\" }"}
		var with_status := bits[1].contains("status=true")
		if not with_status and structure_fails:
			return {"ok": false, "json": null, "code": 0, "error": ""}
		while with_status and hold_status:
			await process_frame
		if with_status and status_fails:
			return {"ok": false, "json": null, "code": 0, "error": ""}
		return {"ok": true, "json": {
			"part_id": "R", "part_name": "Rig", "kind": "assembly", "feature_count": 0, "status_included": with_status,
			"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
			"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0},
			"children": nodes("R", []), "truncated": false, "node_count": 0, "max_depth": 32, "max_nodes": 10000,
			"truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
		}, "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1] == "occurrences":
		while bits[0] == hold_part:
			await process_frame
		if bits[0] == fail_part:
			return {"ok": false, "json": null, "code": 500, "error": "boom"}
		var rows: Array = occurrences.get(bits[0], [])
		return {"ok": true, "json": rows, "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1] == "constraint-status":
		return {"ok": true, "json": {}, "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 1:
		return {"ok": true, "json": {"name": PART_NAMES.get(bits[0], bits[0])}, "error": ""}
	return {"ok": false, "json": null, "code": 404, "error": "404"}


func tiny_glb() -> PackedByteArray:
	var scene := Node3D.new()
	var m := MeshInstance3D.new()
	m.mesh = BoxMesh.new()
	scene.add_child(m)
	m.owner = scene
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(scene, state)
	var bytes := doc.generate_buffer(state)
	scene.free()
	return bytes


func boot() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main._resolved_part_id = "R"
	main._settings.tree_open_docs = []
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	await frames(6)


func _initialize() -> void:
	await boot()
	var glb := tiny_glb()
	check("(setup) a tiny glb to show", glb.size() > 0)

	# --- 1. the same document re-read keeps Find; another one clears it (no file key: nothing else would tell them apart)
	window.set_query("bolt")
	check("(setup) Find has words", window.current_query() == "bolt")
	check("1. a re-read of the same document (session_show_model, same_document) keeps the words", main.session_show_model(glb, true) and window.current_query() == "bolt")
	await settle()
	check("...still there once the tree has been read again", window.current_query() == "bolt" and window._query_box.visible)
	check("1. a different document (the default) clears them", main.session_show_model(glb) and window.current_query() == "")
	await settle()

	# --- 6. the query's words are the model's (an ideographic space and a tab separate words; the edges are trimmed the same way)
	window.set_query("\u3000bolt\u3000:errors\t")
	check("6. Find splits and trims on the model's whitespace, not ASCII space alone", window.current_query() == "bolt :errors")
	window.set_query("Bracket  Left")
	check("...and keeps the case that was typed (the keyboard reopens with it)", window.current_query() == "Bracket Left" and window._query_label.text == "Find: Bracket Left")
	window.clear_query()

	# --- 2. Save As: the words' key moves with the file
	var doc_a := "user://b71_a.didsa"
	var doc_b := "user://b71_b.didsa"
	main._opened_native_path = doc_a
	window.mark_stale()
	await settle()
	window.set_query("bolt")
	main._opened_native_path = doc_b
	window.note_document_changed(doc_a)
	window.mark_stale() # (the refresh a Save As leads to)
	await settle()
	check("2. after Save As the next mark_stale does not clear the words", window.current_query() == "bolt")
	main._opened_native_path = "user://b71_c.didsa"
	window.mark_stale()
	await settle()
	check("...and a really different file still does", window.current_query() == "")
	main._opened_native_path = ""

	# --- 4. a failed status call does not stick
	status_fails = true
	window.mark_stale()
	await settle()
	check("(setup) the status call failed: unavailable", window._status_unavailable)
	status_fails = false
	window._refresh_token += 1 # (the in-place re-read of _refresh_levels(), which does not go through _refresh_root())
	await window._load_endpoint(window._refresh_token)
	check("4. the next load asks again: the flag is clear and the states arrived", not window._status_unavailable)
	status_fails = true
	window._refresh_token += 1
	await window._load_endpoint(window._refresh_token)
	check("(the flag is set again by a new failure)", window._status_unavailable)
	var tree_before: int = window._tree.size()
	var resp_before: Dictionary = window._resp.duplicate(true)
	structure_fails = true # (a re-read whose structure call fails keeps the old tree and answer: and the flag that goes with them)
	window._refresh_token += 1
	await window._load_endpoint(window._refresh_token)
	window.set_query(":errors")
	check("4b. a failed structure call after a failed status call leaves the old tree and answer, and the hint on 'unavailable', not 'still loading'", window._tree.size() == tree_before and window._resp == resp_before and window._status_unavailable and window._query_hint.text.contains("unavailable") and not window._query_hint.text.contains("still loading"))
	window.clear_query()
	structure_fails = false
	# a Fix / Float while ?status=true is in flight drops that answer; if the refresh it queues fails at the structure call, the flag is as it was
	status_fails = false
	window._refresh_token += 1
	await window._load_endpoint(window._refresh_token) # (a clean load: the flag clears)
	status_fails = true
	window._refresh_token += 1
	await window._load_endpoint(window._refresh_token) # (the status call fails: the flag is set)
	status_fails = false
	hold_status = true
	window._refresh_token += 1
	window._load_endpoint(window._refresh_token) # (not awaited: it waits on the held status call)
	await frames(4)
	window._mutation_seq += 1 # (the Fix / Float)
	structure_fails = true
	hold_status = false
	await settle()
	window.set_query(":errors")
	check("4c. a dropped status answer whose refresh fails keeps the flag it had: 'unavailable', not 'still loading'", window._status_unavailable and window._query_hint.text.contains("unavailable") and not window._query_hint.text.contains("still loading"))
	window.clear_query()
	structure_fails = false
	# --- 7. (B8 carry-over) a dropped status answer and a failed refresh, with the flag clear before
	status_fails = false
	window._refresh_token += 1
	await window._load_endpoint(window._refresh_token)
	check("(setup) a clean load: states arrived, the flag clear", not window._status_unavailable and bool(window._resp.get("status_included", false)))
	hold_status = true
	window._refresh_token += 1
	window._load_endpoint(window._refresh_token)
	await frames(4)
	window._mutation_seq += 1 # (a Fix / Float: the status answer in flight is dropped)
	structure_fails = true
	hold_status = false
	await settle()
	window.set_query(":errors")
	check("7. the status answer was dropped and the refresh failed: 'unavailable' although the flag was clear, never 'still loading'", window._status_unavailable and window._query_hint.text.contains("unavailable") and not window._query_hint.text.contains("still loading"))
	window.clear_query()
	structure_fails = false
	window._refresh_token += 1
	await window._load_endpoint(window._refresh_token)
	check("(setup) a clean load again", not window._status_unavailable and bool(window._resp.get("status_included", false)))
	structure_fails = true
	window.note_fixed_changed(["s1"], false) # (a Float: the row reads 'updating' until a fresh status arrives; the read that follows fails)
	check("(setup) the floated row says 'updating'", str(Model.find_row(window._tree, ["s1"])["state"]) == "pending")
	await settle()
	check("7. the failed refresh leaves the floated row on its flag, not 'updating' for good", str(Model.find_row(window._tree, ["s1"])["state"]) != "pending" and not window._row_text(Model.find_row(window._tree, ["s1"])).contains("updating"))
	structure_fails = false
	main.queue_free()
	await frames(3)

	# --- 5. a reveal still fetching a level when the document switches
	mode = "404" # (only the per-level fallback fetches a level when a row is revealed: the tree call brings every level)
	await boot()
	var settings = main._settings
	var doc_x := "user://b71_x.didsa"
	var doc_y := "user://b71_y.didsa"
	settings.tree_open_docs = []
	main._opened_native_path = doc_x
	window.mark_stale()
	await settle()
	check("(setup) per-level fallback, the tree is loaded, nothing is open", not window._tree.is_empty() and not window._endpoint_active() and Model.find_row(window._tree, ["s2"])["children"] == null and not bool(Model.find_row(window._tree, ["s2"])["expanded"]))
	window._has_selected = true
	window._selected = ["s2", "k1", "kb"]
	hold_part = "S"
	window.expand_to_selection() # (not awaited: it waits on the held level)
	await frames(4)
	check("(setup) the reveal is waiting on a level", window._open_touched and hold_part == "S")
	main._opened_native_path = doc_y
	window.mark_stale() # (the document switches; the new one's first answer restores its remembered rows)
	await settle()
	check("(setup) the new document loaded and was not touched", not window._tree.is_empty() and not window._open_touched)
	hold_part = ""
	await settle()
	check("5. the late level does not mark the new document touched, and opens nothing in it", not window._open_touched and not bool(Model.find_row(window._tree, ["s2"])["expanded"]) and settings.tree_open_docs.is_empty())
	main.queue_free()
	await frames(2)

	# --- 8. a Refresh of the same document does not end a reveal; a failed level leaves children not fetched
	await boot()
	settings = main._settings
	settings.tree_open_docs = []
	main._opened_native_path = doc_x
	window.mark_stale()
	await settle()
	window._has_selected = true
	window._selected = ["s2", "k1", "kb"]
	hold_part = "S"
	window.expand_to_selection() # (not awaited: it waits on the held level)
	await frames(4)
	window._refresh_root() # (the Refresh button: the same document, a newer refresh)
	await frames(6)
	hold_part = ""
	await settle()
	var k1 := Model.find_row(window._tree, ["s2", "k1"])
	check("8. a Refresh of the same document did not end the reveal: the levels below were fetched and opened", not k1.is_empty() and k1["children"] != null and bool(Model.find_row(window._tree, ["s2"])["expanded"]) and bool(k1["expanded"]))
	main.queue_free()
	await frames(2)
	await boot()
	settings = main._settings
	settings.tree_open_docs = []
	main._opened_native_path = doc_x
	window.mark_stale()
	await settle()
	window._has_selected = true
	window._selected = ["s2", "k1", "kb"]
	fail_part = "S"
	await window._reveal(window._selected)
	var s2 := Model.find_row(window._tree, ["s2"])
	check("8. a failed level fetch leaves the row's children not fetched and it closed", s2["children"] == null and not bool(s2["expanded"]) and window._status_label.text.contains("Couldn't load children"))
	check("8. ...and it is no change: the rows are not 'touched' and nothing is stored", not window._open_touched and settings.tree_open_docs.is_empty())
	fail_part = ""
	await window._reveal(window._selected)
	check("8. pressed again it asks again and opens", Model.find_row(window._tree, ["s2"])["children"] != null and bool(Model.find_row(window._tree, ["s2"])["expanded"]) and window._open_touched)
	main.queue_free()
	await frames(2)
	quit(0)
