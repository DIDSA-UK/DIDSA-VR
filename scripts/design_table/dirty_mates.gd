extends RefCounted
## "Mates are flagged dirty after an edit and need redoing; a part that is also open elsewhere is flagged dirty" (the design
## table brief). A part's mates name faces and edges by their index in the part's CURRENT geometry (DIDSA-CAD's SubShapeRef), and the
## backend re-resolves them only when it solves — it has no revision or stale flag of its own. So when the table changes a part, the
## client flags EVERY arena instance of that part (they all changed: they share one definition) with the node meta "mates_dirty",
## and shows a small warning badge on each. While flagged a part is not steered by its mates (mates_tool.gd checks the meta) and is
## not an anchor others are solved against; "Enforce mates" (enforce_button.gd) re-solves them and clears the flags.
##
## The flags live on the nodes. A save writes the flagged parts' occurrence ids as the VR-only extra `vr_stale_mates` (main.gd,
## stale_mate_occurrences(); the flat app ignores keys it does not know), and opening that file flags them again (restore_stale_mates()),
## so "this part's mates need redoing" survives a save and open. Loading anything else starts with no flags: a reload re-reads every
## mate fresh from the backend, which is exactly the check the flag stands in for.

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const BADGE_NAME := "DirtyBadge"
const BADGE_WORLD_SIZE := 0.045 ## metres across


static func is_dirty(node: Node) -> bool:
	return is_instance_valid(node) and bool(node.get_meta("mates_dirty", false))


static func mark(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	node.set_meta("mates_dirty", true)
	if node.get_node_or_null(BADGE_NAME) == null and node is MeshInstance3D:
		_add_badge(node as MeshInstance3D)


static func clear(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	node.set_meta("mates_dirty", false)
	var badge := node.get_node_or_null(BADGE_NAME)
	if badge != null:
		node.remove_child(badge)
		badge.queue_free()


static func dirty_nodes(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group("grabbable_parts").filter(func(n): return is_dirty(n))


static func clear_all(tree: SceneTree) -> int:
	var nodes := dirty_nodes(tree)
	for n in nodes:
		clear(n)
	return nodes.size()


static func _add_badge(part: MeshInstance3D) -> void:
	## A warning mark that always faces you and shows through the part, sized in world metres whatever the model's scale.
	var tokens: Resource = load("res://ui/didsa_ui_theme.tres")
	var sprite := Sprite3D.new()
	sprite.name = BADGE_NAME
	sprite.texture = UiIcons.texture("warn", 64)
	sprite.modulate = tokens.warn
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.no_depth_test = true
	sprite.render_priority = 6
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var scale_x: float = maxf(part.global_transform.basis.get_scale().x, 0.000001)
	sprite.pixel_size = BADGE_WORLD_SIZE / 64.0 / scale_x
	sprite.position = part.get_aabb().get_center()
	part.add_child(sprite)
