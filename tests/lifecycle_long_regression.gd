extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func run() -> void:
	var game := (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.set_process(false)
	check(game.test_mode, "long lifecycle regression must use isolated mode")
	var max_active := 0
	var max_generation := 0
	var births := 0
	var previous_ids := {}
	for fly in game.flies:
		previous_ids[str(fly["id"])] = true
	for step in range(24000): # 1,200 seconds at the production 50 ms tick.
		game._simulate_step(0.05)
		max_active = maxi(max_active, game._active_count())
		var ids := {}
		for fly in game.flies:
			var id := str(fly["id"])
			check(not ids.has(id), "duplicate ID during long lifecycle")
			ids[id] = true
			if bool(fly.get("alive", true)):
				max_generation = maxi(max_generation, int(fly.get("generation", 0)))
		for id in ids:
			if not previous_ids.has(id):
				births += 1
		previous_ids = ids
	check(max_active <= game.ACTIVE_CAPACITY, "long lifecycle exceeded capacity")
	check(max_generation >= 3, "long lifecycle did not produce third generation")
	check(births > 0, "long lifecycle produced no offspring")
	print("LIFECYCLE_LONG_REGRESSION ", JSON.stringify({"failures": failures, "max_active": max_active, "max_generation": max_generation, "births": births, "sim_time": game.sim_time, "final_population": game._active_count()}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
