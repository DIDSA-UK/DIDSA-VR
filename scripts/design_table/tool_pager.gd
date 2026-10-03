extends RefCounted
## The design table's tool row is six slots wide. A category with six tools or
## fewer shows them all. A category with more shows five and turns slot six into
## "More", which cycles through the pages of five. Pure data, no scene tree, so it
## is unit-tested on its own (tests/design_table_logic.gd).
##
##   var page := ToolPager.slots(tools, 0)
##   page["tools"]     the tool defs for the row (never more than 6 slots in all)
##   page["has_more"]  true when slot six is the "More" button
##   page["page"]      the page actually shown (clamped)
##   page["pages"]     how many pages there are

const SLOTS := 6
const PAGE_WITH_MORE := 5 ## tools per page when slot six is "More"


static func page_count(tool_count: int) -> int:
	if tool_count <= SLOTS:
		return 1
	return ceili(float(tool_count) / float(PAGE_WITH_MORE))


static func slots(tools: Array, page: int) -> Dictionary:
	var pages := page_count(tools.size())
	var shown := clampi(page, 0, pages - 1)
	if pages == 1:
		return {"tools": tools.duplicate(), "has_more": false, "page": 0, "pages": 1}
	var start := shown * PAGE_WITH_MORE
	return {
		"tools": tools.slice(start, mini(start + PAGE_WITH_MORE, tools.size())),
		"has_more": true,
		"page": shown,
		"pages": pages,
	}


static func next_page(page: int, tool_count: int) -> int:
	## "More" wraps round to the first page after the last.
	var pages := page_count(tool_count)
	return (page + 1) % pages if pages > 1 else 0
