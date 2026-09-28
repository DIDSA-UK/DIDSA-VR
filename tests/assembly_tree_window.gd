extends SceneTree
## Pure-logic test for assembly_tree_window.gd - no scene, no backend, no
## network. Exercises _occurrences_to_rows()/_row_label() directly against
## synthetic OccurrenceResponse-shaped dictionaries, the same style as
## colour_tool.gd's/mates_tool.gd's own pure-logic tests.
## Run: "$GODOT" --headless --path . --script res://tests/assembly_tree_window.gd

const AssemblyTreeWindow := preload("res://scripts/assembly_tree_window.gd")


func _initialize() -> void:
	# A named occurrence with a resolved_part_id (so it's expandable), an
	# unnamed one that falls back to a short id-based label, and one with
	# neither a name nor anything to expand.
	var occurrences := [
		{"id": "occ-0001", "name_override": "Bracket", "resolved_part_id": "part-b"},
		{"id": "ABCDEFGHIJKLMNOP", "name_override": null, "resolved_part_id": "part-c"},
		{"id": "QRSTUVWXYZ123456", "name_override": "", "resolved_part_id": ""},
	]
	var rows := AssemblyTreeWindow._occurrences_to_rows(occurrences)

	print("SMOKE three rows built: ", rows.size() == 3)
	print("SMOKE a named occurrence keeps its own name: ", rows[0]["name"] == "Bracket")
	print("SMOKE an unnamed occurrence falls back to a short id-based label: ", rows[1]["name"] == "Occurrence ABCDEFGH")
	print("SMOKE an empty-string name_override also falls back: ", rows[2]["name"] == "Occurrence QRSTUVWX")
	print("SMOKE a resolved_part_id marks a row expandable: ", rows[0]["resolved_part_id"] == "part-b" and rows[1]["resolved_part_id"] == "part-c")
	print("SMOKE no resolved_part_id means nothing to expand: ", rows[2]["resolved_part_id"] == "")
	print("SMOKE every row starts unexpanded with children not yet fetched: ", not rows[0]["expanded"] and rows[0]["children"] == null)

	print("SMOKE an empty occurrences list builds an empty tree: ", AssemblyTreeWindow._occurrences_to_rows([]).is_empty())

	# A real OccurrenceResponse also carries fields this window doesn't use
	# (transform, suppressed, hidden, fixed, color) - confirm those don't
	# trip up row-building at all.
	var full_shape := [{
		"id": "occ-full", "external_ref": null, "resolved_part_id": "part-x",
		"name_override": "Full Shape", "transform": {"translation": [0, 0, 0], "rotation": [0, 0, 0, 1]},
		"suppressed": false, "hidden": true, "fixed": false, "color": "#ff0000",
	}]
	var full_rows := AssemblyTreeWindow._occurrences_to_rows(full_shape)
	print("SMOKE a full real-shaped OccurrenceResponse still builds correctly: ", full_rows.size() == 1 and full_rows[0]["name"] == "Full Shape" and full_rows[0]["resolved_part_id"] == "part-x")

	quit()
