extends RefCounted
## One feature the design table can make, as the editor sees it (Phase 5 of docs/implementation-plan.md). table_tools.gd stays the
## registry of what is on the deck; this is what a tool DOES once it is the active one, so table_editor.gd no longer carries a
## match arm per tool and a new tool is one more file here (registered in feature_tools.gd).
##
## The interface, all of it optional except `request`:
##   options(ed)               the tool's settings as the panel shows them: [{id, text, toggle?, pressed?, disabled?}]
##   handle_option(ed, id)     one of those was pressed; true when this tool owned it ("apply" is the editor's)
##   on_activated(ed)          the tool was just chosen: move the editor to the state its picks need, say what is missing
##   request(ed, extra)        the checked create body, {ok, error, route, body}, from what the editor holds (part_features.gd *_request).
##                             The same body is PATCHed by a preview and sent again by Redo.
##   can_apply(ed)             false greys Apply out
##   finishes_sketch()         true when the feature spends the open sketch (Extrude, Revolve)
##   preview_mode()            "none" | "eager" (create now, PATCH while the options change, Cancel deletes) | "coarse" (a translucent
##                             body from the coarse-preview route, nothing stored)
##   preview_route()           the coarse-preview route for "coarse"
##   preview_aux(ed)           awaited before each preview run: a tool may ask the backend for something to show beside its settings (the Gear tool's circle sizes)
## `ed` is table_editor.gd. A tool reads and writes its settings through `ed.options` and its picks through `ed.edges` / `ed.faces`.

const PartFeatures := preload("res://scripts/design_table/part_features.gd")

var id := ""


func options(_ed) -> Array:
	return []


func handle_option(_ed, _option_id: String) -> bool:
	return false


func on_activated(_ed) -> void:
	pass


func request(_ed, _extra: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error": "That tool can't make a feature yet.", "route": "", "body": {}}


func wants_plane_pick() -> bool:
	## true: a pull on a reference plane, a made plane or a flat face is this tool's pick (on_plane_picked) instead of starting a sketch there
	return false


func on_plane_picked(_ed, _spec: Dictionary) -> void:
	pass


func on_pick(_ed, _kind: String) -> void:
	## the laser just picked something of this kind ("edge", "vertex") for the tool (a tool that needs one kind, then another, moves the pick on here)
	pass


func can_apply(_ed) -> bool:
	return true


func reload_build_after() -> bool:
	## true: the Build tree is read again after Apply (the feature is not seen in the part's mesh, e.g. a plane)
	return false


func finishes_sketch() -> bool:
	return false


func preview_mode() -> String:
	return "none"


func preview_route() -> String:
	return ""


func preview_aux(_ed) -> void:
	pass


func build_type() -> String:
	## The backend's feature type this tool makes (the Build tree's `type`); the route is "<type with - for _>-features"
	return id


func edits_in_tool() -> bool:
	## true: the Build row's Edit opens this tool with the feature's settings loaded (load_from_row), and Apply PATCHes it
	return false


func edits_row(_row: Dictionary) -> bool:
	## false: this Build row has the tool's feature type but is not one it makes (the curve type is shared: the Helix tool does not edit an intersection curve)
	return true


func load_from_row(_ed, _row: Dictionary) -> void:
	pass


func patch_keys() -> Array:
	## the body keys a PATCH of this feature may carry (row_payload picks those out of the row to put the old values back)
	return []


func row_payload(row: Dictionary) -> Dictionary:
	var out := {}
	for key in patch_keys():
		if row.has(key):
			out[key] = row[key]
	return out


func summary(_f: Dictionary, _features: Array) -> String:
	## the second line of the feature's Build row
	return ""


func patch_body(req: Dictionary) -> Dictionary:
	## What a PATCH of the feature made from `req` sends. The update routes ignore fields they do not take, so the create body does (override
	## when a field must not be sent again).
	return req["body"]


func done_text() -> String:
	return "%s done." % id.capitalize()
