extends RefCounted
## A generic undo/redo history. A "command" is just a label plus two
## Callables — undo() reverts an action, redo() reapplies it — pushed right
## after the action itself already happened (the initial doing is the
## caller's job; this only remembers how to reverse and redo it).
##
## Meant to be shared by whatever pushes reversible actions: controller.gd
## (part moves via grip-drag or laser-select), two_hand_model.gd (whole-model
## drags, scale presets, Fit, Home) and later tools (hide/show, isolate,
## etc. — push a command exactly the same way: capture the before state,
## perform the action, push {label, undo, redo}). One instance, created by
## main.gd, handed to whoever needs it.
##
## A fresh push clears the redo stack, same as any standard undo/redo history:
## once you've done something new, "redo" no longer means anything.

signal changed ## something was pushed, undone or redone: the document is no longer as it was saved or loaded

var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []


func push(label: String, undo: Callable, redo: Callable) -> void:
	_undo_stack.append({"label": label, "undo": undo, "redo": redo})
	_redo_stack.clear()
	changed.emit()


func can_undo() -> bool:
	return not _undo_stack.is_empty()


func can_redo() -> bool:
	return not _redo_stack.is_empty()


func undo_label() -> String:
	return _undo_stack.back()["label"] if can_undo() else ""


func redo_label() -> String:
	return _redo_stack.back()["label"] if can_redo() else ""


func history_labels() -> Array:
	## Newest first, for the tablet's history list: what Undo would reverse next,
	## then the one before that, and so on.
	var out := []
	for i in range(_undo_stack.size() - 1, -1, -1):
		out.append(_undo_stack[i]["label"])
	return out


func redo_labels() -> Array:
	## Next redo first.
	var out := []
	for i in range(_redo_stack.size() - 1, -1, -1):
		out.append(_redo_stack[i]["label"])
	return out


func undo() -> void:
	if _undo_stack.is_empty():
		return
	var entry: Dictionary = _undo_stack.pop_back()
	(entry["undo"] as Callable).call()
	_redo_stack.append(entry)
	changed.emit()


func redo() -> void:
	if _redo_stack.is_empty():
		return
	var entry: Dictionary = _redo_stack.pop_back()
	(entry["redo"] as Callable).call()
	_undo_stack.append(entry)
	changed.emit()


func clear() -> void:
	## Call this whenever whatever the history points at might be about to
	## disappear (e.g. the model is being replaced) — an undo/redo Callable
	## touching a freed node would error.
	_undo_stack.clear()
	_redo_stack.clear()
