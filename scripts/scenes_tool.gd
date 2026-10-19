extends Node
## Scenes in VR (DIDSA-CAD `docs/scenes-scope.md`, S2): named arrangements of an assembly (moved, hidden and painted parts, and
## a viewpoint) that change nothing in the model. A scene is shown on the SANDBOX (mates_tool.gd's Relax mates): showing one
## relaxes the mates and arranges the parts as the scene says, so everything moved, hidden or painted while it shows is on screen
## only, and Back to default (Return parts) puts the model back exactly as it is.
##
##   Show          relaxes, then poses every placed instance by the scene (scene_compose.gd, the backend reference's copy), hides
##                 what it hides, and puts its appearance overrides in the Appearance tool's temporary layer (the top layer).
##                 The scene's viewpoint, if it has one and View is on, turns and places the model so you look at it from there,
##                 keeping the scale you have (it never zooms).
##   Save as new   POST /parts/{root}/scenes: what is on screen now, as overrides against the real model (capture()).
##   Update scene  PATCH the shown scene's overrides (its name, section planes and viewpoint are kept).
##   Back to default  Return parts; if what is on screen differs from the shown scene it asks first: Update / Discard / Stay
##                 (back_to_default() returns "ask"; request_back() / request_show() leave the question in `pending_ask`, answer()
##                 answers it). The plain sandbox (no scene shown) goes back without asking, as it always has.
##
## Where nodes come from: the assembly glb is FLAT (DIDSA-CAD `encode_assembly_glb`: one node per placed instance, sub-assemblies
## included, each at its pose in the root's frame, mm; `instance_path` names it, pattern copies included). A sub-assembly with no
## geometry of its own is a plain Node3D (mesh_identity.gd tags those too). `scopes` gives the glb scenes: the world's (its root
## Part) and each open Assembly Room's (the room's Part, D6: a scene lives in its own assembly).
##
## What capture() writes: going down the tree, a node's local transform as it is now (its pose now in its parent's pose now) is
## compared with its real one; a different one is an override. A sub-assembly without geometry has no pose of its own on screen:
## it moved if all of its parts moved alike (a group grab), else it stayed with its parent. The root's own content can't move in
## a scene (the backend refuses a transform at path ""): its moves are counted and left out. Hidden comes from what the shown scene
## hid; appearance from the temporary layer (paint while a scene shows); a paint on every copy of a pattern or every placement of a
## part has no scene form and is left out (counted).
##
## Not here yet: a scene's section planes are kept (an Update never sends them) but not drawn in VR.

signal scenes_changed() ## the list, or which scene shows, changed
signal message(text: String)

const Compose := preload("res://scripts/appearance/scene_compose.gd")
const Rule := preload("res://scripts/appearance/appearance_rule.gd")

const API_PREFIX := "/document"
const EPS_MM := 0.01 ## a move smaller than this (in either direction) is no move
const EPS_BASIS := 0.0001

var api = null
var mates_tool: Node = null ## the sandbox
var appearance_tool: Node = null ## the temporary layer and the model (for real hidden flags)
var scopes: Callable = Callable() ## () -> [{root: Part id, scene: Node3D (the glb's root), view: Node3D or null (what a viewpoint moves)}]
var camera: Node3D = null ## the head, for a viewpoint
var use_viewpoint := true ## Show also applies the scene's viewpoint

var scope_root := "" ## the assembly the page works in ("" = the first scope: the world)
var shown: Dictionary = {} ## the scene showing: {root, scene (the backend's dict)}; empty = the default
var last_capture: Dictionary = {} ## the last capture()'s report: {overrides, root_moves, skipped_paint}
var pending_ask: Dictionary = {} ## {action: "back" | "show", scene_id}: what waits on Update / Discard / Stay (the page shows the question)

var _lists: Dictionary = {} ## root -> [scene dicts] as the backend last listed them
var _hidden_by_scene: Dictionary = {} ## node -> its visible flag before the scene hid / showed it
var _collision_off: Dictionary = {} ## CollisionObject3D -> its collision_layer, while its part is hidden
var _baseline: Dictionary = {} ## node -> where the shown scene (or the last save) put it: a group move is measured from here
var _busy := false


func _ready() -> void:
	if mates_tool != null and mates_tool.has_signal("sandbox_changed"):
		mates_tool.sandbox_changed.connect(_on_sandbox_changed)


func is_busy() -> bool:
	return _busy


func forget() -> void:
	## The model is being replaced: nothing shown, nothing remembered (the list is read again when the page asks).
	_restore_visibility()
	_hidden_by_scene.clear()
	_collision_off.clear()
	_baseline.clear()
	_lists.clear()
	pending_ask = {}
	scope_root = ""
	if not shown.is_empty():
		shown = {}
		scenes_changed.emit()


func current_root() -> String:
	if scope_root != "":
		return scope_root
	var all := _scopes()
	return str(all[0]["root"]) if not all.is_empty() else ""


func scenes_of(root: String = "") -> Array:
	return (_lists.get(root if root != "" else current_root(), []) as Array).duplicate()


func shown_id() -> String:
	return str((shown.get("scene", {}) as Dictionary).get("id", "")) if not shown.is_empty() else ""


func shown_name() -> String:
	return str((shown.get("scene", {}) as Dictionary).get("name", "")) if not shown.is_empty() else ""


func refresh(root: String = "") -> Array:
	## Reads the scope's scenes (a coroutine).
	var r := root if root != "" else current_root()
	if api == null or r == "":
		return []
	var got: Dictionary = await api.request(HTTPClient.METHOD_GET, API_PREFIX + "/parts/%s/scenes" % r, null)
	if got.get("ok", false) and got.get("json") is Array:
		_lists[r] = got["json"]
	scenes_changed.emit()
	return scenes_of(r)


# --- the nodes of a scope ------------------------------------------------------------------------------------------

func _scopes() -> Array:
	return scopes.call() if scopes.is_valid() else []


func _scope(root: String) -> Dictionary:
	for s in _scopes():
		if str(s["root"]) == root:
			return s
	return {}


func nodes_of(root: String) -> Dictionary:
	## instance path -> node, for every placed instance in the scope's glb.
	var out := {}
	var scope := _scope(root)
	var scene: Node = scope.get("scene")
	if scene == null or not is_instance_valid(scene):
		return out
	for node in [scene] + scene.get_children():
		if node is Node3D and node.has_meta("instance_path"):
			out[str(node.get_meta("instance_path"))] = node
	return out


func _home_of(node: Node3D) -> Transform3D:
	## Where the node really is: its sandbox home while relaxed, else where it is now.
	if mates_tool != null and mates_tool.relaxed and mates_tool.has_method("sandbox_home_of"):
		var h = mates_tool.sandbox_home_of(node)
		if h is Transform3D:
			return h
	return node.transform


static func _present_ancestor(path: String, by_path: Dictionary) -> Variant:
	## The nearest ancestor path that has a node (null for the root's own content).
	var probe = Compose.parent_path(path)
	while probe != null and not by_path.has(probe):
		probe = Compose.parent_path(probe)
	return probe


func real_nodes(root: String) -> Array:
	## compose_scene's nodes for the scope as it really is: each instance's real local transform, real hidden flag and bodies.
	var by_path := nodes_of(root)
	var out: Array = []
	for path in by_path:
		var node: Node3D = by_path[path]
		var home := _home_of(node)
		var anc = _present_ancestor(path, by_path)
		var local := home if anc == null else _home_of(by_path[anc]).affine_inverse() * home
		out.append({"path": path, "local": Compose.from_transform(local), "hidden": real_hidden(root, path), "bodies": []})
	return out


func real_hidden(root: String, path: String) -> bool:
	## Whether the model hides the instance (an occurrence on its way down is hidden). False when the model isn't read.
	if appearance_tool == null:
		return false
	var parts: Dictionary = (appearance_tool.model() as Dictionary).get("parts", {})
	var at := root
	for segment in Rule.split_path(path):
		var occ: Dictionary = ((parts.get(at, {}) as Dictionary).get("occurrences", {}) as Dictionary).get(Rule.base_segment(str(segment)), {})
		if occ.is_empty():
			return false
		if bool(occ.get("hidden", false)):
			return true
		at = str(occ.get("part_id", ""))
	return false


# --- Show ----------------------------------------------------------------------------------------------------------

func show_scene(scene_id: String, choice: String = "") -> String:
	## Shows a listed scene of the current scope (a coroutine). Returns "shown", "ask" (what is on screen is unsaved: answer with
	## choice "update" / "discard" / "stay") or an error message.
	var root := current_root()
	var scene: Dictionary = {}
	for s in scenes_of(root):
		if str(s.get("id", "")) == scene_id:
			scene = s
	if scene.is_empty():
		return "That scene is not in the list (refresh it)."
	if choice == "" and scene_unsaved():
		return "ask"
	if choice == "stay":
		return "stay"
	if choice == "update" and not shown.is_empty():
		var saved := await update_scene()
		if not saved["ok"]:
			return str(saved["error"])
	await _apply(root, scene)
	return "shown"


func _apply(root: String, scene: Dictionary) -> void:
	_restore_visibility()
	var by_path := nodes_of(root)
	if appearance_tool != null:
		await appearance_tool.ensure_loaded(root)
	var nodes := real_nodes(root)
	var composed := Compose.compose_scene(nodes, {"parts": {}}, root, scene)
	# The sandbox: every part's home is where it really is; the arrangement is the scene's poses.
	var home := {}
	if mates_tool != null:
		for node in get_tree().get_nodes_in_group("grabbable_parts"):
			if is_instance_valid(node):
				home[node] = _home_of(node)
	for path in by_path:
		home[by_path[path]] = _home_of(by_path[path])
	var arrangement := {}
	for path in by_path:
		var node: Node3D = by_path[path]
		var want := Compose.to_transform(composed[path]["world"])
		want.basis = want.basis.scaled(node.transform.basis.get_scale()) # (glb nodes are unscaled; kept if one ever isn't)
		arrangement[node] = want
	for node in home:
		if not arrangement.has(node):
			arrangement[node] = home[node] # what moved in the sandbox before goes home: the scene starts from the real model
	if mates_tool != null:
		mates_tool.arrange_in_sandbox(home, arrangement)
	else:
		for node in arrangement:
			(node as Node3D).transform = arrangement[node]
	_baseline.clear()
	for path in by_path:
		_baseline[by_path[path]] = (by_path[path] as Node3D).transform
	# Hidden: only what the scene decides (a scene `hidden` on the instance or above it); the rest shows as the app shows it.
	var decided := _hidden_decisions(scene)
	var missing := 0
	for o in scene.get("overrides", []):
		if o.get("hidden") == false and o.get("body_id") == null and o.get("face") == null and not by_path.has(str(o["path"])):
			missing += 1
	for path in by_path:
		var d = _decision(path, decided)
		if d == null:
			continue
		_set_hidden(by_path[path], bool(d))
	# Appearance: the scene's overrides are the top layer.
	if appearance_tool != null:
		var layer: Array = []
		for o in scene.get("overrides", []):
			if o.get("appearance") is Dictionary and not (o["appearance"] as Dictionary).is_empty():
				layer.append(appearance_tool._record_from_wire(o))
		appearance_tool._temporary[root] = layer
		appearance_tool.repaint(by_path.values(), str(appearance_tool.world_root))
	shown = {"root": root, "scene": scene.duplicate(true)}
	if use_viewpoint and scene.get("viewpoint") is Dictionary:
		_apply_viewpoint(root, scene["viewpoint"])
	var note := ""
	if missing > 0:
		note = " %d part(s) it shows are hidden in the model and not loaded (Settings: show hidden parts)." % missing
	if not (scene.get("unresolved", []) as Array).is_empty():
		note += " %d override(s) no longer match the assembly." % (scene["unresolved"] as Array).size()
	if not (scene.get("section_planes", []) as Array).is_empty():
		note += " Its section plane shows in the flat app only."
	message.emit("Showing scene \"%s\". Moves and paint are temporary until you Update it.%s" % [str(scene.get("name", "")), note])
	scenes_changed.emit()


static func _hidden_decisions(scene: Dictionary) -> Dictionary:
	var out := {}
	for o in scene.get("overrides", []):
		if o.get("hidden") != null and o.get("body_id") == null and o.get("face") == null:
			out[str(o["path"])] = bool(o["hidden"])
	return out


static func _decision(path: String, decided: Dictionary) -> Variant:
	var probe = path
	while probe != null:
		if decided.has(probe):
			return decided[probe]
		probe = Compose.parent_path(probe)
	return null


func _set_hidden(node: Node3D, hide: bool) -> void:
	if not _hidden_by_scene.has(node):
		_hidden_by_scene[node] = node.visible
	node.visible = not hide
	for child in node.get_children():
		if child is CollisionObject3D: # (a hidden part can't be lasered or grabbed)
			if hide and not _collision_off.has(child):
				_collision_off[child] = (child as CollisionObject3D).collision_layer
				(child as CollisionObject3D).collision_layer = 0
			elif not hide and _collision_off.has(child):
				(child as CollisionObject3D).collision_layer = _collision_off[child]
				_collision_off.erase(child)


func _restore_visibility() -> void:
	for node in _hidden_by_scene:
		if is_instance_valid(node):
			(node as Node3D).visible = _hidden_by_scene[node]
	_hidden_by_scene.clear()
	for body in _collision_off:
		if is_instance_valid(body):
			(body as CollisionObject3D).collision_layer = _collision_off[body]
	_collision_off.clear()


func is_hidden_by_scene(node: Node) -> bool:
	return _hidden_by_scene.has(node) and not (node as Node3D).visible


# --- the viewpoint -------------------------------------------------------------------------------------------------

static func _v(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func viewpoint_pose(viewpoint: Dictionary, current: Transform3D, head: Transform3D) -> Transform3D:
	## Where the model goes so the head looks at it from the viewpoint: the model's `up` turned to the world's up, the eye's
	## horizontal direction to the target turned to where the head faces, the eye at the head. The scale is the one it has.
	var s := current.basis.get_scale().x
	var up_m := _v(viewpoint.get("up", [0, 1, 0])).normalized()
	var look_m := _v(viewpoint["target"]) - _v(viewpoint["eye"])
	var h_m := (look_m - up_m * look_m.dot(up_m))
	if h_m.length() < 1e-9: # looking straight down or up: any horizontal will do
		h_m = up_m.cross(Vector3.RIGHT if absf(up_m.x) < 0.9 else Vector3.FORWARD)
	h_m = h_m.normalized()
	var fwd := -head.basis.z
	var h_w := Vector3(fwd.x, 0.0, fwd.z)
	h_w = h_w.normalized() if h_w.length() > 1e-6 else Vector3.FORWARD
	var a := Basis(h_m, up_m, h_m.cross(up_m))
	var b := Basis(h_w, Vector3.UP, h_w.cross(Vector3.UP))
	var basis := (b * a.transposed()).scaled_local(Vector3.ONE * s)
	return Transform3D(basis, head.origin - basis * _v(viewpoint["eye"]))


func _apply_viewpoint(root: String, viewpoint: Dictionary) -> void:
	var view: Node3D = _scope(root).get("view")
	if view == null or camera == null or not is_instance_valid(view):
		return
	var scene: Node3D = _scope(root).get("scene")
	# The viewpoint is in the scene Part's frame (the glb's root); `view` carries it (the world's AssemblyRoot).
	var inner := scene.global_transform.affine_inverse() * view.global_transform if scene != null else Transform3D.IDENTITY
	var pose := viewpoint_pose(viewpoint, view.global_transform * inner.affine_inverse(), camera.global_transform)
	view.global_transform = pose * inner


func current_viewpoint(root: String = "") -> Variant:
	## The head's view of the scope now, as a scene viewpoint in its frame (mm): eye at the head, target 1 m ahead, the world's up.
	var scene: Node3D = _scope(root if root != "" else current_root()).get("scene")
	if scene == null or camera == null:
		return null
	var inv := scene.global_transform.affine_inverse()
	var eye := inv * camera.global_transform.origin
	var target := inv * (camera.global_transform.origin - camera.global_transform.basis.z)
	var up := (inv.basis * Vector3.UP).normalized()
	if eye.distance_to(target) < 1e-6:
		return null
	return {"eye": [eye.x, eye.y, eye.z], "target": [target.x, target.y, target.z], "up": [up.x, up.y, up.z]}


# --- capture: what is on screen, as a scene -------------------------------------------------------------------------

static func _same(a: Transform3D, b: Transform3D) -> bool:
	if a.origin.distance_to(b.origin) > EPS_MM:
		return false
	var ao := a.basis.orthonormalized()
	var bo := b.basis.orthonormalized()
	for i in 3:
		if (ao[i] - bo[i]).length() > EPS_BASIS:
			return false
	return true


static func _unscaled(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis.orthonormalized(), t.origin)


func capture(root: String = "") -> Dictionary:
	## The overrides that make a scene of what is on screen now in the scope, against the real model:
	## {overrides: [...], root_moves: n (root content moved: not saveable), skipped_paint: n}.
	var r := root if root != "" else current_root()
	var by_path := nodes_of(r)
	var paths: Array = by_path.keys()
	paths.sort_custom(func(a, b) -> bool: return str(a).count("/") < str(b).count("/") or (str(a).count("/") == str(b).count("/") and str(a) < str(b)))
	var actual := {} # path -> its pose now (in the scope's frame)
	var whole := {} # path -> {transform?, hidden?}
	var root_moves := 0
	var has_mesh := {}
	for path in paths:
		has_mesh[path] = by_path[path] is MeshInstance3D
	for path in paths:
		var node: Node3D = by_path[path]
		var home := _unscaled(_home_of(node))
		var anc = _present_ancestor(path, by_path)
		var real_local := home if anc == null else _unscaled(_home_of(by_path[anc])).affine_inverse() * home
		var parent_now: Transform3D = Transform3D.IDENTITY if anc == null else actual[anc]
		var now: Transform3D
		if path == "":
			# The root's own content stays where it is in a scene: a move of it is counted (and left out), and what it places is
			# measured from where it really is.
			if has_mesh[path] and not _same(_unscaled(node.transform), home):
				root_moves += 1
			actual[path] = home
			continue
		if has_mesh[path]:
			now = _unscaled(node.transform)
		else:
			now = _meshless_now(path, paths, by_path)
		actual[path] = now
		var local_now: Transform3D = now if anc == null else parent_now.affine_inverse() * now
		if not _same(local_now, real_local):
			whole[path] = {"transform": Compose.from_transform(local_now)}
	# Hidden: what the scene shown hid or showed (nothing in VR hides a part on its own yet), kept as the scene said.
	if not shown.is_empty() and str(shown["root"]) == r:
		for path in _hidden_decisions(shown["scene"]):
			if path == "":
				continue
			var entry: Dictionary = whole.get(path, {})
			entry["hidden"] = _hidden_decisions(shown["scene"])[path]
			whole[path] = entry
	var overrides: Array = []
	var appearance_of_whole := {}
	var subshape: Array = []
	var skipped := 0
	if appearance_tool != null:
		for rec in (appearance_tool._temporary.get(r, []) as Array):
			if rec.has("scope") or rec.has("pattern_id") or rec.has("part_id"):
				skipped += 1
				continue
			if rec.has("body_id") or rec.has("face"):
				var o := {"path": str(rec.get("path", "")), "body_id": str(rec.get("body_id", (rec.get("face", {}) as Dictionary).get("body_id", ""))), "appearance": rec["appearance"]}
				if rec.get("face") is Dictionary:
					o["face"] = {"body_id": str(rec["face"]["body_id"]), "shape_type": "face", "index": int(rec["face"]["index"])}
				subshape.append(o)
			else:
				appearance_of_whole[str(rec.get("path", ""))] = rec["appearance"]
	for path in appearance_of_whole:
		var entry: Dictionary = whole.get(path, {})
		entry["appearance"] = appearance_of_whole[path]
		whole[path] = entry
	var keys: Array = whole.keys()
	keys.sort()
	for path in keys:
		var o := {"path": path}
		o.merge(whole[path])
		overrides.append(o)
	overrides += subshape
	last_capture = {"overrides": overrides, "root_moves": root_moves, "skipped_paint": skipped}
	return last_capture


func _baseline_of(node: Node3D) -> Transform3D:
	return _baseline[node] if _baseline.has(node) else _home_of(node)


func _meshless_now(path: String, paths: Array, by_path: Dictionary) -> Transform3D:
	## A sub-assembly with no geometry of its own sits where the scene put it, and moves with its parts if every one of them moved
	## alike since (a group grab); if they moved differently, each part moved on its own.
	var node: Node3D = by_path[path]
	var stayed := _unscaled(node.transform)
	var delta = null
	var prefix := path + "/" if path != "" else ""
	for other in paths:
		if other == path or not (by_path[other] is MeshInstance3D) or not str(other).begins_with(prefix):
			continue
		var d: Transform3D = _unscaled(by_path[other].transform) * _unscaled(_baseline_of(by_path[other])).affine_inverse()
		if delta == null:
			delta = d
		elif not _same(d, delta):
			return stayed
	if delta == null:
		return stayed
	return delta * stayed


static func _normalised(overrides: Array) -> Dictionary:
	## Overrides by (path, body, face), each with its fields, for comparing two scenes (transforms within the tolerance).
	var out := {}
	for o in overrides:
		var face = o.get("face")
		var key := "%s|%s|%s" % [str(o.get("path", "")), str(o.get("body_id", "") if o.get("body_id") != null else ""), str(int(face["index"])) if face is Dictionary else ""]
		var rec := {}
		if o.get("transform") is Dictionary:
			rec["transform"] = Compose.to_transform(Compose.pose(o["transform"]))
		if o.get("hidden") != null:
			rec["hidden"] = bool(o["hidden"])
		if o.get("appearance") is Dictionary and not (o["appearance"] as Dictionary).is_empty():
			rec["appearance"] = o["appearance"]
		if not rec.is_empty():
			out[key] = rec
	return out


static func same_overrides(a: Array, b: Array) -> bool:
	var na := _normalised(a)
	var nb := _normalised(b)
	if na.size() != nb.size():
		return false
	for key in na:
		if not nb.has(key):
			return false
		var x: Dictionary = na[key]
		var y: Dictionary = nb[key]
		if x.has("transform") != y.has("transform") or (x.has("transform") and not _same(x["transform"], y["transform"])):
			return false
		if x.get("hidden") != y.get("hidden"):
			return false
		if not _same_appearance(x.get("appearance", {}), y.get("appearance", {})):
			return false
	return true


static func _same_appearance(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if (a[k] is float or a[k] is int) and (b[k] is float or b[k] is int):
			if absf(float(a[k]) - float(b[k])) > 1e-6:
				return false
		elif str(a[k]).to_upper() != str(b[k]).to_upper():
			return false
	return true


func has_unsaved() -> bool:
	## What is on screen differs from the shown scene (or, with none shown, from the default) in the current scope.
	if mates_tool != null and not mates_tool.relaxed:
		return false
	var got: Array = capture()["overrides"]
	if shown.is_empty() or str(shown["root"]) != current_root():
		return not got.is_empty()
	return not same_overrides(got, (shown["scene"] as Dictionary).get("overrides", []))


func scene_unsaved() -> bool:
	## A scene shows and what is on screen differs from it: what Back to default and Show ask about (moves in the plain sandbox,
	## with no scene shown, go back without asking, as they always have).
	return not shown.is_empty() and has_unsaved()


# --- Save as new / Update / Delete -----------------------------------------------------------------------------------

func save_as_new(scene_name: String, with_viewpoint: bool = true) -> Dictionary:
	## POST what is on screen as a new scene of the current scope; it becomes the shown one. {ok, error, scene}. A coroutine.
	var root := current_root()
	if api == null or root == "":
		return {"ok": false, "error": "no backend configured"}
	var got := capture(root)
	var body := {"name": scene_name, "overrides": got["overrides"]}
	var vp = current_viewpoint(root) if with_viewpoint else null
	if vp != null:
		body["viewpoint"] = vp
	_busy = true
	var r: Dictionary = await api.request(HTTPClient.METHOD_POST, API_PREFIX + "/parts/%s/scenes" % root, body)
	_busy = false
	if not r.get("ok", false) or not (r.get("json") is Dictionary):
		return {"ok": false, "error": str(r.get("error", "the backend refused the scene"))}
	var scene: Dictionary = r["json"]
	var list: Array = _lists.get(root, [])
	list.append(scene)
	_lists[root] = list
	shown = {"root": root, "scene": scene.duplicate(true)}
	_commit_baseline(root)
	message.emit(_saved_text("Saved scene \"%s\"" % str(scene.get("name", "")), got))
	scenes_changed.emit()
	return {"ok": true, "error": "", "scene": scene}


func update_scene(with_viewpoint: bool = false) -> Dictionary:
	## PATCH the shown scene's overrides with what is on screen (and its viewpoint, if asked). {ok, error, scene}. A coroutine.
	if shown.is_empty():
		return {"ok": false, "error": "no scene is showing"}
	var root := str(shown["root"])
	var got := capture(root)
	var body := {"overrides": got["overrides"]}
	if with_viewpoint:
		body["viewpoint"] = current_viewpoint(root)
	_busy = true
	var r: Dictionary = await api.request(HTTPClient.METHOD_PATCH, API_PREFIX + "/parts/%s/scenes/%s" % [root, shown_id()], body)
	_busy = false
	if not r.get("ok", false) or not (r.get("json") is Dictionary):
		return {"ok": false, "error": str(r.get("error", "the backend refused the update"))}
	var scene: Dictionary = r["json"]
	var list: Array = _lists.get(root, [])
	for i in list.size():
		if str(list[i].get("id", "")) == str(scene.get("id", "")):
			list[i] = scene
	shown = {"root": root, "scene": scene.duplicate(true)}
	_commit_baseline(root)
	message.emit(_saved_text("Updated scene \"%s\"" % str(scene.get("name", "")), got))
	scenes_changed.emit()
	return {"ok": true, "error": "", "scene": scene}


func delete_scene(scene_id: String) -> Dictionary:
	var root := current_root()
	_busy = true
	var r: Dictionary = await api.request(HTTPClient.METHOD_DELETE, API_PREFIX + "/parts/%s/scenes/%s" % [root, scene_id], null)
	_busy = false
	if not r.get("ok", false):
		return {"ok": false, "error": str(r.get("error", "the backend refused the delete"))}
	_lists[root] = (_lists.get(root, []) as Array).filter(func(s) -> bool: return str(s.get("id", "")) != scene_id)
	if shown_id() == scene_id:
		shown = {}
	scenes_changed.emit()
	return {"ok": true, "error": ""}


func _commit_baseline(root: String) -> void:
	## After a save: a sub-assembly without geometry takes the pose its parts' group move gave it, and every node's pose now is the
	## baseline the next group move is measured from.
	var by_path := nodes_of(root)
	var paths: Array = by_path.keys()
	for path in paths:
		var node: Node3D = by_path[path]
		if not (node is MeshInstance3D) and path != "":
			var t := _meshless_now(path, paths, by_path)
			node.transform = Transform3D(t.basis.scaled(node.transform.basis.get_scale()), t.origin)
	for path in paths:
		_baseline[by_path[path]] = (by_path[path] as Node3D).transform


static func _saved_text(head: String, got: Dictionary) -> String:
	var text := "%s (%d change%s)." % [head, (got["overrides"] as Array).size(), "" if (got["overrides"] as Array).size() == 1 else "s"]
	if int(got["root_moves"]) > 0:
		text += " The assembly's own parts can't move in a scene: left out."
	if int(got["skipped_paint"]) > 0:
		text += " %d paint(s) on every copy / placement left out: paint them one by one." % int(got["skipped_paint"])
	return text


# --- Back to default -----------------------------------------------------------------------------------------------

func back_to_default(choice: String = "") -> String:
	## Return parts. "ask" when what is on screen is unsaved (answer with choice "update" / "discard" / "stay"); "returned"; "stay";
	## or an error message. A coroutine.
	if choice == "" and scene_unsaved():
		return "ask"
	if choice == "stay":
		return "stay"
	if choice == "update" and not shown.is_empty():
		var saved := await update_scene()
		if not saved["ok"]:
			return str(saved["error"])
	if mates_tool != null and mates_tool.relaxed:
		await mates_tool.return_parts()
	else:
		_on_sandbox_changed(false)
	return "returned"


func request_back() -> String:
	## Back to default from a button: when it has to ask, the question waits in `pending_ask` for answer(). A coroutine.
	var r := await back_to_default()
	if r == "ask":
		pending_ask = {"action": "back"}
		message.emit("This scene has unsaved changes: Update, Discard or Stay (Scenes page).")
		scenes_changed.emit()
	return r


func request_show(scene_id: String) -> String:
	var r := await show_scene(scene_id)
	if r == "ask":
		pending_ask = {"action": "show", "scene_id": scene_id}
		message.emit("This scene has unsaved changes: Update, Discard or Stay (Scenes page).")
		scenes_changed.emit()
	elif r != "shown":
		message.emit(r)
	return r


func answer(choice: String) -> String:
	## Update / Discard / Stay for the question waiting in `pending_ask`. A coroutine.
	var ask := pending_ask
	pending_ask = {}
	if ask.is_empty():
		return ""
	var r := ""
	if str(ask["action"]) == "back":
		r = await back_to_default(choice)
	else:
		r = await show_scene(str(ask["scene_id"]), choice)
	scenes_changed.emit()
	return r


func _on_sandbox_changed(on: bool) -> void:
	if on:
		return
	_restore_visibility()
	_baseline.clear()
	if not shown.is_empty():
		shown = {}
		scenes_changed.emit()
