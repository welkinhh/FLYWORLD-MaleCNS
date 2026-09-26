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
	var seed_count := 3
	var duration_seconds := 300.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--flyworld-seeds="):
			seed_count = int(argument.get_slice("=", 1))
		elif argument.begins_with("--flyworld-duration="):
			duration_seconds = float(argument.get_slice("=", 1))
	if seed_count < 1 or seed_count > 100 or duration_seconds < 300.0 or duration_seconds > 3600.0:
		push_error("Use 1..100 seeds and 300..3600 simulated seconds")
		quit(1)
		return
	var seed_results: Array = []
	for seed_offset in range(seed_count):
		game.rng.seed = 17010914 + seed_offset
		game._reset_flies()
		var max_active := 0
		var max_generation := 0
		var births := 0
		var previous_ids := {}
		for fly in game.flies:
			previous_ids[str(fly["id"])] = true
		for step in range(int(duration_seconds / 0.05)):
			game._simulate_step(0.05)
			max_active = maxi(max_active, game._active_count())
			var ids := {}
			for fly in game.flies:
				var id := str(fly["id"])
				if ids.has(id):
					failures.append("seed %d duplicate %s" % [seed_offset, id])
				ids[id] = true
				if bool(fly.get("alive", true)):
					max_generation = maxi(max_generation, int(fly.get("generation", 0)))
			for id in ids:
				if not previous_ids.has(id):
					births += 1
			previous_ids = ids
		var passed: bool = max_active <= game.ACTIVE_CAPACITY and max_generation >= 3 and births > 0
		if not passed:
			failures.append("seed %d max=%d generation=%d births=%d" % [seed_offset, max_active, max_generation, births])
		seed_results.append({"seed": 17010914 + seed_offset, "max_active": max_active, "max_generation": max_generation, "births": births, "final_population": game._active_count()})
		print("LIFECYCLE_SEED ", JSON.stringify(seed_results.back()))
	print("LIFECYCLE_MULTISEED_REGRESSION ", JSON.stringify({"failures": failures, "seeds": seed_results}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
