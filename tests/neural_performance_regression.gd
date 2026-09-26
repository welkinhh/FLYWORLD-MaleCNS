extends SceneTree

## Short integrated frame-time check after MaleCNS warm-up.
## The 30-minute wall-clock harness validates service longevity; this fixture
## records the actual render loop with the 30-fly stress population enabled.

const WARMUP_SECONDS := 75.0
const SAMPLE_FRAMES := 240


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var game = (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	var bridge_seen := false
	await process_frame
	# The normal 30-population stress switch intentionally mixes life stages.
	# For a render/service ceiling test use thirty adults so every actor and
	# every wing/brain path remains active during the sample window.
	for i in range(maxi(0, game.ACTIVE_CAPACITY - game.flies.size())):
		var fly: Dictionary = game._make_fly(game._next_fly_id(), game._random_walk_target(game.FOOD_POS), Color.CORAL, 0.2, 0.1, 0.4, "赤枝" if i % 2 == 0 else "青苔", "雄" if i % 2 == 0 else "雌", "adult")
		fly["stage_age"] = 20.0
		game.flies.append(fly)
	game.selected_index = 0
	var warmup_start := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - warmup_start) / 1000.0 < WARMUP_SECONDS:
		await process_frame
		bridge_seen = bridge_seen or game.neural_adapter.bridge_state == "malecns"
	var frame_ms: Array[float] = []
	var previous := Time.get_ticks_usec()
	for _index in range(SAMPLE_FRAMES):
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append(float(now - previous) / 1000.0)
		previous = now
	frame_ms.sort()
	var total := 0.0
	for value in frame_ms:
		total += value
	var p95 := frame_ms[int(frame_ms.size() * 0.95)] if not frame_ms.is_empty() else 0.0
	var result := {
		"population": game._active_count(),
		"bridge_state": game.neural_adapter.bridge_state,
		"bridge_seen": bridge_seen,
		"frames": frame_ms.size(),
		"average_fps": 1000.0 / maxf(total / maxf(frame_ms.size(), 1), 0.001),
		"frame_ms_p95": p95,
		"target_p95_ms": 33.3,
		"pass": p95 <= 33.3 and bridge_seen,
	}
	print("NEURAL_PERFORMANCE_REGRESSION ", JSON.stringify(result))
	var file := FileAccess.open("res://build/neural_performance_regression.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result))
	game.queue_free()
	quit(0 if bool(result["pass"]) else 1)
