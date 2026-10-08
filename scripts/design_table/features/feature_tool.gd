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


func can_apply(_ed) -> bool:
	return true


func finishes_sketch() -> bool:
	return false


func preview_mode() -> String:
	return "none"


func preview_route() -> String:
	return ""


func done_text() -> String:
	return "%s done." % id.capitalize()
