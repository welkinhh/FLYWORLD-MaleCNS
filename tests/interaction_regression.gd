extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func click(game: Node, point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = point
	game._input(event)

func screen_for(game: Node, ground: Vector2) -> Vector2:
	return game.garden_view.global_position + game.garden_view.camera.unproject_position(game.garden_view.to_world(ground))

func run() -> void:
	var game = (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.set_process(false)
	check(game.test_mode, "Interaction tests require isolated mode")
	game.paused = true
	for i in range(game.flies.size()):
		game.flies[i]["pos"] = Vector2(220 + i * 65, 430)
		game.flies[i]["render_pos"] = game.flies[i]["pos"]
	game._process(0.0)
	var selected_id: String = str(game.flies[3]["id"])
	var actor: Node3D = game.garden_view.actors[selected_id]
	var selected_screen: Vector2 = game.garden_view.global_position + game.garden_view.camera.unproject_position(actor.position + Vector3(0, 0.16, 0))
	click(game, selected_screen)
	check(game.selected_index == 3, "Clicking an ID string selected the wrong array index")
	var empty_screen := screen_for(game, Vector2(480, 550))
	check(game.garden_view.pick_fly(empty_screen).is_empty(), "Empty-click fixture overlaps a fly")
	click(game, empty_screen)
	check(game.selected_index == 3, "Empty clicks changed selection")

	var ground := Vector2(510, 490)
	var point := screen_for(game, ground)
	var previous_food_count: int = game.foods.size()
	game._on_sugar_pressed()
	click(game, point)
	check(game.foods.size() == previous_food_count + 1, "Sugar placement did not create edible food")
	if game.foods.size() > previous_food_count:
		var candy: Dictionary = game.foods.back()
		check(candy["center"].distance_to(ground) < 0.1, "Candy location differs from the clicked ground")
		candy["amount"] = 0.0
		var with_empty_candy: float = game._sugar_signal(ground)
		game.foods.pop_back()
		check(is_equal_approx(with_empty_candy, game._sugar_signal(ground)), "Consumed candy retains a phantom scent")

	game._on_predator_pressed()
	click(game, point)
	check(game.predators.size() == 1, "Predator placement failed")
	game._process(0.0)
	if not game.predators.is_empty():
		var spider: Node3D = game.garden_view.spider_nodes[0]
		var spider_screen: Vector2 = game.garden_view.global_position + game.garden_view.camera.unproject_position(spider.position + Vector3(0, 0.18, 0))
		game._on_delete_predator_pressed()
		click(game, spider_screen)
		check(game.predators.is_empty(), "Clicking a spider did not delete it")

	var wheel := InputEventMouseButton.new()
	wheel.position = point
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	var before_zoom: float = game.garden_view.camera.size
	game._input(wheel)
	check(is_equal_approx(game.garden_view.camera.size, before_zoom), "Main handler duplicates camera zoom")
	game.garden_view._gui_input(wheel)
	check(is_equal_approx(game.garden_view.camera.size, before_zoom - 0.55), "Wheel-up does not zoom in exactly once")
	game.sim_time = 123.0
	game.sim_accumulator = 0.04
	game.paused = false
	game._on_pause_pressed()
	game._on_new_round_pressed()
	check(game.sim_time == 0.0 and game.sim_accumulator == 0.0, "Restart retains the old clock")
	check(game._display_name(game.flies[0]["id"]) == "01", "Restart did not reset IDs")
	check(not game.paused and game.pause_button.text == "暂停", "Restart retained the paused UI")
	print("INTERACTION_REGRESSION ", JSON.stringify({"failures": failures}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
