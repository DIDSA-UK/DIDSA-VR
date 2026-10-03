extends "res://scripts/assembly_tree_window.gd"
## The assembly tree at the design table's left, from John's sketch ("Tree: parts and sub-assemblies can be pulled out onto the
## table or into the world"). It is the ordinary Assembly Tree window (browse the occurrences, tap a name to select the part)
## docked to the console and given two actions on every placed part:
##   Table  puts that part on the table to edit it, without carrying it there;
##   Bring  moves it to a spot in front of you in the arena (an ordinary, undoable move).
## Only parts with geometry in the arena can be taken: a sub-assembly row has none of its own (open it and take one of its parts).
## It is a child of the console, so it moves with it; its own grab handle still moves it separately, and its X puts it away
## until the table is next opened.
##
## Pulling a row out by dragging it is not built: the laser freezes the pointer while the trigger is held (laser_surface.gd, so
## a shaky squeeze can't cancel a button press), so a drag from a row would need a second gesture of its own.

var table ## design_table.gd
@export var dock_position := Vector3(-0.50, 0.20, 0.06) ## in the console's frame
@export var dock_yaw_degrees: float = 24.0 ## turns the panel in towards the slab


func setup_for_table(p_table, left: XRController3D, right: XRController3D, camera: XRCamera3D, main: Node) -> void:
	table = p_table
	setup_tree(left, right, camera, main)
	panel_size = Vector2(0.26, 0.34)
	viewport_size = Vector2i(447, 585)
	_apply_panel_size(panel_size, true)
	_base_width = panel_size.x


func _place_in_front_of_camera() -> void:
	## Docked at the console's left instead of in front of the camera.
	transform = Transform3D(Basis(Vector3.UP, deg_to_rad(dock_yaw_degrees)), dock_position)


func _add_row_actions(line: HBoxContainer, row: Dictionary, _is_expandable: bool) -> void:
	var occurrence_id := str(row.get("id", ""))
	if occurrence_id == "": # the root row is the assembly itself
		return
	var node: Node3D = table.node_for_occurrence(occurrence_id) if table else null
	var on_table: bool = node != null and node == table.seated
	line.add_child(_action("Table", "table", node != null and not on_table, _take_to_table.bind(occurrence_id), &"ButtonAccent"))
	line.add_child(_action("Bring", "scale", node != null and not on_table, _bring.bind(occurrence_id), &""))


func _action(text: String, icon_name: String, enabled: bool, callback: Callable, variation: StringName) -> Button:
	var b := Button.new()
	b.text = text
	b.icon = UiIcons.texture(icon_name, 24)
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(0, 0)
	b.add_theme_font_size_override("font_size", tokens.font_small)
	if variation != &"":
		b.theme_type_variation = variation
	b.pressed.connect(callback)
	return b


func _take_to_table(occurrence_id: String) -> void:
	if table == null:
		return
	var node: Node3D = table.node_for_occurrence(occurrence_id)
	if node == null:
		_set_status("That part isn't in the arena (hidden, or a sub-assembly with no body of its own).")
		return
	var reason: String = table.seat_node(node)
	_set_status(reason)
	_rebuild_rows()


func _bring(occurrence_id: String) -> void:
	if table == null:
		return
	var node: Node3D = table.node_for_occurrence(occurrence_id)
	if node == null:
		_set_status("That part isn't in the arena (hidden, or a sub-assembly with no body of its own).")
		return
	_set_status(table.bring_part(node))
