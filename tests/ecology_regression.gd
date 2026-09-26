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
	check(game.test_mode, "ecology regression must run in isolated test mode")
	check(is_equal_approx(game.speed_multiplier, 1.0), "default speed must be x1")
	check(game.foods.size() == 2, "fresh world must have two banana foods")

	# Feeding must overcome the corresponding metabolism rate.
	var adult: Dictionary = game.flies[0]
	adult["pos"] = game.foods[0]["surfaces"][0]["pos"]
	adult["hunger"] = 0.6
	game.flies[0] = adult
	var adult_before := float(adult["hunger"])
	game._consume_food_at(0, 1.0, 0.18)
	check(float(game.flies[0]["hunger"]) < adult_before - 0.0014, "adult feeding does not overcome metabolism")

	# Two candy placements must have independent stable IDs.
	var candy_a: Dictionary = game._make_sugar_food(Vector2(470, 470))
	var candy_b: Dictionary = game._make_sugar_food(Vector2(560, 560))
	check(str(candy_a["id"]) != str(candy_b["id"]), "candy IDs are duplicated")

	# InputEventKey must never reach mouse-position handling.
	game.tool_mode = "sugar"
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	game._input(escape)
	check(game.tool_mode.is_empty(), "Escape did not cancel active tool")

	# Birth after a dead slot before the parents must preserve every live ID.
	game.flies.clear()
	for i in range(30):
		var fly: Dictionary = game._make_fly("TEST-%03d" % i, Vector2(450, 430), Color.WHITE, 0.2, 0.1, 0.5, "赤枝", "雌" if i % 2 == 0 else "雄", "adult")
		fly["stage_age"] = 20.0
		fly["reproduction_cooldown"] = 0.0 if i in [1, 2] else 1000.0
		fly["mating_timer"] = 1.0
		fly["alive"] = i != 0
		game.flies.append(fly)
	game._update_reproduction()
	var ids := {}
	for fly in game.flies:
		ids[str(fly["id"])] = true
	check(ids.size() == game.flies.size(), "birth transaction created duplicate or lost ID")
	check(ids.has("TEST-029"), "birth transaction lost a live record after slot reclaim")

	print("ECOLOGY_REGRESSION ", JSON.stringify({"failures": failures, "unique_ids": ids.size(), "population": game.flies.size()}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
