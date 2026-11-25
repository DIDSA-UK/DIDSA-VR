extends "res://scripts/tree/occurrence_tree_view.gd"
## The Assembly Tree window (Milestone 3, V-7, Phases A and B): the World scope of the one occurrence tree component (C6, scripts/tree/occurrence_tree_view.gd,
## which has everything the tree does). Its root is the loaded assembly (main.current_root_part_id()), its rows stand for the world's parts
## (RoomRegistry.world_parts, through main.tree_row_nodes), and its bar adds Room. It remembers its open rows per document and dims what is outside an open room.
## The tablet's Assembly Tree button opens it; main.gd keeps it current (mark_stale, document_replaced, note_document_changed).


func _init() -> void:
	scope = Scope.world()
