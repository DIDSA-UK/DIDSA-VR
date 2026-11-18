extends Control
## P0 voice spike (docs/live-sessions-spikes.md, "Spike V"): microphone -> Opus (TwoVoip) -> WebSocket -> relay -> Opus -> speaker, on
## a Quest 3 (as a 2D panel app) and an Android phone. Every 5 s one `DIDSA VR: voice:` line (adb logcat) and the same text on screen:
## frames sent / received / lost / late, the echo round trip (p50 / p95), bandwidth, the jitter buffer, the mic level.
##
## Frames use the session scope's voice framing (DIDSA-CAD docs/live-sessions-scope.md 4.6): byte 0 version (1), byte 1 sender id (the
## relay writes it), bytes 2-3 sequence (big-endian), byte 4 flags (bit 1: a TwoVoip JSON header / footer, not Opus), then the payload.
## The script must parse without the add-on (it then says how to install it), so TwoVoip's classes are reached by name only.

const VERSION := 1
const HEADER := 5
const FLAG_CONTROL := 2
const REPORT_EVERY_S := 5.0
const SETTINGS := "user://voice_spike.cfg"
const MIC_SCENE := "res://addons/twovoip/voiphelper/two_voip_mic.tscn"
const SPEAKER_SCENE := "res://addons/twovoip/voiphelper/two_voip_speaker.tscn"

var ws := WebSocketPeer.new()
var my_id := -1
var mic: Node
var speakers: Dictionary = {} ## sender id -> TwoVoipSpeaker
var seq := 0
var sent_at: Dictionary = {} ## seq -> usec, for the echo round trip
var rtts: PackedFloat32Array = PackedFloat32Array()
var last_seq: Dictionary = {} ## sender id -> last sequence seen
var counts := {"sent": 0, "received": 0, "lost": 0, "late": 0, "bytes_out": 0, "bytes_in": 0}
var _report_left := REPORT_EVERY_S
var _cfg := ConfigFile.new()

var _url: LineEdit
var _status: Label
var _report: Label
var _talk: Button
var _vox: CheckButton
var _mic_on: CheckButton
var _play_echo: CheckButton
var _lag: SpinBox


func _ready() -> void:
	_cfg.load(SETTINGS)
	_build_ui()
	_log("start: %s %s, Godot %s, TwoVoip %s, input devices %s, input mix rate %d" % [OS.get_name(), OS.get_model_name(),
		Engine.get_version_info()["string"], "loaded" if ClassDB.class_exists("TwovoipOpusEncoder") else "MISSING", AudioServer.get_input_device_list(),
		AudioServer.get_input_mix_rate()])
	if OS.get_name() == "Android":
		_log("permissions granted at start: %s" % [OS.get_granted_permissions()])
	if not ClassDB.class_exists("TwovoipOpusEncoder"):
		_status.text = "TwoVoip is not installed: run tools/install_voip_plugin.sh, open this project once in the editor, export again."
		return
	mic = load(MIC_SCENE).instantiate()
	add_child(mic)
	mic.init_voip_mic(true, _mic_on, null, _talk, _vox, null)
	var ok: bool = mic.set_opus_values(48000, 20, 1, 24000, 5, true, _const("DENOISER_RNNOISE"), _const("AGC_APPLIED"))
	_log("Opus encoder: 48 kHz mono, 20 ms frames, 24 kbit/s, complexity 5, RNNoise, AGC: %s" % ("ok" if ok else "FAILED"))
	mic.transmit_audio_packet.connect(_on_packet)
	get_tree().on_request_permissions_result.connect(func(p: String, granted: bool) -> void: _log("permission %s: %s" % [p, "granted" if granted else "REFUSED"]))


func _const(name: String) -> int:
	return ClassDB.class_get_integer_constant("TwovoipOpusEncoder", name)


# --- sending and receiving --------------------------------------------------------------------------------------------------------

func _on_packet(packet: PackedByteArray) -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var flags := FLAG_CONTROL if packet.size() > 0 and packet[0] == 123 else 0 # '{': a TwoVoip JSON header / footer
	var frame := PackedByteArray([VERSION, 0, (seq >> 8) & 255, seq & 255, flags])
	frame.append_array(packet)
	sent_at[seq] = Time.get_ticks_usec()
	if sent_at.size() > 2000:
		sent_at.erase(sent_at.keys()[0])
	seq = (seq + 1) & 0xFFFF
	ws.send(frame, WebSocketPeer.WRITE_MODE_BINARY)
	counts["sent"] += 1
	counts["bytes_out"] += frame.size()


func _process(delta: float) -> void:
	ws.poll()
	while ws.get_ready_state() == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
		var was_text := ws.was_string_packet()
		var data := ws.get_packet()
		if was_text or (data.size() > 0 and data[0] == 123):
			var msg = JSON.parse_string(data.get_string_from_utf8())
			if msg is Dictionary and msg.get("t") == "hello":
				my_id = int(msg["id"])
				_log("relay says my id is %d" % my_id)
			continue
		_on_frame(data)
	_report_left -= delta
	if _report_left <= 0.0:
		_report_left = REPORT_EVERY_S
		report()


func _on_frame(data: PackedByteArray) -> void:
	if data.size() <= HEADER or data[0] != VERSION:
		return
	var sender := int(data[1])
	var n := (int(data[2]) << 8) | int(data[3])
	counts["received"] += 1
	counts["bytes_in"] += data.size()
	if sender == my_id and sent_at.has(n):
		rtts.append((Time.get_ticks_usec() - int(sent_at[n])) / 1000.0)
		sent_at.erase(n)
	if last_seq.has(sender):
		var gap := (n - int(last_seq[sender]) + 65536) % 65536
		if gap == 0 or gap > 32768:
			counts["late"] += 1
			return
		counts["lost"] += gap - 1
	last_seq[sender] = n
	if sender == my_id and not _play_echo.button_pressed:
		return
	_speaker_for(sender).receive_audio_packet(data.slice(HEADER))


func _speaker_for(sender: int) -> Node:
	if not speakers.has(sender):
		var player := AudioStreamPlayer.new()
		player.name = "Player%d" % sender
		add_child(player)
		var speaker: Node = load(SPEAKER_SCENE).instantiate()
		speaker.audio_buffer_lag_time_target = _lag.value
		player.add_child(speaker) # TwoVoipSpeaker plays through its parent when the parent is the player
		speakers[sender] = speaker
	return speakers[sender]


func report() -> void:
	var p50 := 0.0
	var p95 := 0.0
	if not rtts.is_empty():
		var sorted := rtts.duplicate()
		sorted.sort()
		p50 = sorted[sorted.size() / 2]
		p95 = sorted[mini(sorted.size() - 1, int(ceil(sorted.size() * 0.95)) - 1)]
	var buffers := PackedStringArray()
	for sender in speakers:
		var playback = speakers[sender].audio_stream_playback_opus
		if playback != null:
			buffers.append("%d: %.0f ms" % [sender, 1000.0 * playback.queue_length_frames() / 48000.0])
	var level: float = mic.last_chunkmax if mic != null else 0.0
	var text := "sent %d, received %d, lost %d, late %d | echo round trip p50 %.0f ms, p95 %.0f ms (%d) | out %.1f kbit/s, in %.1f kbit/s | jitter buffer %s (target %.2f s) | mic level %.3f%s | %d fps" % [
		counts["sent"], counts["received"], counts["lost"], counts["late"], p50, p95, rtts.size(),
		counts["bytes_out"] * 8.0 / 1000.0 / REPORT_EVERY_S, counts["bytes_in"] * 8.0 / 1000.0 / REPORT_EVERY_S,
		", ".join(buffers) if not buffers.is_empty() else "none", _lag.value, level, " (talking)" if mic != null and mic.currentlytalking else "",
		Engine.get_frames_per_second()]
	counts["bytes_out"] = 0
	counts["bytes_in"] = 0
	rtts = PackedFloat32Array()
	_log(text)
	_report.text = text.replace(" | ", "\n")


# --- the encode benchmark (V4) ----------------------------------------------------------------------------------------------------

func encode_benchmark(frames: int = 500) -> Dictionary:
	## Encodes `frames` 20 ms chunks of a 440 Hz tone (48 kHz mono, 24 kbit/s, complexity 5, RNNoise) and times each chunk's
	## process + encode. Returns {ok, frames, mean_us, worst_us, bytes_per_frame}.
	if not ClassDB.class_exists("TwovoipOpusEncoder"):
		return {"ok": false}
	var enc: Object = ClassDB.instantiate("TwovoipOpusEncoder")
	if enc.initialize(48000, 48000, 1, _const("DENOISER_RNNOISE"), _const("AGC_DISABLED"), 960) != OK or not enc.create_opus_encoder(24000, 5, true):
		return {"ok": false}
	var size: int = enc.get_required_input_chunk_size()
	var chunk := PackedVector2Array()
	chunk.resize(size)
	var total := 0
	var worst := 0
	var bytes := 0
	for f in frames:
		for i in size:
			var v := 0.3 * sin(TAU * 440.0 * float(f * size + i) / 48000.0)
			chunk[i] = Vector2(v, v)
		var t0 := Time.get_ticks_usec()
		enc.process_chunk(chunk)
		var packet: PackedByteArray = enc.encode_chunk(PackedByteArray(), 0)
		var took := Time.get_ticks_usec() - t0
		total += took
		worst = maxi(worst, took)
		bytes += packet.size()
	return {"ok": true, "frames": frames, "mean_us": total / frames, "worst_us": worst, "bytes_per_frame": bytes / frames}


# --- the screen -------------------------------------------------------------------------------------------------------------------

func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 24)
	box.add_theme_constant_override("separation", 10)
	add_child(box)
	var title := Label.new()
	title.text = "DIDSA voice spike (P0). Relay: python3 spikes/voice/echo_relay.py --echo on the PC."
	box.add_child(title)
	_url = LineEdit.new()
	_url.text = str(_cfg.get_value("relay", "url", "ws://192.168.1.10:8301/ws"))
	_url.custom_minimum_size = Vector2(0, 64)
	box.add_child(_url)
	var row := HBoxContainer.new()
	box.add_child(row)
	_add_button(row, "Connect", _connect)
	_add_button(row, "Encode benchmark (V4)", func() -> void:
		var r := encode_benchmark()
		_log("encode benchmark: %s" % ("%d frames of 20 ms, mean %d us, worst %d us, %d bytes a frame" % [r["frames"], r["mean_us"], r["worst_us"], r["bytes_per_frame"]] if r["ok"] else "TwoVoip missing or failed")))
	_talk = Button.new()
	_talk.text = "Hold to talk"
	_talk.custom_minimum_size = Vector2(0, 120)
	box.add_child(_talk)
	_vox = CheckButton.new()
	_vox.text = "Open mic (voice activation, no button)"
	box.add_child(_vox)
	_mic_on = CheckButton.new()
	_mic_on.text = "Microphone on"
	_mic_on.toggle_mode = true
	_mic_on.button_pressed = true
	box.add_child(_mic_on)
	_play_echo = CheckButton.new()
	_play_echo.text = "Play my own voice back (relay --echo)"
	_play_echo.button_pressed = true
	box.add_child(_play_echo)
	var lag_row := HBoxContainer.new()
	box.add_child(lag_row)
	var lag_label := Label.new()
	lag_label.text = "Jitter buffer target (s; TwoVoip's default 0.6) "
	lag_row.add_child(lag_label)
	_lag = SpinBox.new()
	_lag.min_value = 0.05
	_lag.max_value = 1.0
	_lag.step = 0.05
	_lag.value = float(_cfg.get_value("speaker", "lag", 0.2))
	_lag.value_changed.connect(func(v: float) -> void:
		for s in speakers.values():
			s.audio_buffer_lag_time_target = v
		_cfg.set_value("speaker", "lag", v)
		_cfg.save(SETTINGS))
	lag_row.add_child(_lag)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_report = Label.new()
	_report.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_report)


func _add_button(parent: Control, label: String, action: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 80)
	b.pressed.connect(action)
	parent.add_child(b)


func _connect() -> void:
	_cfg.set_value("relay", "url", _url.text.strip_edges())
	_cfg.save(SETTINGS)
	ws = WebSocketPeer.new()
	var err := ws.connect_to_url(_url.text.strip_edges())
	_log("connecting to %s: %s" % [_url.text.strip_edges(), error_string(err)])


func _log(text: String) -> void:
	print("DIDSA VR: voice: ", text)
	if _status != null:
		_status.text = text
