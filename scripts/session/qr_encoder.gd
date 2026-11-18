extends RefCounted
## A small QR code generator, for the join code a presenter shows (Host Session). The headset has a QR READER (landing/qr_scanner.gd) but nothing that makes one, and
## no add-ons are allowed, so this is written here: byte mode, versions 1 to 10, error correction M (L when M does not fit), the eight masks scored by the standard's
## four penalties. The text it makes is ASCII (a hub address and a six-character code), at most a few dozen bytes: version 3 to 5 in practice.
##
## Written from the QR Code Model 2 standard (ISO/IEC 18004); verified by decoding its output with an independent reader (tests/qr_encoder.gd checks structure and the
## error-correction maths headless; the build notes record the OpenCV round trip). A scan by a real headset has not been tried.
##
##   var qr := QrEncoder.encode("didsa-join:1?h=wss%3A...&c=K7XQ4M")    # {ok, size, modules (PackedByteArray, 1 = dark), version, level, mask}
##   var image := QrEncoder.to_image(qr, 8)                              # white quiet zone included

enum Level { L, M }

const MAX_VERSION := 10
const FORMAT_BITS := {Level.L: 1, Level.M: 0}
const QUIET_ZONE := 4
# per version (index 1..10): the error-correction codewords per block, then [blocks, data codewords per block] for group 1 and group 2
const BLOCKS := {
	Level.L: [null, [7, 1, 19, 0, 0], [10, 1, 34, 0, 0], [15, 1, 55, 0, 0], [20, 1, 80, 0, 0], [26, 1, 108, 0, 0], [18, 2, 68, 0, 0], [20, 2, 78, 0, 0],
		[24, 2, 97, 0, 0], [30, 2, 116, 0, 0], [18, 2, 68, 2, 69]],
	Level.M: [null, [10, 1, 16, 0, 0], [16, 1, 28, 0, 0], [26, 1, 44, 0, 0], [18, 2, 32, 0, 0], [24, 2, 43, 0, 0], [16, 4, 27, 0, 0], [18, 4, 31, 0, 0],
		[22, 2, 38, 2, 39], [22, 3, 36, 2, 37], [26, 4, 43, 1, 44]],
}
const ALIGNMENT := [null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]]


static func data_capacity(version: int, level: int) -> int:
	## Bytes of text that fit (byte mode) in a version at a level.
	var b: Array = BLOCKS[level][version]
	var codewords: int = int(b[1]) * int(b[2]) + int(b[3]) * int(b[4])
	var header_bits := 4 + (8 if version <= 9 else 16)
	return (codewords * 8 - header_bits) / 8


static func encode(text: String) -> Dictionary:
	## {ok, size, modules, version, level, mask, error}. Not ok when the text is too long for version 10 at level L.
	var bytes := text.to_utf8_buffer()
	for level in [Level.M, Level.L]:
		for version in range(1, MAX_VERSION + 1):
			if bytes.size() <= data_capacity(version, level):
				return _build(bytes, version, level)
	return {"ok": false, "size": 0, "modules": PackedByteArray(), "version": 0, "level": 0, "mask": 0, "error": "That text is too long for a QR code here (%d bytes)." % bytes.size()}


static func dark(qr: Dictionary, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < int(qr["size"]) and y < int(qr["size"]) and (qr["modules"] as PackedByteArray)[y * int(qr["size"]) + x] == 1


static func to_image(qr: Dictionary, scale: int = 8, quiet: int = QUIET_ZONE) -> Image:
	## The code as a black-on-white image, `scale` pixels a module, with the quiet zone round it (a reader needs it).
	var size: int = qr["size"]
	var pixels := (size + quiet * 2) * scale
	var image := Image.create(pixels, pixels, false, Image.FORMAT_L8)
	image.fill(Color.WHITE)
	for y in size:
		for x in size:
			if dark(qr, x, y):
				image.fill_rect(Rect2i((x + quiet) * scale, (y + quiet) * scale, scale, scale), Color.BLACK)
	return image


# --- Building -----------------------------------------------------------------------------------------------------------------

static func _build(bytes: PackedByteArray, version: int, level: int) -> Dictionary:
	var b: Array = BLOCKS[level][version]
	var ec_len: int = b[0]
	var sizes: Array = []
	for i in int(b[1]):
		sizes.append(int(b[2]))
	for i in int(b[3]):
		sizes.append(int(b[4]))
	var total_data := 0
	for n in sizes:
		total_data += int(n)
	# the data bit stream: mode 0100, the length, the bytes, a terminator, padding
	var bits: Array = []
	_append_bits(bits, 0b0100, 4)
	_append_bits(bits, bytes.size(), 8 if version <= 9 else 16)
	for value in bytes:
		_append_bits(bits, value, 8)
	_append_bits(bits, 0, mini(4, total_data * 8 - bits.size()))
	while bits.size() % 8 != 0:
		bits.append(0)
	var data := PackedByteArray()
	for i in range(0, bits.size(), 8):
		var v := 0
		for j in 8:
			v = (v << 1) | int(bits[i + j])
		data.append(v)
	var pad := 0xEC
	while data.size() < total_data:
		data.append(pad)
		pad = 0x11 if pad == 0xEC else 0xEC
	# split into blocks, add each block's Reed-Solomon remainder, interleave
	var divisor := _rs_divisor(ec_len)
	var data_blocks: Array = []
	var ec_blocks: Array = []
	var at := 0
	for n in sizes:
		var block := data.slice(at, at + int(n))
		at += int(n)
		data_blocks.append(block)
		ec_blocks.append(_rs_remainder(block, divisor))
	var stream := PackedByteArray()
	for i in int(sizes.max()):
		for block in data_blocks:
			if i < (block as PackedByteArray).size():
				stream.append(block[i])
	for i in ec_len:
		for block in ec_blocks:
			stream.append(block[i])
	# the matrix
	var size := version * 4 + 17
	var modules := PackedByteArray()
	modules.resize(size * size)
	var is_function := PackedByteArray()
	is_function.resize(size * size)
	_draw_function_patterns(modules, is_function, size, version)
	_place_data(modules, is_function, size, stream)
	var best_mask := 0
	var best_score := 1 << 30
	for mask in 8:
		_apply_mask(modules, is_function, size, mask)
		_draw_format(modules, is_function, size, level, mask)
		var score := _penalty(modules, size)
		if score < best_score:
			best_score = score
			best_mask = mask
		_apply_mask(modules, is_function, size, mask) # (XOR again: undone)
	_apply_mask(modules, is_function, size, best_mask)
	_draw_format(modules, is_function, size, level, best_mask)
	return {"ok": true, "size": size, "modules": modules, "version": version, "level": level, "mask": best_mask, "error": "", "stream": stream}


static func _append_bits(bits: Array, value: int, count: int) -> void:
	for i in range(count - 1, -1, -1):
		bits.append((value >> i) & 1)


static func _put(modules: PackedByteArray, is_function: PackedByteArray, size: int, x: int, y: int, is_dark: bool) -> void:
	modules[y * size + x] = 1 if is_dark else 0
	is_function[y * size + x] = 1


static func _draw_function_patterns(modules: PackedByteArray, is_function: PackedByteArray, size: int, version: int) -> void:
	for i in size:
		_put(modules, is_function, size, 6, i, i % 2 == 0) # timing
		_put(modules, is_function, size, i, 6, i % 2 == 0)
	for centre in [Vector2i(3, 3), Vector2i(size - 4, 3), Vector2i(3, size - 4)]: # finders with their separators
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				var x: int = centre.x + dx
				var y: int = centre.y + dy
				if x >= 0 and y >= 0 and x < size and y < size:
					var dist := maxi(absi(dx), absi(dy))
					_put(modules, is_function, size, x, y, dist != 2 and dist != 4)
	var positions: Array = ALIGNMENT[version]
	for i in positions.size():
		for j in positions.size():
			if (i == 0 and j == 0) or (i == 0 and j == positions.size() - 1) or (i == positions.size() - 1 and j == 0):
				continue # where a finder is
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					_put(modules, is_function, size, int(positions[i]) + dx, int(positions[j]) + dy, maxi(absi(dx), absi(dy)) != 1)
	_draw_format(modules, is_function, size, Level.M, 0) # reserves the format areas (redrawn with the real mask later)
	if version >= 7: # version information, twice
		var rem := version
		for i in 12:
			rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
		var bits := (version << 12) | rem
		for i in 18:
			var is_dark := ((bits >> i) & 1) == 1
			var a := size - 11 + i % 3
			var c := i / 3
			_put(modules, is_function, size, a, c, is_dark)
			_put(modules, is_function, size, c, a, is_dark)


static func format_bits(level: int, mask: int) -> int:
	## The 15 format-information bits (error-correction level and mask, BCH-protected, XOR 0x5412).
	var data: int = (int(FORMAT_BITS[level]) << 3) | mask
	var rem := data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	return ((data << 10) | rem) ^ 0x5412


static func _draw_format(modules: PackedByteArray, is_function: PackedByteArray, size: int, level: int, mask: int) -> void:
	var bits := format_bits(level, mask)
	for i in range(0, 6):
		_put(modules, is_function, size, 8, i, ((bits >> i) & 1) == 1)
	_put(modules, is_function, size, 8, 7, ((bits >> 6) & 1) == 1)
	_put(modules, is_function, size, 8, 8, ((bits >> 7) & 1) == 1)
	_put(modules, is_function, size, 7, 8, ((bits >> 8) & 1) == 1)
	for i in range(9, 15):
		_put(modules, is_function, size, 14 - i, 8, ((bits >> i) & 1) == 1)
	for i in range(0, 8):
		_put(modules, is_function, size, size - 1 - i, 8, ((bits >> i) & 1) == 1)
	for i in range(8, 15):
		_put(modules, is_function, size, 8, size - 15 + i, ((bits >> i) & 1) == 1)
	_put(modules, is_function, size, 8, size - 8, true) # the always-dark module


static func _place_data(modules: PackedByteArray, is_function: PackedByteArray, size: int, stream: PackedByteArray) -> void:
	var i := 0
	var right := size - 1
	while right >= 1:
		if right == 6:
			right = 5
		for vert in size:
			for j in 2:
				var x := right - j
				var upward := ((right + 1) & 2) == 0
				var y := size - 1 - vert if upward else vert
				if is_function[y * size + x] == 0 and i < stream.size() * 8:
					modules[y * size + x] = (stream[i >> 3] >> (7 - (i & 7))) & 1
					i += 1
		right -= 2


static func _apply_mask(modules: PackedByteArray, is_function: PackedByteArray, size: int, mask: int) -> void:
	for y in size:
		for x in size:
			if is_function[y * size + x] == 1:
				continue
			var invert := false
			match mask:
				0: invert = (x + y) % 2 == 0
				1: invert = y % 2 == 0
				2: invert = x % 3 == 0
				3: invert = (x + y) % 3 == 0
				4: invert = (x / 3 + y / 2) % 2 == 0
				5: invert = x * y % 2 + x * y % 3 == 0
				6: invert = (x * y % 2 + x * y % 3) % 2 == 0
				7: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
			if invert:
				modules[y * size + x] ^= 1


static func _penalty(modules: PackedByteArray, size: int) -> int:
	var score := 0
	for horizontal in [true, false]:
		for a in size: # N1 (runs of five or more) and N3 (the finder-like 1011101 with four light on a side), along every row and column
			var line := PackedByteArray()
			for b in size:
				line.append(modules[(a * size + b) if horizontal else (b * size + a)])
			var run := 1
			for i in range(1, size):
				if line[i] == line[i - 1]:
					run += 1
					if run == 5:
						score += 3
					elif run > 5:
						score += 1
				else:
					run = 1
			for i in range(0, size - 6):
				if line[i] == 1 and line[i + 1] == 0 and line[i + 2] == 1 and line[i + 3] == 1 and line[i + 4] == 1 and line[i + 5] == 0 and line[i + 6] == 1:
					var before := true
					var after := true
					for k in range(1, 5):
						before = before and (i - k < 0 or line[i - k] == 0)
						after = after and (i + 6 + k >= size or line[i + 6 + k] == 0)
					if before or after:
						score += 40
	for y in range(0, size - 1): # N2: 2 x 2 blocks of one colour
		for x in range(0, size - 1):
			var c := modules[y * size + x]
			if modules[y * size + x + 1] == c and modules[(y + 1) * size + x] == c and modules[(y + 1) * size + x + 1] == c:
				score += 3
	var dark_count := 0
	for v in modules:
		dark_count += v
	var total := size * size
	var k := (absi(dark_count * 20 - total * 10) + total - 1) / total - 1 # N4: how far the dark share is from half, in 5% steps
	score += maxi(k, 0) * 10
	return score


# --- Reed-Solomon over GF(256), polynomial 0x11D ----------------------------------------------------------------------------------

static func _gf_multiply(x: int, y: int) -> int:
	var z := 0
	for i in range(7, -1, -1):
		z = (z << 1) ^ ((z >> 7) * 0x11D)
		z ^= ((y >> i) & 1) * x
	return z


static func _rs_divisor(degree: int) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(degree)
	result[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			result[j] = _gf_multiply(result[j], root)
			if j + 1 < degree:
				result[j] ^= result[j + 1]
		root = _gf_multiply(root, 0x02)
	return result


static func _rs_remainder(data: PackedByteArray, divisor: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(divisor.size())
	for b in data:
		var factor: int = b ^ result[0]
		result.remove_at(0)
		result.append(0)
		for i in divisor.size():
			result[i] ^= _gf_multiply(divisor[i], factor)
	return result
