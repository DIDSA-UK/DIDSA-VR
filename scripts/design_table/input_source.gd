extends RefCounted
## Hit sizes per input source for the sketcher (parity plan S7). Every size is in world metres around the pointing ray, divided by the sheet's scale where it is used.
## "controller" is what the sketcher always used. "hand" is for hand tracking (DIDSA-VR item 10): larger, because a pinch ray shakes more. Nothing selects "hand" until
## hand tracking lands (`TableEditor.set_input_source("hand")` is the one switch).
##   pick  - the reach in which an entity is picked (was PICK_RADIUS)
##   ghost - the reach of a dimension candidate (was GHOST_RADIUS)
##   glyph - half the side of the square a constraint glyph can be pointed at in (was GLYPH_HIT_MM)

const DEFAULT := "controller"
const SOURCES := {
	"controller": {"pick": 0.014, "ghost": 0.030, "glyph": 0.007},
	"hand": {"pick": 0.024, "ghost": 0.045, "glyph": 0.012},
}


static func value(source: String, key: String) -> float:
	var row: Dictionary = SOURCES.get(source, SOURCES[DEFAULT])
	return float(row[key])
