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
	check(game.terrain_surfaces.size() >= 8, "terrain support registry is incomplete")
	var surface: Dictionary = game.terrain_surfaces[0]
	var surface_point: Vector2 = surface.get("a", surface.get("center", Vector2.ZERO))
	var projection: Dictionary = game._surface_projection(surface_point, surface)
	check(float(projection["distance"]) < 0.01, "branch projection is not on the segment")
	var fly: Dictionary = game.flies[0]
	fly["pos"] = Vector2(470, 390)
	fly["target"] = surface_point
	game.flies[0] = fly
	game._start_flight(0, surface_point)
	for _step in range(100):
		if game.flies[0]["flight"]:
			game._update_flight(game.flies[0], 0.05)
	check(not game.flies[0]["flight"], "fly never finished branch landing")
	check(str(game.flies[0].get("support_id", "ground")) != "ground", "fly landed without a leaf/branch support")
	check(float(game.flies[0].get("support_height", 0.0)) > 0.0, "landing support height was not recorded")
	var spider := {
		"kind": "spider",
		"pos": surface_point + Vector2(-20, 10),
		"velocity": Vector2.ZERO,
		"facing": 1.0,
		"support_id": "ground",
		"support_height": 0.0,
		"threat_radius": 150.0,
		"cooldown": 999.0,
		"wander_phase": 0.0,
		"alive": true,
	}
	game.predators.append(spider)
	for _step in range(60):
		game._update_predators(0.05)
	var spider_pos: Vector2 = game.predators[0]["pos"]
	check(game.ROOM_RECT.grow(-game.ROOM_MARGIN).has_point(spider_pos), "spider left the garden bounds")
	check(spider_pos.x == spider_pos.x and spider_pos.y == spider_pos.y, "spider position became non-finite")
	print("SURFACE_REGRESSION ", JSON.stringify({"failures": failures, "surfaces": game.terrain_surfaces.size(), "fly_support": game.flies[0].get("support_id", ""), "spider_support": game.predators[0].get("support_id", "")}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
