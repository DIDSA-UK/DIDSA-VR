extends RefCounted
## What the design table's category and tool rows show, as DATA, using the same
## registry class the wrist tablet uses (scripts/ui/tablet_registry.gd). Names are
## DIDSA-CAD's own, taken from the flat app: the sketch speed dial's "Sketch
## Entities", its constraint chips, and the feature picker (docs/design-table.md
## has the mapping and what is deliberately not here yet).
##
## Every tool here is a "mode" tool: the laser does that tool's job while it is
## on, and ToolManager keeps it to one at a time. `handler` is the design table;
## it gets handler.tool_activated(id) / handler.tool_deactivated(id).
##
## Categories hold at most the tablet registry's limit, and the tool row pages
## itself (two rows, scrolling sideways) when a category has more tools than fit.

const TabletRegistry := preload("res://scripts/ui/tablet_registry.gd")

const ACCENT_SKETCH := Color(0.31, 0.77, 1.00) ## cyan, the same as the wrist tablet's View; every tab uses it (test round 9 Oct: one colour for all, no green in Feature)
const ACCENT_CONSTRAIN := ACCENT_SKETCH ## (the Constrain tab is gone: constraints are sketch tools, set apart as a group below)
const GROUP_DRAW := Color(0.31, 0.77, 1.00) ## cyan: lines, curves, shapes
const GROUP_CONSTRAIN := Color(0.96, 0.69, 0.25) ## amber: constraints and dimensions
const GROUP_EDIT := Color(0.78, 0.55, 0.98) ## violet: trim, offset (and later convert)
const EDIT_IDS := ["trim", "offset"]
const FEATURE_GROUPS := [ ## the Feature tab's groups, each a colour and the tools it holds (in FEATURE_TOOLS order within it)
	["create", "Create", Color(0.31, 0.77, 1.00), ["extrude", "revolve", "loft", "sweep", "helix", "create_plane"]],
	["refine", "Refine", Color(0.96, 0.69, 0.25), ["fillet", "chamfer", "shell", "mirror"]],
	["combine", "Modify", Color(0.78, 0.55, 0.98), ["pattern", "boolean", "merge", "split"]],
	["gears", "Gears", Color(0.55, 0.85, 0.45), ["gear", "rack", "bevel_gear"]],
]
const ACCENT_FEATURE := ACCENT_SKETCH
const ACCENT_MODIFY := ACCENT_SKETCH
const ACCENT_INSPECT := Color(0.95, 0.50, 0.65) ## rose

## id, label, icon. DIDSA-CAD's SketchTool enum, in the order the flat app shows
## them for the tools that are built here (Slot, Ellipse, Ellipse Arc, Spline and
## Text come later, as further pages of the same row).
const SKETCH_TOOLS := [
	["select", "Select", "tool_select"],
	["line", "Line", "tool_line"],
	["rectangle", "Rectangle", "tool_rectangle"],
	["circle", "Circle", "tool_circle"],
	["arc", "Arc", "tool_arc"],
	["polygon", "Polygon", "tool_polygon"],
	["point", "Point", "tool_point"],
	["slot", "Slot", "tool_slot"],
	["ellipse", "Ellipse", "tool_ellipse"],
	["ellipse_arc", "Ellipse Arc", "tool_ellipse_arc"],
	["spline", "Spline", "tool_spline"],
	["text", "Text", "tool_text"],
	["trim", "Trim", "tool_trim"],
	["offset", "Offset", "tool_offset"],
]
## DIDSA-CAD's ribbon constraint chips plus its Dimensions tool.
const CONSTRAIN_TOOLS := [
	["dimension", "Dimension", "tool_dimension"],
	["horizontal", "Horizontal", "tool_horizontal"],
	["vertical", "Vertical", "tool_vertical"],
	["parallel", "Parallel", "tool_parallel"],
	["perpendicular", "Perpendicular", "tool_perpendicular"],
	["coincident", "Coincident", "tool_coincident"],
]
## DIDSA-CAD's feature picker: "Sketch-based" and "Modify" sections.
const FEATURE_TOOLS := [
	["extrude", "Extrude", "tool_extrude"],
	["revolve", "Revolve", "tool_revolve"],
	["fillet", "Fillet", "tool_fillet"],
	["chamfer", "Chamfer", "tool_chamfer"],
	["shell", "Shell", "tool_shell"],
	["mirror", "Mirror", "tool_mirror"],
	["create_plane", "Plane", "feat_plane"],
	["loft", "Loft", "tool_loft"],
	["sweep", "Sweep", "tool_sweep"],
	["helix", "Helix", "tool_helix"],
	["pattern", "Pattern", "tool_pattern"],
	["boolean", "Boolean", "tool_boolean"],
	["merge", "Merge", "tool_merge"],
	["split", "Split", "tool_split"],
	["gear", "Gear", "tool_gear"],
	["rack", "Rack", "tool_rack"],
	["bevel_gear", "Bevel", "tool_bevel_gear"],
]

## The Modify category (direct editing: no sketch, works on faces and bodies of any solid, an imported STEP part included).
const MODIFY_TOOLS := [
	["move_face", "Move Face", "tool_move_face"],
	["delete_face", "Delete Face", "tool_delete_face"],
	["move_body", "Move Body", "tool_move_body"],
	["scale_body", "Scale Body", "tool_scale_body"],
	["delete_body", "Delete Body", "tool_delete_body"],
]

const HINTS := {
	"select": "Aim at a point, line or curve and pull the trigger to pick it (again to let go; pick several for more options). What you can do with it appears below: Length, Radius, Horizontal, Fix, Construction, Delete...",
	"line": "Point at the sheet and pull the trigger to place the start, then the end. Each end starts the next line.",
	"rectangle": "Pick two opposite corners.",
	"circle": "Pick the centre, then a point on the circle.",
	"arc": "Pick the centre, the start, then the end (counter-clockwise).",
	"polygon": "Pick the centre, then the first corner. Sides are set below.",
	"point": "Pull the trigger to place a point.",
	"slot": "Pick the two end centres, then a point as far from the centre line as the slot's half width.",
	"ellipse": "Pick the centre, the end of the long axis, then a point as far from that axis as the short radius.",
	"ellipse_arc": "Pick the centre, the end of the long axis, a point for the short radius, then the start and the end of the arc (counter-clockwise).",
	"spline": "Pick the points the curve passes through, in order, then press Finish spline.",
	"text": "Press Text and type the words, choose the font and size below, then pick where it goes.",
	"trim": "Aim at the part of a line, circle or arc to cut away (it must cross another line or curve) and pull the trigger. A line's end can also be pulled out to the next crossing.",
	"offset": "Set the distance below, then pick a line or arc: a copy is made that far to one side (Reverse for the other).",
	"dimension": "Pick a line, a circle, or two points, then pick the value to type it.",
	"horizontal": "Pick a line to make it horizontal.",
	"vertical": "Pick a line to make it vertical.",
	"parallel": "Pick two lines.",
	"perpendicular": "Pick two lines.",
	"coincident": "Pick two points, or a point and a line or circle.",
	"extrude": "Draw a closed shape, set Boss or Cut and the depth, then Apply.",
	"revolve": "Draw a closed shape and a line to spin it about. Press Axis, pull the trigger on that line, set Boss or Cut and the angle, then Apply.",
	"fillet": "Pick edges on the part, set the radius, then Apply.",
	"chamfer": "Pick edges on the part, set the distance, then Apply.",
	"shell": "Pick the faces to open (the part is hollowed behind them), set the wall thickness, then Apply.",
	"create_plane": "Aim at a flat face or a plane and pull the trigger, set the offset, then Make plane. The new plane can be picked to sketch on.",
	"loft": "Pick a line of each of two or more sketches (each on its own plane): the loft goes through those sketches in order. Add guide, then pull the trigger on the curves of an earlier sketch that run through every section, and Done, to shape the surface between them (any number of guides). Set Boss or Cut, then Apply.",
	"helix": "Set the radius, an optional taper (an end radius or an angle), and the segments (pitch and turns each, e.g. tight end coils), then Apply: a helix curve to sweep along. Pull the trigger on a plane or flat face first to stand it there.",
	"sweep": "With the profile sketch open, pick the lines of the path in an earlier sketch, in order. Set Boss or Cut, then Apply.",
	"pattern": "Pick the body to repeat, choose Rectangular or Circular, a direction (X, Y, Z, or a line of an earlier sketch), the count and spacing, then Apply.",
	"boolean": "Pick the body to change (the target), press Pick tool and pick the body to use on it, choose Subtract or Common, then Apply.",
	"merge": "Pick two or more bodies to join into one, then Apply.",
	"split": "Pick the body to split, press Pick plane and pick a plane or flat face, then Apply.",
	"move_face": "Pick the faces to push or pull (of one body), set the distance, then Apply.",
	"delete_face": "Pick fillet, chamfer, hole or boss faces to delete; the gap is healed. A plain wall can't be deleted. Then Apply.",
	"move_body": "Pick the body to move, set X / Y / Z (negative goes the other way), then Apply.",
	"scale_body": "Pick the body to scale, set the factor, then Apply.",
	"delete_body": "Pick the bodies to delete, then Apply.",
	"mirror": "Aim at a flat face or a reference plane and pull the trigger: the part is mirrored across it.",
	"gear": "Set the module, teeth and width (and a bore for the shaft), then Apply: a new gear body. Pull the trigger on a plane or flat face first to stand it there. The line below gives the centre distance to a partner gear.",
	"rack": "Set the module, teeth and width, then Apply: a new rack body. Pull the trigger on a plane or flat face first to stand it there.",
	"bevel_gear": "Set the module, teeth, width and pitch cone angle (or the mate's teeth, then Cone from mate for a 90 degree pair), and a bore, then Apply: a new bevel gear body.",
}


static func register(reg, handler: Object) -> void:
	## The Sketch tab holds all three kinds of sketch tool, each set apart as a group with its own colour:
	## draw (Select and the line / curve / shape tools), constrain (constraints and Dimension) and edit (Trim, Offset).
	_category(reg, handler, "sketch", "Sketch", "cat_sketch", ACCENT_SKETCH, [])
	reg.add_group("sketch", "draw", "Draw", GROUP_DRAW)
	reg.add_group("sketch", "constrain", "Constrain", GROUP_CONSTRAIN)
	reg.add_group("sketch", "edit", "Edit", GROUP_EDIT)
	for t in SKETCH_TOOLS:
		if not EDIT_IDS.has(t[0]):
			_tool(reg, handler, "sketch", t, "draw")
	for t in CONSTRAIN_TOOLS:
		_tool(reg, handler, "sketch", t, "constrain")
	for t in SKETCH_TOOLS:
		if EDIT_IDS.has(t[0]):
			_tool(reg, handler, "sketch", t, "edit")
	## The Feature tab sets its tools apart the same way: Create (from a sketch), Refine (edges, faces) and Modify (bodies).
	reg.add_category("feature", "Feature", "cat_feature", ACCENT_FEATURE)
	for g in FEATURE_GROUPS:
		reg.add_group("feature", g[0], g[1], g[2])
		for tool_id in g[3]: # in the group's own order
			for t in FEATURE_TOOLS:
				if t[0] == tool_id:
					_tool(reg, handler, "feature", t, g[0])
	_category(reg, handler, "modify", "Modify", "cat_modify", ACCENT_MODIFY, MODIFY_TOOLS)


static func _category(reg, handler: Object, id: String, label: String, icon: String, accent: Color, tools: Array) -> void:
	reg.add_category(id, label, icon, accent)
	for t in tools:
		_tool(reg, handler, id, t, "")


static func _tool(reg, handler: Object, category_id: String, t: Array, group: String) -> void:
	reg.add_tool(category_id, t[0], t[1], t[2], Callable(), {
		"kind": "mode",
		"on_activate": Callable(handler, "tool_activated").bind(t[0]),
		"on_deactivate": Callable(handler, "tool_deactivated").bind(t[0]),
		"hint": HINTS.get(t[0], ""),
		"group": group,
	})
