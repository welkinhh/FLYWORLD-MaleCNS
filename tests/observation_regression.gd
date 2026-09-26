extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		errors.append(message)
		push_error(message)

func run() -> void:
	var scene := load("res://Main.tscn") as PackedScene
	var game = scene.instantiate()
	root.add_child(game)
	game.set_process(false)
	await process_frame
	await process_frame
	# Isolate world regressions from persisted user data and background services.
	check(game.test_mode, "Tests must not load or overwrite user saves")
	check(game.flies.size() == 8, "Fresh world must start with eight adults: four per color")
	for corner in [Vector2(48, 95), Vector2(835, 95), Vector2(48, 682), Vector2(835, 682)]:
		var safe: Vector2 = game._resolve_ground_collision(corner)
		var danger: Vector2 = game.ROOM_RECT.get_center()
		var escape: Vector2 = game._away_target(safe, danger)
		check(escape.distance_to(safe) >= 40, "Escape target collapses at edge")
		var fly: Dictionary = game.flies[0]
		fly["pos"] = safe
		fly["target"] = escape
		fly["action"] = "撤退"
		fly["flight"] = false
		fly["velocity"] = Vector2.ZERO
		fly["route"] = PackedVector2Array()
		for step in range(50):
			game._move_ground(0, 0.05)
		check(safe.distance_to(fly["pos"]) > 40, "Fly failed to leave edge in 2.5 seconds")
		check(not game._is_inside_blocking_furniture(fly["pos"]), "Fly entered blocking vegetation")
	# Every launch must land at a valid, reachable destination.
	for corner in [Vector2(48, 95), Vector2(835, 95), Vector2(48, 682), Vector2(835, 682)]:
		game.flies[0]["pos"] = game.FOOD_POS
		game.flies[0]["support_id"] = "ground"
		game.flies[0]["support_kind"] = "ground"
		game.flies[0]["support_height"] = 0.0
		game.flies[0]["flight_height"] = 0.0
		game._start_flight(0, corner)
		for step in range(100):
			if game.flies[0]["flight"]:
				game._update_flight(game.flies[0], 0.05)
		check(not game.flies[0]["flight"], "Flight never finished")
		game.flies[0]["action"] = "探索"
		game.flies[0]["target"] = game.FOOD_POS
		game.flies[0]["support_id"] = "ground"
		game.flies[0]["support_kind"] = "ground"
		game.flies[0]["support_height"] = 0.0
		game.flies[0]["route"] = PackedVector2Array()
		game.flies[0]["velocity"] = Vector2.ZERO
		var landed: Vector2 = game.flies[0]["pos"]
		for step in range(60):
			game._move_ground(0, 0.05)
		check(game.ROOM_RECT.grow(-game.ROOM_MARGIN).has_point(game.flies[0]["pos"]), "Landing left the garden bounds")
		check(not game._is_inside_blocking_furniture(game.flies[0]["pos"]), "Landing ended inside blocking vegetation")
	# Alternating routine states must not flood the event list.
	game.flies[0]["recent_events"] = []
	var before: int = game.event_log.size()
	for i in range(50):
		game._record_fly_event(0, "探索", "test")
		game._record_fly_event(0, "进食", "test")
	check(game.event_log.size() - before == 2, "Repeated routine events were not deduplicated")
	# No high-level proxy signal may illuminate morphology.
	game.brain_view.set_catalog(game.adult_brain_catalog, "adult")
	check(game.brain_view.full_brain_instance != null, "adult whole-brain backdrop is missing")
	check(game.brain_view.connectome_edges_instance == null, "hidden connectome edge LOD should not block startup")
	check(game.brain_view.full_brain_positions.size() > 100000, "adult whole-brain position coverage is unexpectedly small")
	game.brain_view.set_activity({"sugar": 1.0, "threat": 1.0, "motor": 1.0}, {})
	for material in game.brain_view.active_neuron_materials.values():
		check(is_equal_approx(material.emission_energy_multiplier, 0.35), "Proxy signal leaked into morphology")
	# A deterministic fixture validates rendering; Python tests exercise the model.
	var fixture_id := str(game.larva_brain_catalog.get("neurons", [])[0].get("neuron_id", "29"))
	var activity: Dictionary = {"dataset_id": "Winding2023-L1EM", "request_seq": 1, "spike_ids": [fixture_id]}
	game.brain_view.set_catalog(game.larva_brain_catalog, "larva")
	game.brain_view.set_activity({}, activity)
	var lit := false
	for material in game.brain_view.active_neuron_materials.values():
		lit = lit or material.emission_energy_multiplier > 0.4
	check(lit, "Larval activity fixture not rendered")
	game.brain_view.set_catalog(game.adult_brain_catalog, "adult")
	game.brain_view.set_activity({}, activity)
	check(game.brain_view.last_activity.is_empty(), "Larval activity leaked into adult view")
	game.brain_view.set_catalog(game.larva_brain_catalog, "larva")
	game.brain_view.set_activity({}, activity)
	await process_frame
	check(game.brain_view.full_brain_instance == null, "Adult point cloud survived larval switch")
	check(game.brain_view.connectome_edges_instance == null, "Adult connectome edges survived larval switch")
	# Capture a clean new-world diorama; in headless mode verify transforms only.
	game._reset_flies()
	game.brain_view_stage = ""
	game.paused = true
	game._process(0.12)
	game.garden_view.sync_state(game.flies, [], game.foods, str(game.flies[0]["id"]), 0.016, true, 65, game.world_uuid, game.terrain_surfaces)
	game._refresh_ui()
	await process_frame
	await process_frame
	check(game.brain_view.tooltip_text.is_empty(), "brain view still exposes an explanatory tooltip")
	var panel_height: float = game.runtime_panel_rect.size.y
	var state_height: float = minf(game.SIDEBAR_STATE_HEIGHT, maxf(74.0, panel_height * 0.18))
	var event_height: float = minf(game.SIDEBAR_EVENT_HEIGHT, maxf(92.0, panel_height * 0.22))
	var expected_brain_height: float = maxf(180.0, panel_height - state_height - event_height - game.SIDEBAR_CONTROLS_HEIGHT)
	check(is_equal_approx(game.brain_view.size.y, expected_brain_height), "Brain frame did not fill the sidebar middle region")
	check(is_equal_approx(game.brain_view.position.x, game.runtime_panel_rect.position.x), "Brain frame retained a side gap")
	check(game.brain_view.position.y + game.brain_view.size.y <= game.runtime_panel_rect.end.y - game.SIDEBAR_CONTROLS_HEIGHT + 0.1, "Brain frame overlaps action row")
	check(game.actions_container.get_child_count() == 4, "Sidebar action row must contain four aligned buttons")
	check(game.brain_control_button.text == "连接大脑", "Disconnected brain action must be labeled 连接大脑")
	check(game.runtime_garden_rect.end.y >= game.get_viewport_rect().size.y - 0.1, "Footer strip still reduces the full-screen garden")
	check(game.pause_button.get_global_rect().end.x <= 1248, "Transport exceeds top bar")
	check(game.light_slider.get_global_rect().end.x <= 1248, "Environment controls exceed top bar")
	# Projection/inverse projection must agree, preventing click/placement offsets.
	var ground: Vector2 = game.FOOD_POS + Vector2(100, 80)
	var point3d: Vector3 = game.garden_view.to_world(ground)
	var screen: Vector2 = game.garden_view.global_position + game.garden_view.camera.unproject_position(point3d)
	check(game.garden_view.screen_to_ground(screen).distance_to(ground) < 0.1, "3D ground picking is misaligned")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/observation_25d.png")
	print("OBSERVATION_REGRESSION ", JSON.stringify({"failures": errors, "tests": "four-corner escape, landing, event dedup, larval rendering fixture, proxy rejection, stage switching, layout, 3D picking"}))
	game.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)
