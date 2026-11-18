extends SceneTree
## Writes QR codes made by scripts/session/qr_encoder.gd as PNGs for decode.py (an independent reader) to check.
## Usage:  godot --headless --path . --script res://tools/qr_roundtrip/dump.gd -- <output folder>

const Q := preload("res://scripts/session/qr_encoder.gd")
const TEXTS := {
	"a": "HELLO",
	"b": "didsa-join:1?c=K7XQ4M",
	"c": "didsa-join:1?h=wss%3A%2F%2Fsessions.example.net&c=K7XQ4M",
	"d": "didsa-join:1?h=wss%3A%2F%2Fsessions.example.net%3A8300&c=K7XQ4M",
	"e": "didsa-join:1?h=ws%3A%2F%2F192.168.100.200%3A8300&c=K7XQ4M",
	"f": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
	"g": "y100",
	"h": "z150",
	"i": "w200",
	"j": "Mixed 1234 ~!@#$%^&*() end",
}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var folder: String = args[0] if args.size() > 0 else "."
	DirAccess.make_dir_recursive_absolute(folder)
	for key in TEXTS:
		var text: String = TEXTS[key]
		match key:
			"g": text = "y".repeat(100)
			"h": text = "z".repeat(150)
			"i": text = "w".repeat(200)
			"j": text = text.repeat(5)
		var qr := Q.encode(text)
		print("QR ", key, " ok=", qr["ok"], " version=", qr["version"], " size=", qr["size"])
		if qr["ok"]:
			Q.to_image(qr, 6).save_png("%s/%s.png" % [folder, key])
	quit()
