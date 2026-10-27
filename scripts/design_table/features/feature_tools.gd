extends RefCounted
## The feature tools the editor knows, by tool id (the same ids as table_tools.gd's FEATURE_TOOLS).

const ExtrudeTool := preload("res://scripts/design_table/features/extrude_tool.gd")
const RevolveTool := preload("res://scripts/design_table/features/revolve_tool.gd")
const FilletTool := preload("res://scripts/design_table/features/fillet_tool.gd")
const ChamferTool := preload("res://scripts/design_table/features/chamfer_tool.gd")
const ShellTool := preload("res://scripts/design_table/features/shell_tool.gd")
const MirrorTool := preload("res://scripts/design_table/features/mirror_tool.gd")
const LoftTool := preload("res://scripts/design_table/features/loft_tool.gd")
const SweepTool := preload("res://scripts/design_table/features/sweep_tool.gd")
const PatternTool := preload("res://scripts/design_table/features/pattern_tool.gd")
const BooleanTool := preload("res://scripts/design_table/features/boolean_tool.gd")
const MergeTool := preload("res://scripts/design_table/features/merge_tool.gd")
const SplitTool := preload("res://scripts/design_table/features/split_tool.gd")
const MoveFaceTool := preload("res://scripts/design_table/features/move_face_tool.gd")
const DeleteFaceTool := preload("res://scripts/design_table/features/delete_face_tool.gd")
const MoveBodyTool := preload("res://scripts/design_table/features/move_body_tool.gd")
const ScaleBodyTool := preload("res://scripts/design_table/features/scale_body_tool.gd")
const DeleteBodyTool := preload("res://scripts/design_table/features/delete_body_tool.gd")
const CreatePlaneTool := preload("res://scripts/design_table/features/create_plane_tool.gd")
const GearTool := preload("res://scripts/design_table/features/gear_tool.gd")
const RackTool := preload("res://scripts/design_table/features/rack_tool.gd")
const BevelGearTool := preload("res://scripts/design_table/features/bevel_gear_tool.gd")
const HelixTool := preload("res://scripts/design_table/features/helix_tool.gd")
const SpringTool := preload("res://scripts/design_table/features/spring_tool.gd")


static func make_all() -> Dictionary:
	var all := {}
	for tool in [ExtrudeTool.new(), RevolveTool.new(), FilletTool.new(), ChamferTool.new(), ShellTool.new(), MirrorTool.new(), CreatePlaneTool.new(), LoftTool.new(), SweepTool.new(), HelixTool.new(), SpringTool.new(), PatternTool.new(), BooleanTool.new(), MergeTool.new(), SplitTool.new(), MoveFaceTool.new(), DeleteFaceTool.new(), MoveBodyTool.new(), ScaleBodyTool.new(), DeleteBodyTool.new(), GearTool.new(), RackTool.new(), BevelGearTool.new()]:
		all[tool.id] = tool
	return all


static var _by_type := {}


static func for_type(type: String):
	## The tool that makes backend feature type `type` (the Build tree asks for its summary and Edit), or null.
	if _by_type.is_empty():
		for tool in make_all().values():
			_by_type[tool.build_type()] = tool
	return _by_type.get(type)
