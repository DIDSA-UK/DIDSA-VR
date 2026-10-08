extends "res://scripts/design_table/features/feature_tool.gd"
## Chamfer: bevel the picked edges.


func _init() -> void:
	id = "chamfer"


func options(ed) -> Array:
	return [{"id": "distance", "text": "Distance %.2f mm" % float(ed.options["distance"])}, {"id": "clear_edges", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d)" % ed.edges.size(), "disabled": not can_apply(ed)}]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"distance":
			ed.type_option("distance", "Distance (mm)")
		"clear_edges":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	ed.start_edge_picks()


func can_apply(ed) -> bool:
	return not ed.edges.is_empty()


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.chamfer_request(ed.edge_refs(), float(ed.options["distance"]))
