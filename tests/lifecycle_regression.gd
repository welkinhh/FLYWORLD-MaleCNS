extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func run() -> void:
	var game := (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.set_process(false)
	check(game.flies.size() == 8, "fresh population is not four adults per color")
	check(game.speed_multiplier == 1.0, "default ecological speed is not x1")
	check(game.foods.size() == 2, "fresh world does not have two bananas")
	check(game.STAGE_DURATIONS["egg"] == 30.0 and game.STAGE_DURATIONS["larva"] == 45.0 and game.STAGE_DURATIONS["pupa"] == 15.0, "stage clocks are not 30/45/15")
	var max_active := 0
	var max_generation := 0
	for step in range(520):
		game._simulate_step(1.0)
		max_active = max(max_active, game._active_count())
		for fly in game.flies:
			if bool(fly.get("alive", true)):
				max_generation = max(max_generation, int(fly.get("generation", 0)))
	check(max_active <= game.ACTIVE_CAPACITY, "active population exceeded 30")
	check(max_generation >= 3, "fixed-seed run did not reach third generation")
	for fly in game.flies:
		if bool(fly.get("alive", true)) and str(fly.get("life_stage", "")) == "adult" and int(fly.get("generation", 0)) > 0:
			check(str(fly.get("sex", "未知")) in ["雄", "雌"], "adult offspring retained unknown sex")
	print("LIFECYCLE_REGRESSION ", JSON.stringify({"failures": failures, "max_active": max_active, "max_generation": max_generation, "sim_time": game.sim_time}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
