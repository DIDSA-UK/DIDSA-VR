extends SceneTree
## Desktop timing of the GDScript local retraction (tight loop, headless): see scripts/local_retraction_bench.gd. NOT a pass/fail test:
## it prints `SMOKE BENCH` lines (microseconds per call) for the cases below and the projector's own frame as the reference.
## Run: "$GODOT" --headless --path . --script res://tests/bench_local_retraction.gd [-- --calls=2000]
## The numbers that matter are the ones from the HEADSET (scenes/bench_local_retraction.tscn): see docs/local-retraction-benchmark.md.
const Bench := preload("res://scripts/local_retraction_bench.gd")


func _initialize() -> void:
	var calls := 2000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--calls="):
			calls = int(a.substr(8))
	var b = Bench.new()
	if not b.setup(true):
		print("SMOKE FAILED: could not set up the benchmark cases")
		quit(1)
		return
	for _i in 200: # warm-up (the GDScript VM, caches)
		b.run_once()
	b.clear()
	for _i in calls:
		b.run_once()
	for line in b.report("desktop "):
		print(line)
	print("SMOKE BENCH done: ", calls, " calls per case on ", OS.get_name(), " ", OS.get_processor_name(), " (", OS.get_processor_count(), " threads)")
	quit(0)
