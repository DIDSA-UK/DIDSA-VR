extends SceneTree
## T6 (docs/test-report-30-oct-plan.md): the pure tables behind the selection drawer. selection_actions.gd: every row of the plan's "what each selection offers"
## (edges on one body and on two, a planar face, a curved face, two faces, a lone vertex, vertex + edge / face, a body, a finished sketch with and without a closed
## shape, a feature, a surface body's faces), the default (first) action, disabled actions kept with their reason. selection_breadcrumbs.gd: the chain for a face
## (Face > Body > made by Extrude 2 > Part), the "#N" suffix rule of graph.py base_feature_id(), several entities ("3 edges", the shared rungs only), a sketch
## entity, and a long chain folding its middle into "...". Pure: no scene, no backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_selection_actions.gd  (see tests/README.md)

const SA := preload("res://scripts/design_table/selection_actions.gd")
const SB := preload("res://scripts/design_table/selection_breadcrumbs.gd")


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func ids(list: Array) -> Array:
	return list.map(func(a) -> String: return str(a["id"]))


func by_id(list: Array, id: String) -> Dictionary:
	for a in list:
		if a["id"] == id:
			return a
	return {}


func edge(body: String, i: int) -> Dictionary:
	return {"kind": "edge", "body_id": body, "index": i}


func face(body: String, i: int, planar: bool) -> Dictionary:
	return {"kind": "face", "body_id": body, "index": i, "planar": planar}


func _initialize() -> void:
	check("nothing selected, no actions", SA.actions_for([]).is_empty())

	# --- edges
	var one_edge := SA.actions_for([edge("b1", 0)])
	check("one edge: Fillet first (the default), Chamfer, Create plane", ids(one_edge) == ["fillet", "chamfer", "create_plane"] and one_edge[0]["enabled"] and SA.default_action([edge("b1", 0)])["id"] == "fillet")
	check("...Fillet and Chamfer are in the Refine group, Create plane in Create", one_edge[0]["group"] == "refine" and one_edge[1]["group"] == "refine" and one_edge[2]["group"] == "create")
	var three := SA.actions_for([edge("b1", 0), edge("b1", 1), edge("b1", 2)])
	check("three edges on one body: Fillet and Chamfer on, Create plane off (it takes one edge)", by_id(three, "fillet")["enabled"] and by_id(three, "chamfer")["enabled"] and not by_id(three, "create_plane")["enabled"] and by_id(three, "create_plane")["reason"] != "")
	var two_bodies := SA.actions_for([edge("b1", 0), edge("b2", 0)])
	check("edges on two bodies: Fillet / Chamfer disabled with 'Pick edges on one body', and still listed", not by_id(two_bodies, "fillet")["enabled"] and by_id(two_bodies, "fillet")["reason"] == "Pick edges on one body" and not by_id(two_bodies, "chamfer")["enabled"] and ids(two_bodies).has("fillet"))
	check("...and the default skips the disabled ones", SA.default_action([edge("b1", 0), edge("b2", 0)]).get("id", "") == "")
	var surface_edge := SA.actions_for([edge("s1", 0)], {"surface_bodies": ["s1"]})
	check("an edge of a surface body: Fillet / Chamfer disabled (no solid)", not by_id(surface_edge, "fillet")["enabled"] and "solid" in by_id(surface_edge, "fillet")["reason"])

	# --- faces
	var planar := SA.actions_for([face("b1", 3, true)])
	check("one planar face: New sketch on face first, Move face, Create plane, Fillet, Chamfer, Shell, Delete face", ids(planar) == ["sketch_on_face", "move_face", "create_plane", "fillet", "chamfer", "shell", "delete_face"] and SA.default_action([face("b1", 3, true)])["id"] == "sketch_on_face")
	check("...Extrude face only when the backend has it", not ids(planar).has("extrude_face") and ids(SA.actions_for([face("b1", 3, true)], {"has_face_extrude": true})).has("extrude_face"))
	var curved := SA.actions_for([face("b1", 4, false)])
	check("one curved face: Move face, Fillet, Chamfer, Shell, Delete face; no sketch and no plane (not flat)", ids(curved) == ["move_face", "fillet", "chamfer", "shell", "delete_face"])
	var two_faces := SA.actions_for([face("b1", 3, true), face("b1", 5, true)])
	check("two flat faces: Create plane (midplane), Move faces, Shell, Delete faces", ids(two_faces) == ["create_plane", "move_faces" if false else "move_face", "shell", "delete_face"] and by_id(two_faces, "create_plane")["enabled"] and by_id(two_faces, "move_face")["text"] == "Move faces" and by_id(two_faces, "delete_face")["text"] == "Delete faces")
	var two_mixed := SA.actions_for([face("b1", 3, true), face("b1", 4, false)])
	check("a flat and a curved face: Create plane (midplane) is off with a reason", not by_id(two_mixed, "create_plane")["enabled"])
	var three_faces := SA.actions_for([face("b1", 1, true), face("b1", 2, true), face("b1", 3, true)])
	check("three faces: no Create plane, Shell (open these) and Move / Delete faces", not ids(three_faces).has("create_plane") and ids(three_faces).has("shell") and ids(three_faces).has("move_face"))
	var cross_faces := SA.actions_for([face("b1", 1, true), face("b2", 2, true)])
	check("faces on two bodies: Move / Shell / Delete are disabled with a reason", not by_id(cross_faces, "move_face")["enabled"] and not by_id(cross_faces, "shell")["enabled"] and not by_id(cross_faces, "delete_face")["enabled"])
	var surface_face := SA.actions_for([face("s1", 0, true)], {"surface_bodies": ["s1"]})
	check("a surface body's face: Fillet, Chamfer and Shell are left out (no solid), Move face and Delete face stay", not ids(surface_face).has("fillet") and not ids(surface_face).has("chamfer") and not ids(surface_face).has("shell") and ids(surface_face).has("move_face") and ids(surface_face).has("delete_face"))

	# --- vertices and mixtures
	var lone := SA.actions_for([{"kind": "vertex", "body_id": "b1", "index": 2}])
	check("a lone vertex: Create plane is off with 'Pick an edge or face as well'", ids(lone) == ["create_plane"] and not lone[0]["enabled"] and lone[0]["reason"] == "Pick an edge or face as well")
	check("a vertex and an edge: Create plane is on", SA.actions_for([{"kind": "vertex", "body_id": "b1", "index": 2}, edge("b1", 0)])[0]["enabled"])
	check("a vertex and a face: Create plane is on", SA.actions_for([{"kind": "vertex", "body_id": "b1", "index": 2}, face("b1", 0, true)])[0]["enabled"])
	check("an edge and a face: nothing a plane can use", not SA.actions_for([edge("b1", 0), face("b1", 0, true)])[0]["enabled"])

	# --- bodies
	var body := SA.actions_for([{"kind": "body", "body_id": "b1"}])
	check("a body: Move body, Scale body, Mirror, Pattern, Shell, Delete body", ids(body) == ["move_body", "scale_body", "mirror", "pattern", "shell", "delete_body"])
	check("a surface body: Shell is off with a reason", not by_id(SA.actions_for([{"kind": "body", "body_id": "s1"}], {"surface_bodies": ["s1"]}), "shell")["enabled"])

	# --- sketches and features
	var sketch := SA.actions_for([{"kind": "sketch", "feature_id": "sk1", "closed": true}])
	check("a finished sketch with a closed shape: Edit sketch first, Extrude, Revolve, Sweep, Loft, Delete, all on", ids(sketch) == ["edit_sketch", "extrude", "revolve", "sweep", "loft", "delete_feature"] and sketch.all(func(a) -> bool: return a["enabled"]))
	var open_sketch := SA.actions_for([{"kind": "sketch", "feature_id": "sk1", "closed": false}])
	check("a sketch with no closed shape: Extrude and the rest are off with 'No closed shape', Edit sketch and Delete stay on", not by_id(open_sketch, "extrude")["enabled"] and by_id(open_sketch, "extrude")["reason"] == "No closed shape" and by_id(open_sketch, "edit_sketch")["enabled"] and by_id(open_sketch, "delete_feature")["enabled"])
	var feature := SA.actions_for([{"kind": "feature", "feature_id": "f1", "type": "extrude"}])
	check("a feature: Edit, Roll back to here, Suppress, Delete", ids(feature) == ["edit_feature", "rollback", "suppress", "delete_feature"] and by_id(feature, "suppress")["text"] == "Suppress")
	check("...a suppressed one offers Unsuppress", by_id(SA.actions_for([{"kind": "feature", "feature_id": "f1", "suppressed": true}]), "suppress")["text"] == "Unsuppress")
	check("the Part rung: Return to arena, Appearance, Properties", ids(SA.part_actions()) == ["return_arena", "appearance", "properties"])

	# --- breadcrumbs
	check("base_feature_id strips a #N suffix (graph.py), and leaves a plain id", SB.base_feature_id("ext2#3") == "ext2" and SB.base_feature_id("ext2") == "ext2" and SB.base_feature_id("") == "")
	var ctx := {"body_names": {"ext2": "Body 1"}, "feature_names": {"ext2": "Extrude 2"}, "part_name": "Bracket"}
	var rungs := SB.chain([face("ext2", 11, true)], ctx)
	check("a face: Face 12 > Body 1 > made by Extrude 2 > Part \"Bracket\"", rungs.map(func(r) -> String: return r["text"]) == ["Face 12", "Body 1", "made by Extrude 2", "Part \"Bracket\""])
	var split := SB.chain([face("ext2#1", 0, true)], ctx)
	check("a body from a split (ext2#1) is still made by Extrude 2", split.map(func(r) -> String: return r["text"]).has("made by Extrude 2"))
	check("a tap on the Body rung selects the body, on the feature rung selects the feature, on Part selects nothing", rungs[1]["select"] == [{"kind": "body", "body_id": "ext2"}] and rungs[2]["select"][0]["kind"] == "feature" and rungs[3]["select"].is_empty())
	var many := SB.chain([edge("ext2", 0), edge("ext2", 3), edge("ext2", 5)], ctx)
	check("three edges: the first rung reads '3 edges' and the shared rungs above it appear", many[0]["text"] == "3 edges" and many[1]["text"] == "Body 1")
	var across := SB.chain([edge("ext2", 0), edge("other", 3)], ctx)
	check("edges on two bodies share no body rung: '2 edges' then the part", across.map(func(r) -> String: return r["text"]) == ["2 edges", "Part \"Bracket\""])
	var mixed := SB.chain([edge("ext2", 0), face("ext2", 3, true)], ctx)
	check("mixed kinds read '2 items'", mixed[0]["text"] == "2 items")
	var line := SB.chain([{"kind": "line", "id": "l4", "label": "4"}], {"sketch_name": "Sketch 2", "part_name": "Bracket"})
	check("a sketch entity: Line 4 > Sketch 2 > Part", line.map(func(r) -> String: return r["text"]) == ["Line 4", "Sketch 2", "Part \"Bracket\""])
	var dim := SB.chain([{"kind": "dimension", "id": "k1", "label": "Length 40 mm"}], {"sketch_name": "Sketch 2", "part_name": "Bracket"})
	check("a dimension: Length 40 mm > Sketch 2 > Part", dim.map(func(r) -> String: return r["text"]) == ["Length 40 mm", "Sketch 2", "Part \"Bracket\""])
	var no_feature := SB.chain([face("imp1", 0, true)], {"part_name": "P"})
	check("a body whose feature is not known has no 'made by' rung", no_feature.map(func(r) -> String: return r["text"]) == ["Face 1", "Body", "Part \"P\""])
	var long := []
	for i in 8:
		long.append({"id": "r%d" % i, "text": "R%d" % i, "level": "x", "select": []})
	var fold := SB.folded(long)
	check("a chain longer than five keeps its first and last rungs and folds the middle into '...'", fold["shown"].size() == 3 and fold["shown"][0]["text"] == "R0" and fold["shown"][1]["text"] == "..." and fold["shown"][2]["text"] == "R7" and fold["hidden"].size() == 6)
	check("a short chain is shown whole", SB.folded(long.slice(0, 4))["hidden"].is_empty() and SB.folded(long.slice(0, 4))["shown"].size() == 4)
	quit()
