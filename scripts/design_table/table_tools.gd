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
	["line", "Line", "tool_line"],
	["rectangle", "Rectangle", "tool_rectangle"],
	["circle", "Circle", "tool_circle"],
	["arc", "Arc", "tool_arc"],
	["polygon", "Polygon", "tool_polygon"],
	["point", "Point", "tool_point"],
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
	["fillet", "Fillet", "tool_fillet"],
	["chamfer", "Chamfer", "tool_chamfer"],
]

const HINTS := {
	"line": "Point at the sheet and pull the trigger to place the start, then the end. Each end starts the next line.",
	"rectangle": "Pick two opposite corners.",
	"circle": "Pick the centre, then a point on the circle.",
	"arc": "Pick the centre, the start, then the end (counter-clockwise).",
	"polygon": "Pick the centre, then the first corner. Sides are set below.",
	"point": "Pull the trigger to place a point.",
	"dimension": "Pick a line, a circle, or two points, then pick the value to type it.",
	"horizontal": "Pick a line to make it horizontal.",
	"vertical": "Pick a line to make it vertical.",
	"parallel": "Pick two lines.",
	"perpendicular": "Pick two lines.",
	"coincident": "Pick two points, or a point and a line or circle.",
	"extrude": "Draw a closed shape, set Boss or Cut and the depth, then Apply.",
	"fillet": "Pick edges on the part, set the radius, then Apply.",
	"chamfer": "Pick edges on the part, set the distance, then Apply.",
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
