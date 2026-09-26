extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var game = (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	game.set_process(false)
	await process_frame
	for i in range(maxi(0, game.ACTIVE_CAPACITY - game.flies.size())):
		var fly: Dictionary = game._make_fly(game._next_fly_id(), game._random_walk_target(game.FOOD_POS), Color.CORAL, 0.2, 0.1, 0.4, "赤枝" if i % 2 == 0 else "青苔", "雄", "adult")
		game.flies.append(fly)
	game.set_process(true)
	var times: Array[float] = []
	var last := Time.get_ticks_usec()
	for i in range(240):
		await process_frame
		var now := Time.get_ticks_usec()
		if i >= 60:
			times.append(float(now - last) / 1000.0)
		last = now
	times.sort()
	var sum := 0.0
	for duration in times:
		sum += duration
	var result := {"adults": 30, "frames": times.size(), "average_fps": 1000.0 / (sum / times.size()), "frame_ms_p95": times[int(times.size() * 0.95)], "backend": DisplayServer.get_name(), "alive": game._active_count()}
	print("OBSERVATION_PERFORMANCE ", JSON.stringify(result))
	var file := FileAccess.open("res://build/observation_performance.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	game.queue_free()
	await process_frame
	quit()
