extends RefCounted
## The landing's tips, as data: adding a tip is one line in TIPS. Each is {id, title, text, icon, server}.
## `server` is true when the tip is about something that needs a DIDSA-CAD backend (so an offline build, the APK
## handed to friends, leaves it out: see for_connection()). `icon` is a name from ui_icons.gd.
##
## Every control named here was checked against controller.gd, locomotion.gd and the README's Controls table
## (20 Oct 2026); the places the first draft in docs/landing-scope.md was wrong are noted on the tip.

const TIPS: Array[Dictionary] = [
	{"id": "grab", "title": "Grab anything", "icon": "navigate", "server": false,
		"text": "Squeeze the grip on a part to take it where you hold it. Grip on empty space takes the whole model."},
	{"id": "two_hands", "title": "Two hands to scale", "icon": "scale", "server": false,
		"text": "Grip with both hands on empty space, then pull apart to enlarge and push together to shrink."},
	{"id": "exact_scale", "title": "Exact scale", "icon": "scale", "server": false,
		"text": "Click the right thumbstick to type a scale, for example 1 for full size."},
	{"id": "wheel", "title": "The tool wheel", "icon": "tools", "server": false,
		# Draft said "hold right trigger and grip": it is both pressed together (within a short window), not a hold.
		"text": "Press the right trigger and grip together, move your hand towards a tile, and let go to choose. Let go in the middle to cancel."},
	{"id": "move", "title": "Walk, turn, teleport", "icon": "movement", "server": false,
		"text": "Left stick walks. Right stick left or right turns. Push the right stick forward, point at the floor and let go to teleport."},
	{"id": "speed", "title": "Faster walking", "icon": "movement", "server": false,
		"text": "Travel speed on the wrist tablet (View > Navigate) goes up to 30 m/s, handy beside a 110 m rocket."},
	{"id": "tablet", "title": "Your wrist tablet", "icon": "settings", "server": false,
		"text": "Turn your left wrist up, point the right laser at the small round icon and pull the trigger."},
	{"id": "select", "title": "Select a part", "icon": "navigate", "server": false,
		# Draft left out the nudge: A / X pulls the part nearer, B / Y pushes it away (controller.gd).
		"text": "Right laser and trigger turns a part yellow. Then the right stick turns it, and A / X and B / Y pull it nearer or push it away."},
	{"id": "undo", "title": "Undo", "icon": "undo", "server": false,
		# Draft said "every move and change": paint is undoable now, but a bare-glb colour change or a view change is not.
		"text": "Moves, scale changes and mates can be undone from the tablet's top bar or from the tool wheel."},
	{"id": "paint", "title": "Paint", "icon": "paint", "server": true,
		"text": "The Appearance tool: click to paint a body, hold the trigger to choose face, part or the whole assembly."},
	{"id": "section", "title": "Cut it open", "icon": "sections", "server": false,
		"text": "The Section tool slices the model so you can see inside. Grip the plane to move or tilt it."},
	{"id": "measure", "title": "Measure", "icon": "measure", "server": true,
		"text": "Pick two faces, edges or corners to read the distance between them."},
	{"id": "mates", "title": "Mate parts", "icon": "mates", "server": true,
		"text": "Mates join faces, edges and corners. Relax lets you try moves, then Return parts puts everything back."},
	{"id": "rooms", "title": "Rooms", "icon": "room", "server": true,
		"text": "Open a sub-assembly in its own glass room and resize it by its corners."},
	{"id": "scenes", "title": "Scenes", "icon": "scenes", "server": true,
		"text": "Save a pose of the whole assembly and show it again later."},
	{"id": "passthrough", "title": "Mixed reality", "icon": "environment", "server": false,
		# Draft promised passthrough outright. On a standalone Quest it needs the OpenXR Vendors plugin, which is not in the
		# project (docs/status.md), so the tip says where it works.
		"text": "View > Environment > Passthrough puts your parts in your real room on a headset linked to a PC. A standalone Quest needs a plugin this app does not have yet."},
	{"id": "same_files", "title": "Same files as DIDSA-CAD", "icon": "files", "server": true,
		"text": "Anything saved here opens in the flat app, and the other way round."},
]

const CYCLE_SECONDS := 8.0 ## how long a tip stays before the reel moves on


static func for_connection(connected: bool) -> Array[Dictionary]:
	## The tips that make sense with this connection: all of them with a backend, only the offline-safe ones without.
	var out: Array[Dictionary] = []
	for tip in TIPS:
		if connected or not tip["server"]:
			out.append(tip)
	return out
