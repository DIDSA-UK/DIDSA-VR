extends RefCounted
## The feature tools the editor knows, by tool id (the same ids as table_tools.gd's FEATURE_TOOLS).

const ExtrudeTool := preload("res://scripts/design_table/features/extrude_tool.gd")
const RevolveTool := preload("res://scripts/design_table/features/revolve_tool.gd")
const FilletTool := preload("res://scripts/design_table/features/fillet_tool.gd")
const ChamferTool := preload("res://scripts/design_table/features/chamfer_tool.gd")
const ShellTool := preload("res://scripts/design_table/features/shell_tool.gd")
const MirrorTool := preload("res://scripts/design_table/features/mirror_tool.gd")


static func make_all() -> Dictionary:
	var all := {}
	for tool in [ExtrudeTool.new(), RevolveTool.new(), FilletTool.new(), ChamferTool.new(), ShellTool.new(), MirrorTool.new()]:
		all[tool.id] = tool
	return all
