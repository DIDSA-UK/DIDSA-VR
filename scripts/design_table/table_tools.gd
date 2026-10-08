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
## itself when a category has more than six tools (tool_pager.gd).

const TabletRegistry := preload("res://scripts/ui/tablet_registry.gd")

const ACCENT_SKETCH := Color(0.31, 0.77, 1.00) ## cyan, the same as the wrist tablet's View
const ACCENT_CONSTRAIN := Color(0.96, 0.69, 0.25) ## amber
const ACCENT_FEATURE := Color(0.40, 0.90, 0.60) ## green
const ACCENT_MODIFY := Color(0.78, 0.55, 0.98) ## violet
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
	["pattern", "Pattern", "tool_pattern"],
	["boolean", "Boolean", "tool_boolean"],
	["merge", "Merge", "tool_merge"],
	["split", "Split", "tool_split"],
]

const HINTS := {
	"select": "Pick points, lines and curves. Pick again to let go. Options for what you picked appear below.",
	"line": "Point at the sheet and pull the trigger to place the start, then the end. Each end starts the next line.",
	"rectangle": "Pick two opposite corners.",
	"circle": "Pick the centre, then a point on the circle.",
	"arc": "Pick the centre, the start, then the end (counter-clockwise).",
	"polygon": "Pick the centre, then the first corner. Sides are set below.",
	"point": "Pull the trigger to place a point.",
	"slot": "Pick the two end centres, then a point as far from the centre line as the slot's half width.",
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
	"loft": "Pick a line of each of two or more sketches (each on its own plane): the loft goes through those sketches in order. Set Boss or Cut, then Apply.",
	"sweep": "With the profile sketch open, pick the lines of the path in an earlier sketch, in order. Set Boss or Cut, then Apply.",
	"pattern": "Pick the body to repeat, choose Rectangular or Circular, a direction (X, Y, Z, or a line of an earlier sketch), the count and spacing, then Apply.",
	"boolean": "Pick the body to change (the target), press Pick tool and pick the body to use on it, choose Subtract or Common, then Apply.",
	"merge": "Pick two or more bodies to join into one, then Apply.",
	"split": "Pick the body to split, press Pick plane and pick a plane or flat face, then Apply.",
	"mirror": "Aim at a flat face or a reference plane and pull the trigger: the part is mirrored across it.",
}


static func register(reg, handler: Object) -> void:
	_category(reg, handler, "sketch", "Sketch", "cat_sketch", ACCENT_SKETCH, SKETCH_TOOLS)
	_category(reg, handler, "constrain", "Constrain", "cat_constrain", ACCENT_CONSTRAIN, CONSTRAIN_TOOLS)
	_category(reg, handler, "feature", "Feature", "cat_feature", ACCENT_FEATURE, FEATURE_TOOLS)


static func _category(reg, handler: Object, id: String, label: String, icon: String, accent: Color, tools: Array) -> void:
	reg.add_category(id, label, icon, accent)
	for t in tools:
		reg.add_tool(id, t[0], t[1], t[2], Callable(), {
			"kind": "mode",
			"on_activate": Callable(handler, "tool_activated").bind(t[0]),
			"on_deactivate": Callable(handler, "tool_deactivated").bind(t[0]),
			"hint": HINTS.get(t[0], ""),
		})
