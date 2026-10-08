extends "res://scripts/design_table/features/feature_tool.gd"
## Fillet: round the picked edges.


func _init() -> void:
	id = "fillet"


func options(ed) -> Array:
	return [{"id": "radius", "text": "Radius %.2f mm" % float(ed.options["radius"])}, {"id": "clear_edges", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d)" % ed.edges.size(), "disabled": not can_apply(ed)}]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"radius":
			ed.type_option("radius", "Radius (mm)")
		"clear_edges":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	ed.start_edge_picks()


func can_apply(ed) -> bool:
	return not ed.edges.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.fillet_request(ed.edge_refs(), float(ed.options["radius"]))
