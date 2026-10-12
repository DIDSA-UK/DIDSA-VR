extends SceneTree
## Measure results drawn in the world (scripts/measure_dimensions.gd): what describe() decides to draw for a result
## (a linear dimension for two points, a radius / diameter callout for a circular pick, a length label for an edge, nothing
## for volume / area), and the node turning that into lines and labels, following the tool and hiding when it is off.
## Run: "$GODOT" --headless --path . --script res://tests/measure_dimensions.gd  (see tests/README.md)

const Dim := preload("res://scripts/measure_dimensions.gd")


class FakeTool extends Node:
	signal picks_changed()
	signal result_changed()
	var active := true
	var result: Dictionary = {}
	var points: Array = []

	func picked_points() -> Array:
		return points


func _initialize() -> void:
	var a := Vector3(0, 1, 0)
	var b := Vector3(0.3, 1, 0)
	var linear := Dim.describe({"distance": 300.0}, [a, b])
	print("SMOKE two points + a distance = one linear dimension between them: ", linear.size() == 1 and linear[0]["kind"] == "linear" and linear[0]["a"] == a and linear[0]["b"] == b and linear[0]["text"] == "300 mm")
	var dia := Dim.describe({"diameter": 25.0, "radius": 12.5}, [a])
	print("SMOKE a circular pick = a callout with the diameter and the radius: ", dia.size() == 1 and dia[0]["kind"] == "callout" and dia[0]["text"] == "Ø 25 mm   R 12.5 mm")
	var rad := Dim.describe({"radius": 3.25}, [a])
	print("SMOKE a radius alone = an R callout: ", rad.size() == 1 and rad[0]["text"] == "R 3.25 mm")
	var length := Dim.describe({"length": 40.5}, [a])
	print("SMOKE an edge = an L label at the pick: ", length.size() == 1 and length[0]["text"] == "L 40.5 mm" and length[0]["a"] == a)
	print("SMOKE volume / area / mass are not drawn (they are on the tablet): ", Dim.describe({"area": 100.0, "body_volumes": {"b": 5.0}}, [a]).is_empty())
	print("SMOKE no result or no point = nothing: ", Dim.describe({}, [a]).is_empty() and Dim.describe({"distance": 1.0}, []).is_empty())
	print("SMOKE a distance with only one point falls back to the other results: ", Dim.describe({"distance": 5.0, "length": 5.0}, [a])[0]["text"] == "L 5 mm")
	print("SMOKE numbers drop trailing zeros: ", Dim.format_mm(12.5) == "12.5" and Dim.format_mm(12.0) == "12" and Dim.format_mm(0.1234567) == "0.123")

	var cam := Camera3D.new()
	root.add_child(cam)
	var tool := FakeTool.new()
	root.add_child(tool)
	var node := Dim.new()
	root.add_child(node)
	await process_frame
	node.setup(tool, cam)
	print("SMOKE nothing to draw at the start, so the node is hidden: ", not node.visible and node.items().is_empty())
	tool.result = {"distance": 120.0}
	tool.points = [a, b]
	tool.result_changed.emit()
	var labels := node.get_children().filter(func(c: Node) -> bool: return c is Label3D)
	print("SMOKE a result shows one dimension with a value label: ", node.visible and node.items().size() == 1 and labels.size() == 1 and (labels[0] as Label3D).text == "120 mm")
	print("SMOKE the dimension has line geometry: ", (node.get_node("Lines") as MeshInstance3D).mesh != null)
	tool.result = {"diameter": 8.0}
	tool.points = [a]
	tool.picks_changed.emit()
	labels = node.get_children().filter(func(c: Node) -> bool: return c is Label3D and not c.is_queued_for_deletion())
	print("SMOKE a new result replaces the old drawing: ", node.items().size() == 1 and node.items()[0]["kind"] == "callout" and labels.size() == 1)
	tool.active = false
	tool.result_changed.emit()
	print("SMOKE switching the tool off clears the dimensions: ", not node.visible and node.items().is_empty())
	quit()
