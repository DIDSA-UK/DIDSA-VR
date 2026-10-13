extends SceneTree
## Assembly Rooms R4, the design table's world preview (scripts/design_table/table_preview.gd): the empty place a table part leaves in the world as a faint ghost
## of the original or a preview of the edited part in the preview colour (the changed tint once an edit has changed it), following the hidden node, tidied away when
## the part leaves the table. Headless; a stand-in table (a node with `seated` and `table_copy`).
## Run: "$GODOT" --headless --path . --script res://tests/table_preview.gd  (see tests/README.md)

const TablePreview := preload("res://scripts/design_table/table_preview.gd")
const WorldPreview := preload("res://scripts/room/world_preview.gd")

const STUB := "extends Node3D
var seated
var table_copy
"


func _initialize() -> void:
	var stub := GDScript.new()
	stub.source_code = STUB
	stub.reload()
	var table := Node3D.new()
	table.set_script(stub)
	root.add_child(table)
	var preview := TablePreview.new()
	table.add_child(preview)
	preview.setup(table)
	await process_frame
	print("SMOKE with nothing on the table there is nothing to show, and a mode can't be set: ", not preview.available() and not preview.set_mode(WorldPreview.Mode.PREVIEW) and preview.mode == WorldPreview.Mode.HIDDEN)

	var original := BoxMesh.new()
	var part := MeshInstance3D.new()
	part.mesh = original
	root.add_child(part)
	part.global_position = Vector3(2, 1, -3)
	part.visible = false # (on the table: the real node is hidden)
	var copy := Node3D.new()
	table.add_child(copy)
	table.seated = part
	table.table_copy = copy
	preview.on_seated()
	print("SMOKE a part on the table starts with its world place empty: ", preview.available() and preview.mode == WorldPreview.Mode.HIDDEN and preview.get_child_count() == 0)

	preview.set_mode(WorldPreview.Mode.GHOST)
	await process_frame
	var proxy: MeshInstance3D = preview._proxy
	print("SMOKE Ghost shows the original where the part sits in the world, faintly: ", proxy != null and proxy.mesh == original and proxy.global_position.is_equal_approx(Vector3(2, 1, -3)) and absf(float((proxy.material_override as ShaderMaterial).get_shader_parameter("alpha")) - 0.18) < 0.001)
	print("SMOKE ...with a tether from the table to it: ", preview._tether != null)

	preview.set_mode(WorldPreview.Mode.PREVIEW)
	await process_frame
	proxy = preview._proxy
	var tint: Color = (proxy.material_override as ShaderMaterial).get_shader_parameter("tint")
	print("SMOKE Preview shows the part in the preview colour, unchanged so far: ", proxy.mesh == original and tint.is_equal_approx(WorldPreview.PREVIEW_TINT) and not preview.is_changed())

	var edited := BoxMesh.new()
	edited.size = Vector3(2, 2, 2)
	part.mesh = edited # (table_editor.gd swaps the mesh after a feature goes in)
	await process_frame
	await process_frame
	tint = (proxy.material_override as ShaderMaterial).get_shader_parameter("tint")
	print("SMOKE after an edit the preview shows the edited mesh, in the changed tint: ", preview.is_changed() and proxy.mesh == edited and tint.is_equal_approx(WorldPreview.CHANGED_TINT))
	preview.set_mode(WorldPreview.Mode.GHOST)
	await process_frame
	print("SMOKE ...while the ghost is still the part as it was: ", preview._proxy.mesh == original)

	part.global_position = Vector3(5, 1, 0)
	await process_frame
	print("SMOKE the stand-in follows the hidden node: ", preview._proxy.global_position.is_equal_approx(Vector3(5, 1, 0)))
	print("SMOKE it cycles Hidden, Ghost, Preview, Hidden: ", preview.cycle() == WorldPreview.Mode.PREVIEW and preview.cycle() == WorldPreview.Mode.HIDDEN and preview._proxy == null)

	preview.set_mode(WorldPreview.Mode.PREVIEW)
	table.seated = null
	preview.on_cleared()
	await process_frame
	print("SMOKE when the part leaves the table everything is tidied away: ", preview.mode == WorldPreview.Mode.HIDDEN and preview.get_child_count() == 0 and not preview.available())
	quit(0)
