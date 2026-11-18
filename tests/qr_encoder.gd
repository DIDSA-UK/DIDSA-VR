extends SceneTree
## P2: scripts/session/qr_encoder.gd, the QR generator behind Host Session's join code. Headless checks of what can be known without a reader: the capacity table
## against the standard's figures, Reed-Solomon against the standard's worked example, the format bits against its table, the fixed patterns (finders, timing,
## the dark module, alignment), that every version 1 to 10 builds, which version and level a text gets, the image's size and quiet zone, and that the picture is
## deterministic. An INDEPENDENT reader decoding the picture is tools/qr_roundtrip/ (OpenCV; ten texts, versions 1 to 10, all read back exactly when it was written).
## Run: "$GODOT" --headless --path . --script res://tests/qr_encoder.gd  (see tests/README.md)

const Q := preload("res://scripts/session/qr_encoder.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _bits(value: int) -> String:
	var out := ""
	for i in range(14, -1, -1):
		out += str((value >> i) & 1)
	return out


func _initialize() -> void:
	# capacities: byte mode, as the standard's table has them
	_check(Q.data_capacity(1, Q.Level.M) == 14 and Q.data_capacity(1, Q.Level.L) == 17, "version 1 holds 14 bytes at M and 17 at L")
	_check(Q.data_capacity(5, Q.Level.M) == 84 and Q.data_capacity(5, Q.Level.L) == 106, "version 5 holds 84 at M and 106 at L")
	_check(Q.data_capacity(10, Q.Level.M) == 213 and Q.data_capacity(10, Q.Level.L) == 271, "version 10 holds 213 at M and 271 at L")
	var totals_ok := true
	for version in range(1, 11):
		for level in [Q.Level.L, Q.Level.M]:
			var b: Array = Q.BLOCKS[level][version]
			var data: int = int(b[1]) * int(b[2]) + int(b[3]) * int(b[4])
			var blocks: int = int(b[1]) + int(b[3])
			var total := data + blocks * int(b[0])
			var expected: int = [0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346][version]
			totals_ok = totals_ok and total == expected
	_check(totals_ok, "every version's data plus error-correction codewords add up to the standard's total (26, 44, 70 ... 346)")
	# Reed-Solomon: the standard's worked example (1-M, "HELLO WORLD"): ten error-correction codewords
	var data := PackedByteArray([32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17])
	var ec: PackedByteArray = Q._rs_remainder(data, Q._rs_divisor(10))
	_check(Array(ec) == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23], "Reed-Solomon gives the standard's ten codewords for its worked example")
	_check(Q._gf_multiply(2, 128) == 0x1D and Q._gf_multiply(0x1D, 2) == 0x3A and Q._gf_multiply(1, 200) == 200 and Q._gf_multiply(0, 7) == 0, "GF(256) multiplication (x * 128 reduces by 0x11D)")
	# format information
	_check(_bits(Q.format_bits(Q.Level.M, 0)) == "101010000010010" and _bits(Q.format_bits(Q.Level.M, 5)) == "100000011001110", "format bits for M with masks 0 and 5 are the standard's")
	_check(_bits(Q.format_bits(Q.Level.L, 0)) == "111011111000100" and _bits(Q.format_bits(Q.Level.L, 4)) == "110011000101111", "format bits for L with masks 0 and 4 are the standard's")
	# the fixed patterns
	var qr := Q.encode("didsa-join:1?c=K7XQ4M")
	var size: int = qr["size"]
	_check(qr["ok"] and size == qr["version"] * 4 + 17 and (qr["modules"] as PackedByteArray).size() == size * size, "a code is (4 * version + 17) modules square (version %d, %d)" % [qr["version"], size])
	var finders := true
	for origin in [Vector2i(0, 0), Vector2i(size - 7, 0), Vector2i(0, size - 7)]:
		for y in 7:
			for x in 7:
				var ring := maxi(absi(x - 3), absi(y - 3))
				finders = finders and Q.dark(qr, origin.x + x, origin.y + y) == (ring != 2)
	_check(finders, "the three finder patterns are 7 x 7: dark ring, light ring, dark 3 x 3")
	var separators := true
	for i in 8:
		separators = separators and not Q.dark(qr, 7, i) and not Q.dark(qr, i, 7) and not Q.dark(qr, size - 8, i) and not Q.dark(qr, size - 1 - i, 7) and not Q.dark(qr, 7, size - 1 - i) and not Q.dark(qr, i, size - 8)
	_check(separators, "...each with its light separator")
	var timing := true
	for i in range(8, size - 8):
		timing = timing and Q.dark(qr, i, 6) == (i % 2 == 0) and Q.dark(qr, 6, i) == (i % 2 == 0)
	_check(timing, "the timing patterns alternate along row 6 and column 6")
	_check(Q.dark(qr, 8, size - 8), "the always-dark module is dark")
	# the format bits drawn are the ones for the chosen mask, both copies
	var bits := Q.format_bits(qr["level"], qr["mask"])
	var copy1 := 0
	var coords1: Array = [[8, 0], [8, 1], [8, 2], [8, 3], [8, 4], [8, 5], [8, 7], [8, 8], [7, 8], [5, 8], [4, 8], [3, 8], [2, 8], [1, 8], [0, 8]]
	for i in 15:
		copy1 |= (1 if Q.dark(qr, coords1[i][0], coords1[i][1]) else 0) << i
	var copy2 := 0
	for i in 15:
		var x: int = size - 1 - i if i < 8 else 8
		var y: int = 8 if i < 8 else size - 15 + i
		copy2 |= (1 if Q.dark(qr, x, y) else 0) << i
	_check(copy1 == bits and copy2 == bits, "both copies of the format information say this code's level and mask")
	# alignment: version 2 and up has one at (size - 7, size - 7)
	var align := true
	var v2 := Q.encode("didsa-join:1?c=K7XQ4M")
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			align = align and Q.dark(v2, v2["size"] - 7 + dx, v2["size"] - 7 + dy) == (maxi(absi(dx), absi(dy)) != 1)
	_check(v2["version"] >= 2 and align, "an alignment pattern sits near the bottom-right corner (version %d)" % v2["version"])
	# which version a text gets, and every version builds
	_check(Q.encode("HELLO")["version"] == 1 and Q.encode("x".repeat(14))["version"] == 1 and Q.encode("x".repeat(15))["version"] == 2, "the smallest version that fits is used (14 bytes: 1, 15 bytes: 2)")
	_check(Q.encode("x".repeat(213))["version"] == 10 and Q.encode("x".repeat(213))["level"] == Q.Level.M, "213 bytes is version 10 at M")
	_check(Q.encode("x".repeat(214))["level"] == Q.Level.L and Q.encode("x".repeat(214))["version"] > 0, "214 bytes falls to level L (version 10)")
	_check(Q.encode("x".repeat(271))["ok"] and not Q.encode("x".repeat(272))["ok"] and str(Q.encode("x".repeat(272))["error"]) != "", "272 bytes is too long for version 10 at L, with words for why")
	var all_build := true
	for n in [1, 14, 15, 26, 27, 42, 43, 62, 63, 84, 106, 119, 120, 152, 153, 180, 181, 213, 271]:
		var r := Q.encode("a".repeat(n))
		all_build = all_build and r["ok"] and r["size"] == r["version"] * 4 + 17
	_check(all_build, "texts across every version's size build")
	# the join text a presenter shows is small
	var join := Q.encode("didsa-join:1?h=wss%3A%2F%2Fsessions.example.net%3A8300&c=K7XQ4M")
	_check(join["ok"] and join["version"] <= 6 and join["level"] == Q.Level.M, "a join text with a hub address is version %d at M (a big, easy code for a headset camera)" % join["version"])
	# determinism and the image
	var again := Q.encode("didsa-join:1?h=wss%3A%2F%2Fsessions.example.net%3A8300&c=K7XQ4M")
	_check(again["modules"] == join["modules"] and again["mask"] == join["mask"], "the same text gives the same picture")
	var other := Q.encode("didsa-join:1?h=wss%3A%2F%2Fsessions.example.net%3A8300&c=K7XQ4N")
	_check(other["modules"] != join["modules"], "one character different gives a different picture")
	var image := Q.to_image(join, 4)
	var side: int = (join["size"] + 8) * 4
	_check(image.get_width() == side and image.get_height() == side, "the image is (size + 2 * 4 quiet modules) * scale square")
	var quiet_light := true
	for i in side:
		for edge in range(0, 16):
			quiet_light = quiet_light and image.get_pixel(i, edge).r > 0.9 and image.get_pixel(edge, i).r > 0.9
	_check(quiet_light, "the four-module quiet zone round it is white")
	_check(image.get_pixel(16 + 1, 16 + 1).r < 0.1 and image.get_pixel(16 + 4 + 1, 16 + 4 + 1).r > 0.9, "the top-left finder's corner module is black and the next ring white")
	quit()
