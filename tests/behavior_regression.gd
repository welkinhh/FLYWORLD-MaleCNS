extends SceneTree

var failures: Array[String] = []

class FakeAdapter extends RefCounted:
	var bridge_state := "malecns"
	var reconnect_requested := false
	var last_bridge_error := ""
	var calls := 0
	func poll_bridge() -> void: pass
	func begin_tick() -> void: pass
	func set_selection(_id: String, _stage: String) -> void: pass
	func clear_selection() -> void: pass
	func disconnect_bridge() -> void: pass
	func create_state() -> Dictionary:
		return {"sugar": 0.0, "bitter": 0.0, "approach": 0.0, "threat": 0.0, "motor": 0.0}
	func step(previous: Dictionary, _inputs: Dictionary, _dt: float) -> Dictionary:
		calls += 1
		return previous
	func take_activity(_id: String) -> Dictionary: return {}
	func is_bridge_active() -> bool: return true

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func run() -> void:
	var game = (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	game.set_process(false)
	await process_frame
	await process_frame
	check(game.test_mode, "behavior regression must use isolated mode")
	# Fresh pairs must actually enter courtship and lay an egg quickly enough
	# for a normal observer to see the population change.
	game._reset_flies()
	var initial_ids := {}
	for fresh_fly in game.flies:
		initial_ids[str(fresh_fly["id"])] = true
	for _birth_step in range(400):
		game._simulate_step(0.05)
	var first_birth_seen := false
	for fresh_fly in game.flies:
		if not initial_ids.has(str(fresh_fly["id"])):
			first_birth_seen = true
	check(first_birth_seen, "fresh breeding pairs did not produce an offspring within 20 simulated seconds")
	# Spiders must not stall in the old 27-28 px gap, and must reach adults
	# resting on raised leaves/branches as well as on ground.
	for prey_case in [
		{"distance": 27.5, "height": 0.0, "name": "capture-radius boundary"},
		{"distance": 20.0, "height": 0.48, "name": "raised branch prey"},
	]:
		game._reset_flies()
		var predator_test_fly: Dictionary = game.flies[0]
		predator_test_fly["pos"] = Vector2(500.0 + float(prey_case["distance"]), 500.0)
		predator_test_fly["render_pos"] = predator_test_fly["pos"]
		predator_test_fly["alive"] = true
		predator_test_fly["flight"] = false
		predator_test_fly["flight_height"] = 0.0
		predator_test_fly["support_height"] = float(prey_case["height"])
		game.flies = [predator_test_fly]
		game.predators = [{"pos": Vector2(500, 500), "support_height": 0.0, "threat_radius": 150.0, "cooldown": 0.0, "wander_phase": 0.0, "alive": true}]
		game._update_predators(0.05)
		check(not bool(game.flies[0]["alive"]), "spider failed to capture " + str(prey_case["name"]))
	# A close spider must interrupt a fly's long feeding decision timer.
	game._reset_flies()
	var threatened_fly: Dictionary = game.flies[0]
	threatened_fly["pos"] = Vector2(500, 500)
	threatened_fly["render_pos"] = threatened_fly["pos"]
	threatened_fly["flight"] = false
	threatened_fly["flight_height"] = 0.0
	threatened_fly["action"] = "进食"
	threatened_fly["target"] = threatened_fly["pos"]
	threatened_fly["think_timer"] = 3.0
	threatened_fly["action_timer"] = 3.0
	threatened_fly["flight_cooldown"] = 5.0
	game.flies[0] = threatened_fly
	game.predators = [{"pos": Vector2(600, 500), "support_height": 0.0, "threat_radius": 150.0, "cooldown": 0.0, "wander_phase": 0.0, "alive": true}]
	game._update_fly(0, 0.05)
	check(str(game.flies[0]["action"]) == "撤退", "nearby spider did not interrupt feeding to trigger escape")
	game._reset_flies()
	# Brain-control mode must consume the selected adult's readout and override
	# only that individual's ecological action selector.
	game.brain_control_enabled = true
	game.selected_index = 0
	game.flies[0]["brain_readout"] = {"forward": 0.0, "steer": 0.0, "escape": 1.0, "backward": 0.0, "punch": 0.0, "kick": 0.0}
	game._choose_brain_action(0, 0.0, 0.0, 0.0, 0.0)
	check(str(game.flies[0]["action"]) == "撤退", "brain-control escape readout did not drive retreat")
	game.flies[0]["brain_readout"] = {"forward": 1.0, "steer": 0.0, "escape": 0.0, "backward": 0.0, "punch": 0.0, "kick": 0.0}
	game.flies[0]["hunger"] = 0.6
	game._choose_brain_action(0, 0.8, 0.0, 0.0, 0.0)
	check(str(game.flies[0]["action"]) == "进食", "brain-control forward readout did not drive feeding")
	# Wall-clock neural budget must be independent of render FPS.
	var adapter := FakeAdapter.new()
	var original_adapter = game.neural_adapter
	var original_view = game.garden_view
	game.neural_adapter = adapter
	game.garden_view = null
	var calls_by_fps := {}
	for fps in [30, 60, 120]:
		game._reset_flies()
		game.speed_multiplier = 10.0
		game.neural_wall_accumulator = 0.0
		game.neural_steps_due = 0
		adapter.calls = 0
		for _frame in range(fps):
			game._process(1.0 / float(fps))
		calls_by_fps[str(fps)] = adapter.calls
	check(abs(int(calls_by_fps["30"]) - int(calls_by_fps["60"])) <= 1 and abs(int(calls_by_fps["60"]) - int(calls_by_fps["120"])) <= 1, "neural sampling still depends on render FPS")
	# Leaf support must preserve in-area motion.
	game.neural_adapter = original_adapter
	game.garden_view = original_view
	game._reset_flies()
	var leaf: Dictionary = game._surface_by_id("leaf_left")
	var leaf_center: Vector2 = leaf["center"]
	var fly: Dictionary = game.flies[0]
	fly["pos"] = leaf_center
	fly["target"] = leaf_center + Vector2(150, 100)
	fly["action"] = "探索"
	fly["flight"] = false
	fly["flight_height"] = 0.0
	fly["support_id"] = "leaf_left"
	fly["support_height"] = leaf["height"]
	fly["route"] = PackedVector2Array()
	game.flies[0] = fly
	for _step in range(100):
		game._move_ground(0, 0.05)
	check(leaf_center.distance_to(game.flies[0]["pos"]) > 2.0, "leaf support still pins fly to center")
	# A ground spider must not kill a fly in normal flight or on a branch.
	game._reset_flies()
	fly = game.flies[0]
	fly["flight"] = true
	fly["flight_height"] = 0.9
	fly["support_height"] = 0.0
	fly["alive"] = true
	game.flies[0] = fly
	game.predators = [{"pos": fly["pos"], "support_height": 0.0, "threat_radius": 150.0, "cooldown": 0.0, "alive": true}]
	game._update_predators(0.05)
	check(bool(game.flies[0]["alive"]), "ground spider captured airborne fly")
	# Food contact uses the surface under the fly, not another less-crowded target.
	var candy_a: Dictionary = game._make_sugar_food(Vector2(480, 480))
	var candy_b: Dictionary = game._make_sugar_food(Vector2(520, 480))
	candy_a["surfaces"][0]["occupants"] = ["a", "b", "c"]
	game.foods = [candy_a, candy_b]
	fly = game.flies[0]
	fly["flight"] = false
	fly["flight_height"] = 0.0
	fly["support_height"] = 0.05
	fly["pos"] = candy_a["surfaces"][0]["pos"]
	game.flies[0] = fly
	check(game._consume_food_at(0, 1.0, 0.18) > 0.0, "crowded food contact incorrectly returned zero")
	# Larval source IDs outside the three semantic labels must still produce a visible overlay.
	game.brain_view.set_catalog(game.larva_brain_catalog, "larva")
	var fixture_id := ""
	for neuron_id in game.brain_view.morphology_segments:
		if not game.brain_view.active_neuron_materials.has(neuron_id) and not game.brain_view.morphology_segments[neuron_id].is_empty():
			fixture_id = str(neuron_id)
			break
	check(not fixture_id.is_empty(), "Larval branch asset contains no unlabelled neuron fixture")
	game.brain_view.set_activity({}, {"dataset_id": "Winding2023-L1EM", "request_seq": 701, "spike_ids": [fixture_id]})
	check(is_instance_valid(game.brain_view.active_spike_instance), "Larval branch activity did not create a source-ID overlay")
	check(is_instance_valid(game.brain_view.propagation_instance) and game.brain_view.propagation_instance.visible, "Larval activity did not create a morphology pulse")
	game.brain_view.set_activity({}, {})
	check(not game.brain_view.propagation_instance.visible, "Morphology pulse survived activity clear")
	check(not game.brain_view.show_connectome_edges or not game.brain_view.connectome_edges_instance.visible, "connectome edge layer remains visually over-dense by default")
	check(game.brain_view.full_brain_instance == null or not game.brain_view.full_brain_instance.visible, "adult point cloud remains visually over-dense by default")
	# A disconnected adapter must remove the last real frame and must not leave
	# a cached spike overlay that could be mistaken for a local/virtual signal.
	game.neural_adapter.bridge_state = "malecns"
	game.brain_view.set_activity({}, {"dataset_id": "MaleCNS-v1.0", "request_seq": 9001, "spike_ids": []})
	game.neural_adapter.bridge_state = "local"
	game._clear_brain_activity()
	check(game.brain_view.last_activity.is_empty(), "brain view retained activity after bridge disconnect")
	check(game.brain_view.pulse_left.is_empty(), "brain view retained pulse animation after bridge disconnect")
	check(game.flies[game.selected_index].get("brain_activity", {}).is_empty(), "selected fly retained cached activity after bridge disconnect")
	print("BEHAVIOR_REGRESSION ", JSON.stringify({"failures": failures, "neural_calls": calls_by_fps}))
	var file := FileAccess.open("res://build/behavior_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"failures": failures, "neural_calls": calls_by_fps}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
