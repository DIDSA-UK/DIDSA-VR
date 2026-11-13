extends RefCounted
## The Assembly Tree's logic with no nodes and no network (V-7 = phase T1 of docs/feature-tree-review-2026-11-11.md), so it can be unit tested and, in phase T2,
## shared by the world, room and table trees: rows from the backend's OccurrenceResponse dicts, the instance names ("Bolt <2>"), the occurrence-id path of a
## row (what selects the right node when a sub-assembly is placed twice: B1), the state icon of a row, and which actions a row gets and why one is greyed.
##
## A row: {id, name, base_name, override, named, resolved_part_id, children (null = not fetched), expanded, fixed, backend_hidden, suppressed, missing, path, status}
##   id         the occurrence id within its parent Part ("" for the root row)
##   path       the occurrence ids from the scope's root down to this row (empty for the root row): group_index.gd's `group_path` of the nodes it stands for
##   status     the backend's constraint status for it ("fixed" / "fully_constrained" / "under_constrained" / "over_constrained"), or "" when not known
##   missing    the occurrence's file could not be found (no resolved Part)

const KIND_ROOT := "root"
const KIND_TOP := "top" ## a placed occurrence of the root
const KIND_NESTED := "nested" ## a placed occurrence inside a sub-assembly (editing it edits every placement of that sub-assembly)
const KIND_MISSING := "missing"


static func rows_from_occurrences(occurrences: Array, parent_path: Array) -> Array:
	## OccurrenceResponse-shaped dicts -> rows (children not fetched yet). `parent_path`: the path of the row these hang under.
	var rows: Array = []
	for occ in occurrences:
		var resolved := str(occ.get("resolved_part_id", "")) if occ.get("resolved_part_id") != null else ""
		var id := str(occ.get("id", ""))
		var override_name = occ.get("name_override")
		var named: bool = override_name != null and str(override_name) != ""
		var label: String = str(override_name) if named else "Occurrence %s" % id.substr(0, 8)
		rows.append({
			"id": id,
			"name": label,
			"base_name": label,
			"override": named, # the user gave this placement its own name: never renamed "<n>"
			"named": named, # false = still the placeholder; the Part's own name replaces it once read
			"resolved_part_id": resolved,
			"children": null,
			"expanded": false,
			"fixed": bool(occ.get("fixed", false)),
			"backend_hidden": bool(occ.get("hidden", false)),
			"suppressed": bool(occ.get("suppressed", false)),
			"missing": resolved == "",
			"path": parent_path + [id],
			"status": "",
		})
	return rows


static func apply_instance_names(rows: Array) -> void:
	## Siblings that place the same Part, with no name of their own, are told apart SOLIDWORKS style: "Bolt <1>", "Bolt <2>" (owner, 11 Nov). A Part placed
	## once keeps its plain name. Run again whenever the Part names arrive.
	var by_part := {}
	for row in rows:
		if bool(row.get("override", false)) or str(row.get("resolved_part_id", "")) == "":
			continue
		by_part[row["resolved_part_id"]] = (by_part.get(row["resolved_part_id"], []) as Array) + [row]
	for part_id in by_part:
		var group: Array = by_part[part_id]
		if group.size() < 2:
			for row in group:
				row["name"] = str(row["base_name"])
			continue
		for i in group.size():
			group[i]["name"] = "%s <%d>" % [str(group[i]["base_name"]), i + 1]


static func kind_of(row: Dictionary) -> String:
	if str(row.get("id", "")) == "":
		return KIND_ROOT
	if bool(row.get("missing", false)):
		return KIND_MISSING
	return KIND_TOP if (row.get("path", []) as Array).size() <= 1 else KIND_NESTED


static func state_icon(row: Dictionary) -> String:
	## The one icon a row wears (the flat app's rules): pin = fixed, lock = fully constrained, open lock = under-constrained, warning = over-constrained or a
	## missing file, "" = free and unmated. The backend's `fixed` flag decides when the constraint status is not known.
	if bool(row.get("missing", false)):
		return "warning"
	match str(row.get("status", "")):
		"fixed":
			return "pin"
		"fully_constrained":
			return "lock"
		"under_constrained":
			return "lock_open"
		"over_constrained":
			return "warning"
	return "pin" if bool(row.get("fixed", false)) else ""


static func state_hint(row: Dictionary, dof: int = -1) -> String:
	if bool(row.get("missing", false)):
		return "missing file"
	if bool(row.get("suppressed", false)):
		return "suppressed"
	match str(row.get("status", "")):
		"fixed":
			return "fixed"
		"fully_constrained":
			return "fully constrained"
		"under_constrained":
			return "under-constrained" + (" (%d DOF)" % dof if dof >= 0 else "")
		"over_constrained":
			return "over-constrained"
	return "fixed" if bool(row.get("fixed", false)) else ""


static func set_note(rows: Array, row: Dictionary) -> String:
	## M5: what a row says about its rigid set (`row["rigid_set"]`, the backend's id = the set's lead occurrence): the lead "moves with N other part(s)", the rest
	## "moves with <lead name>"; "" outside a set. `rows` are the rows of the same level.
	var set_id := str(row.get("rigid_set", ""))
	if set_id == "":
		return ""
	if set_id == str(row.get("id", "")):
		var others := 0
		for r in rows:
			if str(r.get("rigid_set", "")) == set_id and r != row:
				others += 1
		return "moves with %d other part%s" % [others, "" if others == 1 else "s"] if others > 0 else ""
	for r in rows:
		if str(r.get("id", "")) == set_id:
			return "moves with %s" % str(r.get("name", "the lead"))
	return "moves with other parts"


static func set_colour_index(rows: Array, set_id: String) -> int:
	## M5: one colour slot per rigid set at a level (the set's place among the level's sets sorted by id); -1 outside a set.
	if set_id == "":
		return -1
	var ids: Array = []
	for r in rows:
		var sid := str(r.get("rigid_set", ""))
		if sid != "" and not ids.has(sid):
			ids.append(sid)
	ids.sort()
	return ids.find(set_id)


static func actions_for(row: Dictionary, ctx: Dictionary = {}) -> Array:
	## The bottom bar's actions for a selected row: [{id, label, enabled, why}] in display order. `ctx`: {hidden: bool (every node under the row is hidden in
	## the view), has_nodes: bool (the row stands for something on screen), room_text: String ("Room" / "Close room" / "Cancel", "" = none),
	## used: int (how many times the row's owner Part is placed: > 1 warns on Delete)}. A greyed action says why.
	var kind := kind_of(row)
	var placed := kind == KIND_TOP or kind == KIND_NESTED
	var has_nodes := bool(ctx.get("has_nodes", false))
	var out: Array = []
	out.append({"id": "fix", "label": "Float" if bool(row.get("fixed", false)) else "Fix", "enabled": placed,
		"why": "" if placed else ("the assembly itself can't be fixed" if kind == KIND_ROOT else "its file is missing")})
	out.append({"id": "hide", "label": "Show" if bool(ctx.get("hidden", false)) else "Hide", "enabled": has_nodes,
		"why": "" if has_nodes else "nothing of it is on screen"})
	out.append({"id": "isolate", "label": "Isolate", "enabled": has_nodes, "why": "" if has_nodes else "nothing of it is on screen"})
	out.append({"id": "rename", "label": "Rename", "enabled": placed, "why": "" if placed else "only a placed part has its own name"})
	var room_text := str(ctx.get("room_text", ""))
	if room_text != "":
		out.append({"id": "room", "label": room_text, "enabled": true, "why": ""})
	out.append({"id": "delete", "label": "Delete", "enabled": placed or kind == KIND_MISSING,
		"why": "" if placed or kind == KIND_MISSING else "the assembly itself can't be deleted here"})
	return out


static func delete_warning(row: Dictionary, used: int) -> String:
	## What the second press of Delete says besides the mates: deleting an occurrence INSIDE a sub-assembly edits that sub-assembly's Part, so every placement
	## of it changes (B3). "" for a top-level row.
	if kind_of(row) != KIND_NESTED or used < 2:
		return ""
	return "edits all %d placements of its assembly" % used


static func path_key(path: Array) -> String:
	return "/".join(PackedStringArray(path.map(func(x) -> String: return str(x))))


static func find_row(rows: Array, path: Array) -> Dictionary:
	## The row whose path is `path`, searching the fetched part of the tree ({} if not found or not fetched).
	for row in rows:
		var p: Array = row.get("path", [])
		if p == path:
			return row
		if p.size() < path.size() and path.slice(0, p.size()) == p and row.get("children") != null:
			var inner := find_row(row["children"], path)
			if not inner.is_empty():
				return inner
	return {}


static func merge_children(old_rows: Array, fresh: Array) -> Array:
	## A refreshed level keeps what the user had open: a fresh row takes `expanded` and the fetched `children` of the old row with the same id, and its Part name.
	var by_id := {}
	for row in old_rows:
		by_id[str(row["id"])] = row
	for row in fresh:
		var old: Dictionary = by_id.get(str(row["id"]), {})
		if old.is_empty():
			continue
		if str(old.get("resolved_part_id", "")) == str(row["resolved_part_id"]):
			row["expanded"] = old.get("expanded", false)
			row["children"] = old.get("children")
			if bool(old.get("named", false)) and not bool(row["named"]):
				row["base_name"] = old["base_name"]
				row["name"] = old["base_name"]
				row["named"] = true
	return fresh


static func ancestors_paths(path: Array) -> Array:
	## [[], [a], [a, b]] for the path [a, b, c]: the rows to expand so the last one shows.
	var out: Array = []
	for i in path.size():
		out.append(path.slice(0, i))
	return out
