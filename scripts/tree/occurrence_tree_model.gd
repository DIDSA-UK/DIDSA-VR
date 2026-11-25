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
##   state      (rows built from GET /parts/{id}/assembly-tree) the one state slot of the spec, section 5: missing / cycle / broken / over_constrained / near / unsaved /
##              under_constrained / fixed / fully_constrained / none; state_icon and state_hint use it when it is there, and the older `status` + `fixed` rules when not
##
## The second half of this file is DIDSA-CAD docs/assembly-tree/spec.md (the contract both clients follow), as pure functions over the endpoint's response dicts:
## display names, grouping, the state slot, problem counts, visible_rows (section 7) and reveal_keys (section 8). tests/occurrence_tree_model.gd runs every case of
## tests/fixtures/assembly_tree_vectors.json (a byte-for-byte copy of the file DIDSA-CAD generates) against them.

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
		var label: String = str(override_name) if named else "Component %d" % (rows.size() + 1) # (spec section 3 rule 1.4; the Part's name replaces it once read)
		rows.append({
			"id": id,
			"name": label,
			"base_name": label,
			"override": named, # the user gave this placement its own name: never renamed "<n>"
			"named": named, # false = still the placeholder; the Part's own name replaces it once read
			"placeholder": not named, # base_name is "Component N", not a name: it is never given an "<n>" suffix
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
		if bool(row.get("override", false)) or str(row.get("resolved_part_id", "")) == "" or bool(row.get("placeholder", false)):
			continue # (a placeholder "Component N" is not numbered "<n>": it is not a name yet)
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
	if row.has("state"):
		return state_icon_for(str(row["state"]))
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
	if row.has("state") and not bool(row.get("suppressed", false)):
		return state_hint_for(str(row["state"]), dof)
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
				row["placeholder"] = false
	return fresh


static func ancestors_paths(path: Array) -> Array:
	## [[], [a], [a, b]] for the path [a, b, c]: the rows to expand so the last one shows.
	var out: Array = []
	for i in path.size():
		out.append(path.slice(0, i))
	return out


# =====================================================================================================================================================
# The assembly-tree spec (DIDSA-CAD docs/assembly-tree/spec.md): names, grouping, the state slot, problem counts, visible rows, reveal.
# A "node" is one dict of the endpoint's response (section 1); the response itself is the root. Nothing here touches a scene or the network.
# =====================================================================================================================================================

const STATES := ["missing", "cycle", "broken", "over_constrained", "near", "unsaved", "under_constrained", "fixed", "fully_constrained", "none"] ## section 5, most severe first (the contract's order). The client-only state "pending" (a Float whose fresh status has not arrived) is not in it and ranks last
const GROUP_MIN := 4 ## section 4: this many siblings that share an instance key become one group row

static var _uuid_re: RegEx = null
static var _hex_re: RegEx = null


# --- names (section 3) ---------------------------------------------------------------------------------------------------------------------------------

static func looks_generated(text: String) -> bool:
	## Empty or only spaces; a UUID with or without dashes; or 16+ hex digits with an optional 1-6 letter prefix and "-" / "_".
	var t := text.strip_edges()
	if t == "":
		return true
	if _uuid_re == null:
		_uuid_re = RegEx.create_from_string("^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$")
		_hex_re = RegEx.create_from_string("^(?:[A-Za-z]{1,6}[-_])?[0-9a-fA-F]{16,}$")
	return _uuid_re.search(t) != null or _hex_re.search(t) != null


static func file_stem(external_ref) -> String:
	## The last "/" segment of the stored file reference without its last extension ("lib/v1.2/clip.step.didsa" -> "clip.step"; ".washer" keeps its dot); "" when none.
	if external_ref == null:
		return ""
	var seg := str(external_ref).get_slice("/", str(external_ref).count("/"))
	var dot := seg.rfind(".")
	if dot > 0:
		seg = seg.substr(0, dot)
	return seg


static func _has_text(value) -> bool:
	return value != null and str(value).strip_edges() != ""


static func instance_key(node: Dictionary) -> String:
	## Siblings without a name override that place the same Part (or, when missing, the same file) share one key; "" = none.
	if _has_text(node.get("name_override")):
		return ""
	var resolved = node.get("resolved_part_id")
	if resolved != null and str(resolved) != "":
		return "p:" + str(resolved)
	var ref = node.get("external_ref")
	if str(node.get("kind", "")) == "missing" and ref != null and str(ref) != "":
		return "f:" + str(ref)
	return ""


static func sibling_names(siblings: Array) -> Array:
	## One {label, base, key} per sibling, in order. `base` is the name before any "<n>"; `key` the instance key ("" = none).
	var keys: Array = siblings.map(func(n): return instance_key(n))
	var members := {} ## instance key -> indices
	for i in siblings.size():
		if keys[i] != "":
			if not members.has(keys[i]):
				members[keys[i]] = []
			(members[keys[i]] as Array).append(i)
	var group_base := {}
	for k in members:
		var idx: Array = members[k]
		var first: Dictionary = siblings[idx[0]]
		var base := ""
		var pn = first.get("part_name")
		if pn != null and not looks_generated(str(pn)):
			base = str(pn)
		else:
			for i in idx:
				var stem := file_stem(siblings[i].get("external_ref"))
				if not looks_generated(stem):
					base = stem
					break
		if base == "":
			keys = keys.map(func(x): return "" if x == k else x) # neither a usable Part name nor file name: no instance key, each is "Component N"
		else:
			group_base[k] = base
	var out: Array = []
	var counter := {}
	for i in siblings.size():
		var n: Dictionary = siblings[i]
		var key: String = keys[i]
		if _has_text(n.get("name_override")):
			out.append({"label": str(n["name_override"]), "base": str(n["name_override"]), "key": ""})
		elif key == "" or not group_base.has(key):
			out.append({"label": "Component %d" % (i + 1), "base": "Component %d" % (i + 1), "key": ""})
		else:
			var base: String = group_base[key]
			var size := (members[key] as Array).size()
			counter[key] = int(counter.get(key, 0)) + 1
			out.append({"label": base if size < 2 else "%s <%d>" % [base, counter[key]], "base": base, "key": key})
	return out


# --- the state slot (section 5) --------------------------------------------------------------------------------------------------------------------------

static func state_of(node: Dictionary, unsaved: Array) -> String:
	if str(node.get("kind", "")) == "missing":
		return "missing"
	if bool(node.get("cycle", false)):
		return "cycle"
	if bool(node.get("pending", false)) and not (node.get("constraint") is Dictionary):
		return "pending" # (a Float done here: what the part is now is not known until the next status answer; never show a guess)
	var c = node.get("constraint")
	var cs := ""
	if c is Dictionary:
		cs = str(c.get("status", ""))
		if int(c.get("broken_mates", 0)) > 0:
			return "broken"
		if cs == "over_constrained":
			return "near" if int(c.get("near_mates", 0)) > 0 else "over_constrained"
	var resolved = node.get("resolved_part_id")
	if resolved != null and unsaved.has(str(resolved)):
		return "unsaved"
	if cs == "under_constrained":
		return "under_constrained"
	if cs == "fixed" or (not (c is Dictionary) and bool(node.get("fixed", false))):
		return "fixed"
	if cs == "fully_constrained":
		return "fully_constrained"
	return "none"


static func state_rank(state: String) -> int:
	var i := STATES.find(state)
	return STATES.size() if i < 0 else i


static func state_icon_for(state: String) -> String:
	match state:
		"missing", "cycle", "broken", "over_constrained", "near":
			return "warning"
		"under_constrained":
			return "lock_open"
		"fixed":
			return "pin"
		"fully_constrained":
			return "lock"
	return "" # unsaved has no icon here: its row says "unsaved"


static func state_level(state: String) -> String:
	## How loudly a state is drawn: "error" (red), "warning" (amber), or "".
	match state:
		"missing", "cycle", "broken", "over_constrained":
			return "error"
		"near":
			return "warning"
	return ""


static func state_hint_for(state: String, dof: int = -1) -> String:
	match state:
		"missing":
			return "missing file"
		"cycle":
			return "placed inside itself"
		"broken":
			return "broken mate"
		"over_constrained":
			return "over-constrained"
		"near":
			return "mate nearly met"
		"unsaved":
			return "unsaved"
		"under_constrained":
			return "under-constrained" + (" (%d DOF)" % dof if dof >= 0 else "")
		"fixed":
			return "fixed"
		"fully_constrained":
			return "fully constrained"
		"pending":
			return "updating"
	return ""


static func state_hint_short(state: String, dof: int = -1) -> String:
	## The row's own hint: a few characters, so it never pushes the name out of a 480 px panel (the icon and colour say the rest). The full words are state_hint_for(),
	## shown in the bottom bar when the row is selected.
	match state:
		"missing":
			return "missing"
		"cycle":
			return "loop"
		"broken":
			return "broken"
		"over_constrained":
			return "over"
		"near":
			return "near"
		"unsaved":
			return "unsaved"
		"under_constrained":
			return "under" + (" %d" % dof if dof >= 0 else "")
		"fixed":
			return "fixed"
		"fully_constrained":
			return "full"
		"pending":
			return "updating"
	return ""


# --- problem counts and bubbles (section 6) -------------------------------------------------------------------------------------------------------------

static func _n(value) -> int:
	return 0 if value == null else int(value)


static func unsaved_below(node: Dictionary, unsaved: Array) -> int:
	## Rows below `node` (not suppressed, not under a suppressed row, not missing) whose Part is unsaved.
	var count := 0
	for child in children_of(node):
		if bool(child.get("suppressed", false)):
			continue
		count += _unsaved_self(child, unsaved) + unsaved_below(child, unsaved)
	return count


static func _unsaved_self(node: Dictionary, unsaved: Array) -> int:
	var resolved = node.get("resolved_part_id")
	return 1 if str(node.get("kind", "")) != "missing" and resolved != null and unsaved.has(str(resolved)) else 0


static func bubble_from(error: int, warning: int, unsaved: int):
	if error > 0:
		return {"level": "error", "count": error}
	if warning > 0:
		return {"level": "warning", "count": warning}
	if unsaved > 0:
		return {"level": "unsaved", "count": unsaved}
	return null


static func _collapsed_numbers(node: Dictionary, unsaved: Array) -> Array:
	## [error, warning, unsaved] of a collapsed occurrence: its roll-up plus the unsaved rows below.
	var p = node.get("problems")
	var e := 0
	var w := 0
	if p is Dictionary:
		e = _n(p.get("missing")) + _n(p.get("cycles")) + _n(p.get("broken")) + _n(p.get("over_constrained"))
		w = _n(p.get("near"))
	return [e, w, unsaved_below(node, unsaved)]


static func occurrence_bubble(node: Dictionary, is_open: bool, unsaved: Array):
	if is_open:
		var m = node.get("mates")
		return bubble_from(_n(m.get("broken")), _n(m.get("near")), 0) if m is Dictionary else null
	var nums := _collapsed_numbers(node, unsaved)
	return bubble_from(nums[0], nums[1], nums[2])


static func group_bubble(members: Array, unsaved: Array):
	## A collapsed group: every unsuppressed member's own row plus what is below it.
	var e := 0
	var w := 0
	var u := 0
	for m in members:
		if bool(m.get("suppressed", false)):
			continue
		var st := state_of(m, unsaved)
		if st == "missing" or st == "cycle" or st == "over_constrained":
			e += 1
		u += _unsaved_self(m, unsaved)
		var nums := _collapsed_numbers(m, unsaved)
		e += nums[0]
		w += nums[1]
		u += nums[2]
	return bubble_from(e, w, u)


static func folder_bubble(mates):
	return bubble_from(_n(mates.get("broken")), _n(mates.get("near")), 0) if mates is Dictionary else null


# --- groups (section 4) -----------------------------------------------------------------------------------------------------------------------------------

static func plan_level(siblings: Array, grouping: bool) -> Array:
	## The entries of one level, in order: {"names": {...}, "index": i} for an occurrence row, {"group": true, "members": [i...], "base": ...} for a group row.
	var names := sibling_names(siblings)
	var by_key := {}
	for i in siblings.size():
		var k: String = names[i]["key"]
		if k != "":
			if not by_key.has(k):
				by_key[k] = []
			(by_key[k] as Array).append(i)
	var out: Array = []
	for i in siblings.size():
		var k: String = names[i]["key"]
		if grouping and k != "" and (by_key[k] as Array).size() >= GROUP_MIN:
			if (by_key[k] as Array)[0] == i:
				out.append({"group": true, "members": by_key[k], "base": names[i]["base"], "names": names})
			continue
		out.append({"group": false, "index": i, "names": names})
	return out


static func group_key(parent_key: String, first_occurrence_id: String) -> String:
	return ("" if parent_key == "" else parent_key + "/") + "#group:" + first_occurrence_id


static func node_key(path: Array) -> String:
	return path_key(path)


# --- visible rows (section 7) --------------------------------------------------------------------------------------------------------------------------------

static func visible_rows(response: Dictionary, open, grouping: bool, unsaved_part_ids: Array, features: Dictionary = {}, opts: Dictionary = {}) -> Array:
	## The flat list a client draws for a set of open row keys. Every row: key, kind, depth, label, state, bubble, expandable, open, count, path, hidden, suppressed.
	## `opts` is for the filter and the restore (spec 11 and 12): "listed" (a Dictionary of keys: only those rows are emitted), "all" (every row that can open is open) and
	## "trace" (a Dictionary the walk fills: key -> {"parent", "fixed"}).
	var open_set: Dictionary = open if open is Dictionary else {} # (a set: _is_open asks once per row)
	if open is Array:
		for k in open:
			open_set[k] = true
	var ctx := {"open": open_set, "all": bool(opts.get("all", false)), "listed": opts.get("listed"), "trace": opts.get("trace"), "grouping": grouping, "unsaved": unsaved_part_ids, "features": features}
	var rows: Array = []
	var root_unsaved := unsaved_part_ids.has(str(response.get("part_id", "")))
	_emit(ctx, rows, _row("", "root", 0, str(response.get("part_name", "")), "unsaved" if root_unsaved else "none", null, false, true, null, [], false, false), null, false)
	_list_level(children_of(response), "", 1, ctx, rows)
	if ctx["listed"] == null: # the Mates and Patterns folders are never listed while a filter is on
		var mates = response.get("mates")
		if mates is Dictionary and int(mates.get("count", 0)) > 0:
			_emit(ctx, rows, _row("#mates", "mates_folder", 1, "Mates", "none", folder_bubble(mates), true, _is_open(ctx, "#mates"), int(mates["count"]), null, false, false), "", false)
		var patterns = response.get("patterns")
		if patterns is Dictionary and int(patterns.get("count", 0)) > 0:
			_emit(ctx, rows, _row("#patterns", "patterns_folder", 1, "Patterns", "none", null, true, _is_open(ctx, "#patterns"), int(patterns["count"]), null, false, false), "", false)
	_add_features("", 1, ctx, rows)
	return rows


static func _is_open(ctx: Dictionary, key: String) -> bool:
	return bool(ctx["all"]) or (ctx["open"] as Dictionary).has(key)


static func _emit(ctx: Dictionary, rows: Array, row: Dictionary, parent, fixed: bool) -> bool:
	## Appends a row unless a filter's `listed` set leaves it out; records its parent for the filter's walk back up.
	var listed = ctx["listed"]
	if listed != null and not (listed as Dictionary).has(row["key"]):
		return false
	rows.append(row)
	if ctx["trace"] != null:
		(ctx["trace"] as Dictionary)[row["key"]] = {"parent": parent, "fixed": fixed}
	return true


static func _row(key: String, kind: String, depth: int, label: String, state: String, bubble, expandable: bool, is_open: bool, count, path, hidden: bool, suppressed: bool) -> Dictionary:
	return {"key": key, "kind": kind, "depth": depth, "label": label, "state": state, "bubble": bubble, "expandable": expandable, "open": is_open, "count": count, "path": path, "hidden": hidden, "suppressed": suppressed}


static func _add_features(owner_key: String, depth: int, ctx: Dictionary, rows: Array) -> void:
	for f in (ctx["features"] as Dictionary).get(owner_key, []):
		_emit(ctx, rows, _row("%s#feature:%s" % [owner_key, str(f["id"])], "feature", depth, str(f["label"]), "none", null, false, false, null, null, false, false), owner_key, false)


static func children_of(node: Dictionary) -> Array:
	## A node's children as an Array: the field missing, null or anything else is no children (one place for it: every walk of a response goes through here).
	var c = node.get("children")
	return c if c is Array else []


static func node_expandable(node: Dictionary) -> bool:
	return str(node.get("kind", "")) != "missing" and (not children_of(node).is_empty() or _n(node.get("feature_count")) > 0)


static func _occurrence_row(node: Dictionary, label: String, depth: int, ctx: Dictionary) -> Dictionary:
	var key := node_key(node["path"])
	var expandable := node_expandable(node)
	var is_open := expandable and _is_open(ctx, key)
	var bubble = occurrence_bubble(node, is_open, ctx["unsaved"]) if expandable else null
	return _row(key, str(node.get("kind", "part")), depth, label, state_of(node, ctx["unsaved"]), bubble, expandable, is_open, null, node["path"], bool(node.get("hidden", false)), bool(node.get("suppressed", false)))


static func _list_level(siblings: Array, parent_key: String, depth: int, ctx: Dictionary, rows: Array) -> void:
	var unsaved: Array = ctx["unsaved"]
	for entry in plan_level(siblings, bool(ctx["grouping"])):
		var names: Array = entry["names"]
		if not bool(entry["group"]):
			_list_node(siblings[entry["index"]], names[entry["index"]]["label"], depth, parent_key, ctx, rows)
			continue
		var idx: Array = entry["members"]
		var members: Array = idx.map(func(i): return siblings[i])
		var gkey := group_key(parent_key, str(members[0]["occurrence_id"]))
		var is_open := _is_open(ctx, gkey)
		var live := members.filter(func(m): return not bool(m.get("suppressed", false)))
		var pool: Array = live if not live.is_empty() else members
		var state := "none"
		for m in pool:
			var st := state_of(m, unsaved)
			if state_rank(st) < state_rank(state):
				state = st
		var all_hidden := members.all(func(m): return bool(m.get("hidden", false)))
		var all_suppressed := members.all(func(m): return bool(m.get("suppressed", false)))
		var shown := _emit(ctx, rows, _row(gkey, "group", depth, "%s x%d" % [entry["base"], members.size()], state, null if is_open else group_bubble(members, unsaved), true, is_open, members.size(), null, all_hidden, all_suppressed), parent_key, false)
		if shown and is_open:
			for i in idx:
				_list_node(siblings[i], names[i]["label"], depth + 1, gkey, ctx, rows)


static func _list_node(node: Dictionary, label: String, depth: int, parent_key: String, ctx: Dictionary, rows: Array) -> void:
	var row := _occurrence_row(node, label, depth, ctx)
	var shown := _emit(ctx, rows, row, parent_key, bool(node.get("fixed", false)))
	if shown and bool(row["open"]):
		_list_level(children_of(node), str(row["key"]), depth + 1, ctx, rows)
		_add_features(str(row["key"]), depth + 1, ctx, rows)


# --- room context (B8) ---------------------------------------------------------------------------------------------------------------------------------------

static func room_keys(response: Dictionary, part_ids: Array, open: Dictionary, grouping: bool, all: bool = false) -> Dictionary:
	## The keys (an occurrence's path key, a group's key) of the rows inside an open room: a placement of one of the rooms' Parts, and everything below it (rooms are per
	## Part, so every placement of that Part is inside). Walks only the open rows (every row with `all`, which a filter lists whatever is open). "" in the result: the root
	## Part is itself a room's, so every row is inside.
	var out := {}
	if part_ids.is_empty():
		return out
	if part_ids.has(str(response.get("part_id", ""))):
		out[""] = true
		return out
	_room_level(children_of(response), "", false, part_ids, open, grouping, all, out)
	return out


static func _room_level(siblings: Array, parent_key: String, parent_inside: bool, part_ids: Array, open: Dictionary, grouping: bool, all: bool, out: Dictionary) -> void:
	for entry in plan_level(siblings, grouping):
		if not bool(entry["group"]):
			_room_node(siblings[entry["index"]], parent_inside, part_ids, open, grouping, all, out)
			continue
		var members: Array = (entry["members"] as Array).map(func(i): return siblings[i])
		var gkey := group_key(parent_key, str(members[0]["occurrence_id"]))
		var group_inside := parent_inside or members.any(func(m): return part_ids.has(str(m.get("resolved_part_id", ""))))
		if group_inside:
			out[gkey] = true
		if all or open.has(gkey):
			for m in members: # (judged one by one: the group row is lit when any member is, so the way to it shows; a member that is not the room's Part is outside)
				_room_node(m, parent_inside, part_ids, open, grouping, all, out)


static func _room_node(node: Dictionary, parent_inside: bool, part_ids: Array, open: Dictionary, grouping: bool, all: bool, out: Dictionary) -> void:
	var resolved = node.get("resolved_part_id")
	var inside := parent_inside or (resolved != null and part_ids.has(str(resolved)))
	var key := node_key(node["path"])
	if inside:
		out[key] = true
	if all or open.has(key):
		_room_level(children_of(node), key, inside, part_ids, open, grouping, all, out)


static func room_way_keys(response: Dictionary, part_ids: Array, grouping: bool) -> Dictionary:
	## B8.1: the keys of the rows (and groups) that are not inside an open room but have a placement of the room's Part somewhere below them, open or not: the way to the
	## room. The walk covers every node of the answer (a closed row's subtree is the very thing it has to say something about). "" is the root.
	var out := {}
	if part_ids.is_empty() or part_ids.has(str(response.get("part_id", ""))):
		return out # (no room, or the root Part is itself a room's: every row is inside)
	if _way_level(children_of(response), "", part_ids, grouping, out):
		out[""] = true
	return out


static func _way_level(siblings: Array, parent_key: String, part_ids: Array, grouping: bool, out: Dictionary) -> bool:
	## Whether any sibling is a placement of a room's Part or holds one below it. Rows inside (a placement of the Part) are not marked: they are "inside", not "the way".
	var any := false
	for entry in plan_level(siblings, grouping):
		if not bool(entry["group"]):
			any = _way_node(siblings[entry["index"]], part_ids, grouping, out) or any
			continue
		var members: Array = (entry["members"] as Array).map(func(i): return siblings[i])
		var member_has := false
		var member_is := false
		for m in members:
			member_has = _way_node(m, part_ids, grouping, out) or member_has
			member_is = member_is or _is_room_node(m, part_ids)
		if member_has and not member_is:
			out[group_key(parent_key, str(members[0]["occurrence_id"]))] = true # (a group with a member that is the room's Part is "inside" already: room_keys)
		any = any or member_has
	return any


static func _way_node(node: Dictionary, part_ids: Array, grouping: bool, out: Dictionary) -> bool:
	var key := node_key(node["path"])
	if _is_room_node(node, part_ids):
		return true # (inside: what is below it is inside too, and none of it is "the way")
	var below := _way_level(children_of(node), key, part_ids, grouping, out)
	if below:
		out[key] = true
	return below


static func _is_room_node(node: Dictionary, part_ids: Array) -> bool:
	var resolved = node.get("resolved_part_id")
	return resolved != null and part_ids.has(str(resolved))


# --- reveal (section 8) ----------------------------------------------------------------------------------------------------------------------------------------

static func reveal_keys(response: Dictionary, path: Array, grouping: bool) -> Array:
	## The keys to open so the row at `path` is listed: for each level, its group (when grouping puts that node in one) and then the ancestor.
	var keys: Array = []
	var siblings: Array = children_of(response)
	for i in path.size():
		var node: Dictionary = {}
		for s in siblings:
			if str(s.get("occurrence_id", "")) == str(path[i]):
				node = s
				break
		if node.is_empty():
			break
		if grouping:
			for entry in plan_level(siblings, true):
				if bool(entry["group"]) and (entry["members"] as Array).any(func(m): return str(siblings[m]["occurrence_id"]) == str(path[i])):
					keys.append(group_key(node_key(path.slice(0, i)), str(siblings[entry["members"][0]]["occurrence_id"])))
					break
		if i < path.size() - 1:
			keys.append(node_key(path.slice(0, i + 1)))
		siblings = children_of(node)
	return keys


# --- filter (section 11) ---------------------------------------------------------------------------------------------------------------------------------------

const ERROR_STATES := ["missing", "cycle", "broken", "over_constrained", "lost_reference"] ## the bubble's `error` set (lost_reference is the live part's, spec 13)
const WARNING_STATES := ["near", "moved_reference"]
const FILTER_TOKENS := [":missing", ":errors", ":warnings", ":unsaved", ":fixed", ":hidden", ":suppressed", ":parts", ":assemblies", ":features", ":sketches"]
const NON_MATCHING_KINDS := ["root", "group", "mates_folder", "patterns_folder", "bodies_folder", "planes_folder", "surfaces_folder", "curves_folder"]


static func parse_query(query: String) -> Dictionary:
	## {"terms", "tokens", "unknown"}: lower case, in query order, each word once; a word starting with ":" is a token (spec 11).
	var terms: Array = []
	var tokens: Array = []
	var unknown: Array = []
	for word in _words(query):
		var bucket: Array = terms
		if word.begins_with(":"):
			bucket = tokens if FILTER_TOKENS.has(word) else unknown
		if not bucket.has(word):
			bucket.append(word)
	return {"terms": terms, "tokens": tokens, "unknown": unknown}


static func _is_space(code: int) -> bool:
	## What Python's str.split() (the reference's) treats as whitespace: ASCII 9-13 and 28-32, U+0085, U+00A0, U+1680, U+2000-200A, U+2028, U+2029, U+202F, U+205F, U+3000.
	return (code >= 9 and code <= 13) or (code >= 28 and code <= 32) or code == 0x85 or code == 0xA0 or code == 0x1680 or (code >= 0x2000 and code <= 0x200A) \
		or code == 0x2028 or code == 0x2029 or code == 0x202F or code == 0x205F or code == 0x3000


static func query_words(query: String, keep_case: bool = false) -> Array:
	## The words of a query, split on the reference's whitespace (see _is_space); lower case unless `keep_case` (what the window keeps and shows of what was typed).
	var out: Array = []
	var current := ""
	for ch in (query if keep_case else query.to_lower()):
		if _is_space(ch.unicode_at(0)):
			if current != "":
				out.append(current)
				current = ""
		else:
			current += ch
	if current != "":
		out.append(current)
	return out


static func _words(query: String) -> Array:
	return query_words(query)


static func _token_met(token: String, row: Dictionary, fixed: bool) -> bool:
	match token:
		":missing": return row["state"] == "missing"
		":errors": return ERROR_STATES.has(row["state"])
		":warnings": return WARNING_STATES.has(row["state"])
		":unsaved": return row["state"] == "unsaved"
		":fixed": return fixed
		":hidden": return bool(row["hidden"])
		":suppressed": return bool(row["suppressed"])
		":parts": return row["kind"] == "part"
		":assemblies": return row["kind"] == "assembly"
		":features": return row["kind"] == "feature"
		":sketches": return row.get("type") == "sketch"
	return false


static func filtered_rows(response: Dictionary, query: String, open: Array, grouping: bool, unsaved_part_ids: Array, features: Dictionary = {}) -> Dictionary:
	## {"rows", "unknown"} (spec 11): section 7's rows narrowed to the root, the matches and their ancestors, every row with `match`. An empty query is no filter (the rows
	## for `open`, every match false). The open keys are not changed: the caller keeps its own.
	if _words(query).is_empty():
		var plain: Array = visible_rows(response, open, grouping, unsaved_part_ids, features)
		for r in plain:
			r["match"] = false
		return {"rows": plain, "unknown": []}
	var parsed := parse_query(query)
	var terms: Array = parsed["terms"]
	var tokens: Array = parsed["tokens"]
	var trace := {}
	var everything: Array = visible_rows(response, [], grouping, unsaved_part_ids, features, {"all": true, "trace": trace})
	var matches := {}
	if not terms.is_empty() or not tokens.is_empty():
		for r in everything:
			if NON_MATCHING_KINDS.has(r["kind"]):
				continue
			var label: String = str(r["label"]).to_lower()
			if terms.all(func(t): return label.contains(t)) and tokens.all(func(t): return _token_met(t, r, bool(trace[r["key"]]["fixed"]))):
				matches[r["key"]] = true
	var listed := {"": true}
	for k in matches:
		var key = k
		while key != null and not listed.has(key):
			listed[key] = true
			key = trace[key]["parent"]
	var opened := {}
	for k in listed:
		if k != "":
			opened[trace[k]["parent"]] = true # a listed row is open when something below it is listed
	var rows: Array = visible_rows(response, opened, grouping, unsaved_part_ids, features, {"listed": listed})
	for r in rows:
		r["match"] = matches.has(r["key"])
	return {"rows": rows, "unknown": parsed["unknown"]}


# --- remembered open rows (section 12) -------------------------------------------------------------------------------------------------------------------------

const MAX_STORED_KEYS := 2000
const OPEN_KINDS := ["assembly", "part", "group", "mates_folder", "patterns_folder"]


static func restore_open_keys(response: Dictionary, stored: Array, limit: int = MAX_STORED_KEYS) -> Array:
	## The stored keys that still name a row that can open, in the visible-row order of the tree with everything open and grouping on (whatever the current grouping, so a
	## switch off and on loses nothing), at most `limit`. Feature keys and the root's "" are never kept.
	var wanted := {}
	for k in stored:
		wanted[str(k)] = true
	var kept: Array = []
	for r in visible_rows(response, [], true, [], {}, {"all": true}):
		if wanted.has(r["key"]) and OPEN_KINDS.has(r["kind"]) and bool(r["expandable"]):
			kept.append(r["key"])
	return kept.slice(0, limit)


# --- the window's rows from the endpoint's nodes -------------------------------------------------------------------------------------------------------------

static func rows_from_tree(nodes: Array, parent_path: Array, parent_part_id: String, parent_status_failed: bool, unsaved: Array) -> Array:
	## The endpoint's nodes -> this window's row dicts (same shape as rows_from_occurrences, with every level already fetched: `children` is an Array). The names are the
	## spec's (sibling_names); `state` is the spec's state slot; `placements` is "used N x"; `status_unavailable` marks the children of a level whose status failed.
	var names := sibling_names(nodes)
	var rows: Array = []
	for i in nodes.size():
		var n: Dictionary = nodes[i]
		var id := str(n.get("occurrence_id", ""))
		var resolved := str(n["resolved_part_id"]) if n.get("resolved_part_id") != null else ""
		var c = n.get("constraint")
		var has_c: bool = c is Dictionary
		var row := {
			"id": id,
			"name": names[i]["label"],
			"base_name": names[i]["base"],
			"override": _has_text(n.get("name_override")),
			"named": true,
			"resolved_part_id": resolved,
			"children": rows_from_tree(children_of(n), parent_path + [id], resolved, bool(n.get("status_failed", false)), unsaved),
			"expanded": false,
			"fixed": bool(n.get("fixed", false)),
			"backend_hidden": bool(n.get("hidden", false)),
			"suppressed": bool(n.get("suppressed", false)),
			"missing": str(n.get("kind", "")) == "missing",
			"path": parent_path + [id],
			"status": str(c.get("status", "")) if has_c else "",
			"dof": int(c.get("dof", -1)) if has_c else -1,
			"rigid_set": str(c["rigid_set"]) if has_c and c.get("rigid_set") is String else "",
			"state": state_of(n, unsaved),
			"node_kind": str(n.get("kind", "part")),
			"placements": _n(n.get("placements")),
			"status_unavailable": parent_status_failed,
			"parent_part_id": parent_part_id,
		}
		rows.append(row)
	for row in rows:
		row["set_note"] = set_note(rows, row)
		row["set_slot"] = set_colour_index(rows, str(row["rigid_set"]))
	return rows


static func merge_expanded(old_rows: Array, fresh: Array) -> Array:
	## A refreshed whole tree keeps what was open: a fresh row takes `expanded` from the old row with the same id (and Part), at every depth.
	var by_id := {}
	for row in old_rows:
		by_id[str(row["id"])] = row
	for row in fresh:
		var old: Dictionary = by_id.get(str(row["id"]), {})
		if old.is_empty() or str(old.get("resolved_part_id", "")) != str(row["resolved_part_id"]):
			continue
		row["expanded"] = old.get("expanded", false)
		if old.get("children") != null and row.get("children") != null:
			merge_expanded(old["children"], row["children"])
	return fresh


static func index_rows(rows: Array, out: Dictionary = {}) -> Dictionary:
	## path key -> row, over the whole fetched tree.
	for row in rows:
		out[path_key(row.get("path", []))] = row
		if row.get("children") != null:
			index_rows(row["children"], out)
	return out


static func carry_status(fresh: Dictionary, old: Dictionary) -> void:
	## A structure-only response (no ?status=true) keeps the last status answer for the nodes it shares with the previous response, so a refresh doesn't blank the
	## states while the new status is on its way. Copies constraint / mates counts / problems / status_failed where the fresh node has none.
	if old.is_empty():
		return
	var old_by_path := {}
	_index_nodes(children_of(old), old_by_path)
	_carry_into(fresh, old)
	_carry_nodes(children_of(fresh), old_by_path)


static func _index_nodes(nodes: Array, out: Dictionary) -> void:
	for n in nodes:
		out[node_key(n["path"])] = n
		_index_nodes(children_of(n), out)


static func _carry_nodes(nodes: Array, old_by_path: Dictionary) -> void:
	for n in nodes:
		var o: Dictionary = old_by_path.get(node_key(n["path"]), {})
		if not o.is_empty():
			_carry_into(n, o)
		_carry_nodes(children_of(n), old_by_path)


static func _carry_into(n: Dictionary, o: Dictionary) -> void:
	if n.get("constraint") == null and o.get("constraint") != null and bool(n.get("fixed", false)) == bool(o.get("fixed", false)):
		n["constraint"] = o["constraint"] # (not when `fixed` changed since: that old status describes the old state)
	if n.get("constraint") == null and not bool(n.get("fixed", false)) and (bool(o.get("pending", false)) or bool(o.get("fixed", false))):
		n["pending"] = true # (a structure-only answer for a part that was just floated: its old status is not carried, and "none" would be a guess)
	if n.get("problems") == null and o.get("problems") != null:
		n["problems"] = o["problems"]
	if n.get("mates") is Dictionary and o.get("mates") is Dictionary:
		for k in ["broken", "near", "held", "lost"]:
			if n["mates"].get(k) == null:
				n["mates"][k] = o["mates"].get(k)
	if bool(o.get("status_failed", false)):
		n["status_failed"] = true


static func clear_pending(response: Dictionary) -> void:
	## Drops every `pending` mark (the status call that was to settle them failed): the rows go back to the flag-based state.
	for n in children_of(response):
		n["pending"] = false
		clear_pending(n)


static func normalise_tree(response: Dictionary) -> void:
	## Makes every `children` of a response (the root's and each node's) an Array, so nothing downstream has to ask.
	response["children"] = children_of(response)
	for n in response["children"]:
		if n is Dictionary:
			normalise_tree(n)


static func set_node_fixed(response: Dictionary, path: Array, fixed: bool) -> void:
	## A Fix / Float done here, written into the held response at once: the flag changes and the old constraint (which describes the old state) is dropped.
	## Fixed reads as a pin (a fixed part is fixed whatever its mates). Floated is marked `pending`: the row says "updating" until a fresh status says what it is
	## now (it may be under-constrained, fully constrained, or free), never a blank that reads as "free and unmated".
	var nodes: Array = children_of(response)
	for i in path.size():
		var hit: Dictionary = {}
		for n in nodes:
			if str(n.get("occurrence_id", "")) == str(path[i]):
				hit = n
				break
		if hit.is_empty():
			return
		if i == path.size() - 1:
			hit["fixed"] = fixed
			hit["constraint"] = null
			hit["pending"] = not fixed
			return
		nodes = children_of(hit)
