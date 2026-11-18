extends RefCounted
## The backend's document revision (DIDSA-CAD docs/live-sessions-scope.md, section 5): every /document response carries `X-Document-Revision`, an integer per document session
## that goes up with every change. The presenter reads it off the responses it already gets (the design table's client, the mesh fetches, the mates tool) so a
## `doc_changed` message can say which revision observers should be showing, with no extra call. A change made through a path that does not note it is caught by
## session_publisher.gd, which asks for the revision once (a cheap GET that answers 404 and still carries the header).

const HEADER := "x-document-revision"

static var latest := 0 ## the highest revision seen for this app's document session since reset()


static func note(headers) -> int:
	## Reads the header out of an HTTPRequest's response headers (any case); returns the revision found, or -1. Keeps the highest.
	for header in headers:
		var text := str(header)
		var colon := text.find(":")
		if colon > 0 and text.substr(0, colon).strip_edges().to_lower() == HEADER:
			var value := text.substr(colon + 1).strip_edges()
			if value.is_valid_int():
				latest = maxi(latest, int(value))
				return int(value)
	return -1


static func reset(seed_value: int = 0) -> void:
	## A new session (or another server): the numbers of the old document mean nothing.
	latest = seed_value
