extends SceneTree
## colour_tool.gd's pure logic (hex conversion, the no-network-needed
## root-content rejection, and the local material_override apply) - the
## real PATCH-against-a-running-backend path is tests/e2e_colour.gd (manual
## run, same "needs a real backend" exception as this project's other
## e2e_*.gd tests).
## Run: "$GODOT" --headless --path . --script res://tests/colour_tool.gd

const ColourTool := preload("res://scripts/colour_tool.gd")


func _tagged_mesh_part(owner_part_id: String, occurrence_id: String, name: String) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = name
	part.mesh = BoxMesh.new()
	part.set_meta("owner_part_id", owner_part_id)
	part.set_meta("occurrence_id", occurrence_id)
	return part


func _initialize() -> void:
	# --- hex conversion matches the backend's own straight 0-255->0-1 scaling
	var red := ColourTool._hex_to_color("#ff0000")
	print("SMOKE red hex converts exactly: ", red.is_equal_approx(Color(1.0, 0.0, 0.0, 1.0)))
	var mixed := ColourTool._hex_to_color("#3498db")
	print("SMOKE arbitrary hex converts correctly: ", mixed.is_equal_approx(Color(0x34 / 255.0, 0x98 / 255.0, 0xdb / 255.0, 1.0)))

	# --- root content (occurrence_id "") is rejected before ever touching
	# the network (no backend configured on this tool instance at all - if
	# it tried a real HTTP request this would hang/error, not just fail fast)
	var tool := ColourTool.new()
	get_root().add_child(tool)
	var root_content := _tagged_mesh_part("part-a", "", "RootContent")
	var result: Dictionary = await tool.set_color(root_content, "#ff0000")
	print("SMOKE root content colouring rejected: ", not result["ok"] and result["error"].begins_with("Can't colour the assembly's own root content"))
	print("SMOKE rejected part's material is untouched: ", root_content.material_override == null)

	# --- _apply_local_color (pure, no network) sets a real material
	var placed := _tagged_mesh_part("part-a", "occ-1", "Bolt")
	tool._apply_local_color(placed, "#3498db")
	var applied_mat: StandardMaterial3D = placed.material_override
	print("SMOKE local colour apply sets a real material_override: ", applied_mat != null)
	print("SMOKE applied material albedo matches the requested hex: ", applied_mat.albedo_color.is_equal_approx(ColourTool._hex_to_color("#3498db")))

	# --- clearing (empty hex) applies the neutral default, not the mesh's
	# own untouched look (see colour_tool.gd's own docstring for why)
	tool._apply_local_color(placed, "")
	var cleared_mat: StandardMaterial3D = placed.material_override
	print("SMOKE clearing applies the neutral default colour: ", cleared_mat.albedo_color.is_equal_approx(ColourTool.DEFAULT_MATERIAL_COLOR))

	root_content.free()
	placed.free()
	tool.free()
	quit()
