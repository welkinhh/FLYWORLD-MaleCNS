extends Node2D

## FLYWORLD Godot desktop prototype.
##
## The Godot world owns behavior, lifecycle, family history, and persistence.
## The neural adapter supplies activity for the selected adult or larva.
## Fresh adult model readouts can also drive the selected adult's actions.

# ROOM_RECT is the logical garden coordinate space. GardenView3D maps it into
# a responsive viewport; it is intentionally not a fixed screen rectangle.
const ROOM_RECT := Rect2(32, 78, 820, 620)
const TOP_BAR_HEIGHT := 78.0
const FOOTER_HEIGHT := 0.0
const SIDEBAR_STATE_HEIGHT := 96.0
const SIDEBAR_EVENT_HEIGHT := 116.0
const SIDEBAR_CONTROLS_HEIGHT := 48.0
const SIM_HZ := 20.0
const FOOD_POS := Vector2(366, 408) # Exposed flesh of the painted left banana.
const FOOD_POS_B := Vector2(692, 508) # Exposed flesh of the painted right banana.
const ROOM_MARGIN := 15.0
const LEGACY_HISTORY_PATH := "user://flyworld_history.json"
const WORLD_SAVE_PATH := "user://flyworld_world.json"
const WORLD_SAVE_SCHEMA := 4
const GARDEN_VERSION := 4
const NEURAL_ADAPTER_SCRIPT = preload("res://scripts/neural_adapter.gd")
const BRAIN_VIEW_SCRIPT = preload("res://scripts/brain_view_3d.gd")
const ACTIVE_CAPACITY := 30
const STAGE_DURATIONS := {"egg": 30.0, "larva": 45.0, "pupa": 15.0}
const ADULT_LIFESPAN_MIN := 600.0
const ADULT_LIFESPAN_MAX := 1200.0
const ADULT_MATURITY := 10.0
const REPRODUCTION_COOLDOWN := 30.0
const MATING_DISTANCE := 72.0
const NEURAL_WALL_STEP := 0.05
const BANANA_MAX_NUTRITION := 1200.0
const PREDATOR_ESCAPE_PRESSURE := 0.22
const PREDATOR_CAPTURE_RADIUS := 30.0
const PREDATOR_VERTICAL_REACH := 0.62

var rng := RandomNumberGenerator.new()
var neural_adapter: Object
var sim_accumulator := 0.0
var sim_time := 0.0
var neural_wall_accumulator := 0.0
var neural_steps_due := 0
var last_viewport_size := Vector2.ZERO
var speed_multiplier := 1.0
var initial_population := 8
var paused := false
var selected_index := 0
var tool_mode := ""
var brain_process_pid: int = -1
var started_brain_process := false
var reproduction_timer := 0.0
var world_uuid := "FLYWORLD-LOCAL"
var next_id_number := 1
var next_food_id := 1
var foods: Array = []
var predators: Array = []
var furniture: Array = []
var terrain_surfaces: Array = []
var flies: Array = []
var event_log: Array = []
var event_seq := 0
var environment := {
	"temperature": 25.0,
	"humidity": 60.0,
	"light": 65.0,
}

var ui_root: Control
var top_container: HBoxContainer
var actions_container: HBoxContainer
var runtime_garden_rect := Rect2()
var runtime_panel_rect := Rect2()

var top_state_label: Label
var event_header_label: Label
var event_feed_label: Label
var selected_label: Label
var section_header_label: Label
var brain_view
var adult_brain_catalog: Dictionary = {}
var larva_brain_catalog: Dictionary = {}
var brain_view_stage := ""
var temp_slider: HSlider
var humidity_slider: HSlider
var light_slider: HSlider
var brain_control_button: Button
var pause_button: Button
var garden_view
var navigation_grid: AStarGrid2D
var temperature_value: Label
var humidity_value: Label
var light_value: Label
var last_observed_id := ""
var last_observed_stage := ""
var ui_refresh_elapsed := 0.0
var test_mode := false
var neural_test_mode := false
var brain_control_enabled := false
var world_initializing := true
var bridge_startup_deadline := 0
var bridge_retry_at := 0
var last_bridge_state := "local"


func _ready() -> void:
	test_mode = "--flyworld-test" in OS.get_cmdline_user_args()
	neural_test_mode = "--flyworld-neural-test" in OS.get_cmdline_user_args()
	neural_adapter = NEURAL_ADAPTER_SCRIPT.new()
	rng.seed = 17010914
	initial_population = _population_from_command_line()
	_setup_world()
	world_initializing = false
	_setup_ui()
	neural_adapter.begin_world(world_uuid)
	if not flies.is_empty():
		neural_adapter.set_selection(str(flies[selected_index]["id"]), str(flies[selected_index].get("life_stage", "adult")))
	temp_slider.set_value_no_signal(float(environment["temperature"]))
	humidity_slider.set_value_no_signal(float(environment["humidity"]))
	light_slider.set_value_no_signal(float(environment["light"]))
	pause_button.text = "继续" if paused else "暂停"
	_maybe_start_brain_service()
	queue_redraw()


func _stop_brain_service() -> void:
	if not started_brain_process or brain_process_pid <= 0:
		return
	if OS.get_name() == "Windows":
		# PyInstaller one-file services have a short-lived bootloader parent;
		# taskkill /T closes both it and the extracted child process. Launch it
		# asynchronously so a busy first-run download or Numba warmup cannot hold
		# the game window open after the user closes it.
		OS.create_process("taskkill", PackedStringArray(["/PID", str(brain_process_pid), "/T", "/F"]), false)
	else:
		OS.kill(brain_process_pid)
	brain_process_pid = -1
	started_brain_process = false


func _process(delta: float) -> void:
	neural_adapter.poll_bridge()
	# Activity frames are valid only while the real MaleCNS bridge is active.
	# Clear the cached frame on every disconnect/connecting transition so a
	# previously received spike window cannot flash again after reconnecting.
	if neural_adapter.bridge_state != last_bridge_state:
		if neural_adapter.bridge_state != "malecns":
			_clear_brain_activity()
		last_bridge_state = neural_adapter.bridge_state
	if neural_adapter.bridge_state == "malecns" and selected_index >= 0 and selected_index < flies.size():
		# The single connection control is the source of truth. A connected
		# adult may use the verified readout; larva and disconnected states stay
		# on the ecological controller.
		brain_control_enabled = str(flies[selected_index].get("life_stage", "")) == "adult"
	var now_ms := Time.get_ticks_msec()
	if neural_adapter.bridge_state == "malecns":
		bridge_startup_deadline = 0
	elif neural_adapter.reconnect_requested and now_ms >= bridge_retry_at:
		neural_adapter.connect_bridge()
		bridge_retry_at = now_ms + 2000
	elif now_ms < bridge_startup_deadline and now_ms >= bridge_retry_at and neural_adapter.bridge_state == "local":
		neural_adapter.connect_bridge()
		bridge_retry_at = now_ms + 1500
	if brain_view != null:
		brain_view.activity_paused = paused
	_layout_responsive_ui()
	if get_viewport_rect().size != last_viewport_size:
		queue_redraw()
	if not paused:
		# Neural observation advances on wall-clock time, independent of the
		# ecological multiplier. The world may run at x10 while the selected
		# brain still receives one fixed observation window per wall step.
		neural_wall_accumulator += delta
		while neural_wall_accumulator >= NEURAL_WALL_STEP:
			neural_wall_accumulator -= NEURAL_WALL_STEP
			neural_steps_due = mini(neural_steps_due + 1, 4)
		sim_accumulator += delta * speed_multiplier
		var step := 1.0 / SIM_HZ
		while sim_accumulator >= step:
			_simulate_step(step)
			sim_accumulator -= step
		for fly in flies:
			fly["render_pos"] = Vector2(fly.get("render_pos", fly["pos"])).lerp(fly["pos"], 1.0 - exp(-delta * 18.0))
	if garden_view != null:
		var selected_id := str(flies[selected_index]["id"]) if selected_index >= 0 and selected_index < flies.size() else ""
		garden_view.sync_state(flies, predators, foods, selected_id, delta, paused, float(environment["light"]), world_uuid, terrain_surfaces)
	ui_refresh_elapsed += delta
	if ui_refresh_elapsed >= 0.10:
		ui_refresh_elapsed = 0.0
		_refresh_ui()


func _calculate_panel_rect() -> Rect2:
	var viewport_size := get_viewport_rect().size
	var panel_width := clampf(viewport_size.x * 0.27, 340.0, 420.0)
	return Rect2(viewport_size.x - panel_width, TOP_BAR_HEIGHT, panel_width, maxf(260.0, viewport_size.y - TOP_BAR_HEIGHT - FOOTER_HEIGHT))


func _calculate_garden_rect() -> Rect2:
	var viewport_size := get_viewport_rect().size
	var panel := _calculate_panel_rect()
	return Rect2(0.0, TOP_BAR_HEIGHT, panel.position.x, maxf(260.0, viewport_size.y - TOP_BAR_HEIGHT - FOOTER_HEIGHT))


func _layout_responsive_ui() -> void:
	if ui_root == null:
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x < 1.0 or viewport_size.y < 1.0:
		return
	runtime_panel_rect = _calculate_panel_rect()
	runtime_garden_rect = _calculate_garden_rect()
	if garden_view != null:
		garden_view.position = runtime_garden_rect.position
		garden_view.size = runtime_garden_rect.size
	if top_container != null:
		top_container.position = Vector2(32.0, 16.0)
		top_container.size = Vector2(maxf(400.0, viewport_size.x - 64.0), 50.0)
	var x := runtime_panel_rect.position.x + 20.0
	var width := runtime_panel_rect.size.x - 40.0
	var panel_top := runtime_panel_rect.position.y
	var panel_height := runtime_panel_rect.size.y
	var state_height := minf(SIDEBAR_STATE_HEIGHT, maxf(74.0, panel_height * 0.18))
	var event_height := minf(SIDEBAR_EVENT_HEIGHT, maxf(92.0, panel_height * 0.22))
	var controls_height := SIDEBAR_CONTROLS_HEIGHT
	var brain_height := maxf(180.0, panel_height - state_height - event_height - controls_height)
	if section_header_label != null:
		section_header_label.position = Vector2(x, panel_top + 10.0)
		section_header_label.size = Vector2(width, 22.0)
	if selected_label != null:
		selected_label.position = Vector2(x, panel_top + 36.0)
		selected_label.size = Vector2(width, state_height - 40.0)
	if event_header_label != null:
		event_header_label.position = Vector2(x, panel_top + state_height + 8.0)
		event_header_label.size = Vector2(width, 20.0)
	if event_feed_label != null:
		event_feed_label.position = Vector2(x, panel_top + state_height + 30.0)
		event_feed_label.size = Vector2(width, maxf(48.0, event_height - 34.0))
	if brain_view != null:
		# The morphology is the entire middle panel: no inset gap or second
		# explanatory layer is placed over it.
		brain_view.position = Vector2(runtime_panel_rect.position.x, panel_top + state_height + event_height)
		brain_view.size = Vector2(runtime_panel_rect.size.x, brain_height)
	if brain_control_button != null:
		brain_control_button.visible = true
	if actions_container != null:
		actions_container.position = Vector2(runtime_panel_rect.position.x + 12.0, runtime_panel_rect.end.y - 40.0)
		actions_container.size = Vector2(runtime_panel_rect.size.x - 24.0, 34.0)
	last_viewport_size = viewport_size


func _population_from_command_line() -> int:
	var requested := 8
	for argument in OS.get_cmdline_args():
		var text_argument := str(argument)
		if text_argument.begins_with("--flyworld-population="):
			var parsed := text_argument.get_slice("=", 1).to_int()
			if parsed in [4, 8, 30]:
				requested = parsed
	return requested


func _maybe_start_brain_service() -> void:
	if test_mode and not neural_test_mode:
		return
	# Exported builds can start the project-side brain service themselves.
	# The editor remains usable without it and falls back to the local adapter.
	if Engine.is_editor_hint() and not neural_test_mode:
		return
	# Release builds ship a frozen Python service next to the game. The service
	# writes its large MaleCNS files under user:// so a read-only install folder
	# and a GitHub-downloaded zip both work without administrator privileges.
	var executable_dir := OS.get_executable_path().get_base_dir()
	var bundled_service := executable_dir.path_join("brain_service.exe")
	if FileAccess.file_exists(bundled_service):
		var bundled_data := ProjectSettings.globalize_path("user://malecns_data")
		DirAccess.make_dir_recursive_absolute(bundled_data)
		var bundled_arguments := PackedStringArray(["--model", "malecns", "--data", bundled_data, "--dt", "0.001", "--port", "8765", "--parent-pid", str(OS.get_process_id())])
		brain_process_pid = OS.create_process(bundled_service, bundled_arguments, false)
		started_brain_process = brain_process_pid > 0
		if started_brain_process:
			bridge_startup_deadline = Time.get_ticks_msec() + 90000
			bridge_retry_at = Time.get_ticks_msec() + 1500
			neural_adapter.connect_bridge()
		return
	var project_root := ProjectSettings.globalize_path("res://")
	var python_path := project_root.path_join(".venv/Scripts/python.exe")
	var brain_script := project_root.path_join("brain_service/brain_service.py")
	var brain_data := project_root.path_join("data/malecns")
	if not FileAccess.file_exists(python_path):
		var executable_root := OS.get_executable_path().get_base_dir().get_base_dir()
		python_path = executable_root.path_join(".venv/Scripts/python.exe")
		brain_script = executable_root.path_join("brain_service/brain_service.py")
		brain_data = executable_root.path_join("data/malecns")
	if not FileAccess.file_exists(python_path) or not FileAccess.file_exists(brain_script):
		return
	var arguments := PackedStringArray([brain_script, "--model", "malecns", "--data", brain_data, "--dt", "0.001", "--port", "8765", "--parent-pid", str(OS.get_process_id())])
	brain_process_pid = OS.create_process(python_path, arguments, false)
	started_brain_process = brain_process_pid > 0
	if started_brain_process:
		bridge_startup_deadline = Time.get_ticks_msec() + 90000
		bridge_retry_at = Time.get_ticks_msec() + 1500
		neural_adapter.connect_bridge()


func _setup_world() -> void:
	# The painted backyard is the static environment; don't keep collision blockers
	# for the deleted procedural trees, rocks and fence.
	furniture.clear()
	_setup_terrain_surfaces()
	_reset_flies()
	if not test_mode:
		_load_history()
		_load_world_snapshot()


func _setup_terrain_surfaces() -> void:
	# Logical landing areas follow visible roots, leaves, and the fallen twig in
	# the supplied background art. They affect behavior only; the illustration
	# itself is the complete environment, with no extra scene meshes.
	terrain_surfaces = [
		{"id": "root_left", "kind": "root", "a": Vector2(594, 370), "b": Vector2(665, 420), "radius": 34.0, "height": 0.10},
		{"id": "root_right", "kind": "root", "a": Vector2(665, 420), "b": Vector2(772, 458), "radius": 32.0, "height": 0.12},
		{"id": "fallen_twig", "kind": "twig", "a": Vector2(104, 614), "b": Vector2(324, 600), "radius": 22.0, "height": 0.06},
		{"id": "fern_left", "kind": "leaf", "center": Vector2(170, 568), "radius": 42.0, "height": 0.08},
		{"id": "fern_mid", "kind": "leaf", "center": Vector2(396, 590), "radius": 44.0, "height": 0.08},
		{"id": "fern_right", "kind": "leaf", "center": Vector2(706, 592), "radius": 46.0, "height": 0.08},
		{"id": "groundcover_far_right", "kind": "leaf", "center": Vector2(816, 610), "radius": 34.0, "height": 0.06},
	]


func _surface_projection(point: Vector2, surface: Dictionary) -> Dictionary:
	var projected := Vector2(surface.get("center", point))
	if surface.has("a") and surface.has("b"):
		var a: Vector2 = surface["a"]
		var b: Vector2 = surface["b"]
		var segment := b - a
		var t := clampf((point - a).dot(segment) / maxf(segment.length_squared(), 0.001), 0.0, 1.0)
		projected = a + segment * t
	elif surface.has("center"):
		var center: Vector2 = surface["center"]
		var radius := float(surface.get("radius", 24.0))
		var offset := point - center
		if offset.length() <= radius:
			projected = point
		elif offset.length() > 0.001:
			projected = center + offset.normalized() * radius
	return {"surface": surface, "projected": projected, "distance": point.distance_to(projected)}


func _nearest_terrain_surface(point: Vector2, max_distance: float = INF) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := max_distance
	for surface in terrain_surfaces:
		var projection := _surface_projection(point, surface)
		var limit := float(surface.get("radius", 24.0))
		if float(projection["distance"]) <= limit and float(projection["distance"]) < best_distance:
			best = projection
			best_distance = float(projection["distance"])
	return best


func _surface_by_id(surface_id: String) -> Dictionary:
	if surface_id.is_empty() or surface_id == "ground":
		return {}
	for surface in terrain_surfaces:
		if str(surface.get("id", "")) == surface_id:
			return surface
	return {}


func _apply_support(entity: Dictionary, point: Vector2, preferred_id: String = "") -> Vector2:
	var candidate := _surface_by_id(preferred_id)
	var projection := _surface_projection(point, candidate) if not candidate.is_empty() else {}
	if candidate.is_empty() or float(projection.get("distance", INF)) > float(candidate.get("radius", 24.0)):
		projection = _nearest_terrain_surface(point)
	if projection.is_empty():
		entity["support_id"] = "ground"
		entity["support_kind"] = "ground"
		entity["support_height"] = 0.0
		return _resolve_ground_collision(point)
	var surface: Dictionary = projection["surface"]
	entity["support_id"] = str(surface.get("id", "ground"))
	entity["support_kind"] = str(surface.get("kind", "leaf"))
	entity["support_height"] = float(surface.get("height", 0.0))
	return projection["projected"]


func _exit_tree() -> void:
	if not test_mode:
		_save_world()
	if neural_adapter != null:
		neural_adapter.disconnect_bridge()
	_stop_brain_service()


func _reset_flies() -> void:
	sim_time = 0.0
	sim_accumulator = 0.0
	neural_wall_accumulator = 0.0
	neural_steps_due = 0
	navigation_grid = null
	next_id_number = 1
	next_food_id = 1
	world_uuid = "FLYWORLD-%s-%s" % [str(Time.get_unix_time_from_system()), str(rng.randi())]
	event_log.clear()
	event_seq = 0
	flies.clear()
	# The garden opens with four adults per color: two males and two females.
	# The legacy 4-population command-line mode remains available for compact tests.
	var adults_per_family := 4 if initial_population >= 8 else 2
	for family_index in range(2):
		var family := "赤枝" if family_index == 0 else "青苔"
		var color := Color(0.36, 0.76, 0.93) if family_index == 0 else Color(0.98, 0.58, 0.28)
		for sex_index in range(adults_per_family):
			var sex := "雄" if sex_index % 2 == 0 else "雌"
			var fly_id := _next_fly_id()
			var fly := _make_fly(fly_id, _population_position(family_index, sex_index, false), color, 0.34 + float(sex_index) * 0.08, 0.14 + float(sex_index) * 0.05, 0.54 + float(family_index) * 0.06, family, sex, "adult", 0, [])
			fly["age_seconds"] = 0.0
			fly["stage_age"] = ADULT_MATURITY
			fly["life_span_seconds"] = rng.randf_range(ADULT_LIFESPAN_MIN, ADULT_LIFESPAN_MAX)
			fly["reproduction_cooldown"] = 0.0
			flies.append(fly)
	var adult_initial_count := adults_per_family * 2
	var extra_count: int = max(0, min(ACTIVE_CAPACITY, initial_population) - adult_initial_count)
	for extra_index in range(extra_count):
		var family_index := extra_index % 2
		var family := "赤枝" if family_index == 0 else "青苔"
		var color := Color(0.36, 0.76, 0.93) if family_index == 0 else Color(0.98, 0.58, 0.28)
		var fly_id := _next_fly_id()
		var start_pos := _population_position(family_index, extra_index + 2, true)
		var fly := _make_fly(fly_id, start_pos, color, 0.25, 0.08, 0.32, family, "未知", "larva", 0, [])
		fly["stage_age"] = float((extra_index * 19) % 120)
		fly["age_seconds"] = fly["stage_age"]
		flies.append(fly)
	_initialize_foods()
	predators.clear()
	reproduction_timer = 0.0
	paused = false
	_event("系统", "新一轮后院观察，编号果蝇状态已重置。")
	_save_world()


func _initialize_foods() -> void:
	foods = [
		_make_banana_food("banana_a", FOOD_POS, 0.16, 0),
		_make_banana_food("banana_b", FOOD_POS_B, -0.18, 1),
	]


func _make_banana_food(food_id: String, center: Vector2, rotation: float, variant: int) -> Dictionary:
	var surfaces: Array = []
	for i in range(7):
		# Spread feeding anchors across the visible flesh band in the background
		# art so flies can feed along the banana instead of one tiny point.
		var offset := Vector2((float(i) - 3.0) * 20.0, sin(float(i) * 0.9) * 3.0)
		offset = offset.rotated(rotation)
		surfaces.append({
				"id": "%s-surface-%d" % [food_id, i],
				"pos": center + offset,
				"radius": 24.0,
				"height": 0.02,
				"occupants": [],
		})
	return {
		"id": food_id,
		"kind": "banana",
		"center": center,
		"rotation": rotation,
		"variant": variant,
		"amount": BANANA_MAX_NUTRITION,
		"max_amount": BANANA_MAX_NUTRITION,
		"surface_nutrition": BANANA_MAX_NUTRITION / 7.0,
		"surfaces": surfaces,
		"peel_edible": false,
	}


func _make_sugar_food(center: Vector2) -> Dictionary:
	var food_number := next_food_id
	next_food_id += 1
	return {
		"id": "candy-%d" % food_number,
		"kind": "candy",
		"center": center,
		"rotation": 0.0,
		"variant": 0,
		"amount": 90.0,
		"max_amount": 90.0,
		"surface_nutrition": 90.0,
		"surfaces": [{"id": "candy-surface-%d" % food_number, "pos": center, "radius": 24.0, "height": 0.05, "occupants": []}],
		"peel_edible": true,
	}


func _make_predator(position: Vector2, record: Dictionary = {}) -> Dictionary:
	return {
		"kind": str(record.get("kind", "spider")),
		"pos": _clamp_room_point(position),
		"velocity": Vector2.ZERO,
		"facing": 1.0,
		"support_id": str(record.get("support_id", "ground")),
		"support_height": float(record.get("support_height", 0.0)),
		"threat_radius": clampf(float(record.get("threat_radius", 150.0)), 80.0, 220.0),
		"cooldown": maxf(0.0, float(record.get("cooldown", 0.0))),
		"wander_phase": float(record.get("wander_phase", 0.0)),
		"alive": bool(record.get("alive", true)),
	}


func _next_fly_id() -> String:
	var fly_id := "FLY-%06d" % next_id_number
	next_id_number += 1
	return fly_id


func _display_name(fly_id: Variant) -> String:
	var text_id := str(fly_id)
	if text_id.begins_with("FLY-"):
		var number := text_id.trim_prefix("FLY-").to_int()
		return "%02d" % number
	return text_id


func _population_position(family_index: int, slot: int, larva: bool) -> Vector2:
	var column := slot % 2
	var row := int(slot / 2)
	var origin := Vector2(270.0, 370.0) if family_index == 0 else Vector2(620.0, 470.0)
	if larva:
		origin += Vector2(42.0, 44.0)
	return _resolve_ground_collision(origin + Vector2(column * 72.0, row * 52.0))


func _make_fly(fly_id: String, start_pos: Vector2, body_color: Color, hunger: float, fatigue: float, courage: float, family: String = "赤枝", sex: String = "雄", life_stage: String = "adult", generation: int = 0, parent_ids: Array = []) -> Dictionary:
	return {
		"id": fly_id,
		"family": family,
		"family_color": body_color,
		"sex": sex,
		"life_stage": life_stage,
		"alive": true,
		"age_seconds": 0.0,
		"stage_age": ADULT_MATURITY if life_stage == "adult" else 0.0,
		"stage_duration": ADULT_LIFESPAN_MIN if life_stage == "adult" else float(STAGE_DURATIONS.get(life_stage, STAGE_DURATIONS["egg"])),
		"life_span_seconds": rng.randf_range(ADULT_LIFESPAN_MIN, ADULT_LIFESPAN_MAX) if life_stage == "adult" else 0.0,
		"growth": 0.0 if life_stage != "adult" else 1.0,
		"generation": generation,
		"parent_ids": parent_ids.duplicate(),
		"death_reason": "",
		"reproduction_cooldown": 0.0,
		"mate_id": "",
		"courtship_timer": 0.0,
		"mating_timer": 0.0,
		"sex_roll": rng.randf(),
		"pos": start_pos,
		"render_pos": start_pos,
		"support_id": "ground",
		"support_kind": "ground",
		"support_height": 0.0,
		"velocity": Vector2.ZERO,
		"target": start_pos,
		"flight_start": start_pos,
		"flight_target": start_pos,
		"flight_surface_id": "",
		"action": "探索",
		"action_timer": 0.2,
		"think_timer": 0.0,
		"flight": false,
		"flight_timer": 0.0,
		"flight_cooldown": 1.5,
		"hunger": hunger,
		"fatigue": fatigue,
		"stress": 0.12,
		"water": 0.78,
		"courage": courage,
		"curiosity": 0.5 + rng.randf_range(-0.12, 0.12),
		"body_color": body_color,
		"facing": 1.0,
		"wing_phase": rng.randf_range(0.0, TAU),
		"clash_cooldown": 0.0,
		"brain": neural_adapter.create_state(),
		"brain_activity": {},
		"brain_readout": {},
		"brain_readout_time_ms": 0,
		"brain_turn_sign": 1.0,
		"recent_events": [],
		"memory": {"wins": 0, "losses": 0, "rivals": {}},
	}


func _setup_ui() -> void:
	garden_view = preload("res://scripts/garden_view_3d.gd").new()
	runtime_garden_rect = _calculate_garden_rect()
	runtime_panel_rect = _calculate_panel_rect()
	garden_view.position = runtime_garden_rect.position
	garden_view.size = runtime_garden_rect.size
	add_child(garden_view)
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var ui := Control.new()
	ui_root = ui
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(ui)
	var top := HBoxContainer.new()
	top_container = top
	top.position = Vector2(32, 16)
	top.size = Vector2(1216, 50)
	top.add_theme_constant_override("separation", 12)
	ui.add_child(top)
	_add_label(top, "FLYWORLD", Vector2.ZERO, Vector2.ZERO, 20, Color("f0e9c9")).custom_minimum_size.x = 134
	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 6)
	top.add_child(transport)
	pause_button = _make_button(transport, "暂停", Rect2(0, 0, 66, 36), _on_pause_pressed)
	_make_button(transport, "重新开始", Rect2(0, 0, 94, 36), _on_new_round_pressed)
	for speed in [1.0, 2.0, 5.0, 10.0]:
		_make_button(transport, "%sx" % str(speed), Rect2(0, 0, 42, 36), _on_speed_pressed.bind(speed))
	top_state_label = _add_label(top, "", Vector2.ZERO, Vector2.ZERO, 11, Color("b6c9ae"))
	top_state_label.custom_minimum_size.x = 150
	top_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for name in ["温度", "湿度", "光照"]:
		var column := VBoxContainer.new()
		column.custom_minimum_size.x = 150
		column.add_theme_constant_override("separation", 1)
		top.add_child(column)
		var label := _add_label(column, name, Vector2.ZERO, Vector2.ZERO, 12, Color("e3e6cc"))
		label.custom_minimum_size.y = 20
		if name == "温度":
			temperature_value = label
			temp_slider = _make_slider(column, Rect2(0, 0, 150, 22), 18, 32, 25, _on_temperature_changed)
		elif name == "湿度":
			humidity_value = label
			humidity_slider = _make_slider(column, Rect2(0, 0, 150, 22), 30, 80, 60, _on_humidity_changed)
		else:
			light_value = label
			light_slider = _make_slider(column, Rect2(0, 0, 150, 22), 0, 100, 65, _on_light_changed)
	# Sidebar is split into independent state, event, morphology and action
	# regions. Keeping these as separate controls prevents event text from
	# painting over the selected-fly state.
	section_header_label = _add_label(ui, "个体观察", Vector2(892, 91), Vector2(336, 22), 13, Color("dae3c5"))
	selected_label = _add_label(ui, "", Vector2(892, 118), Vector2(336, 42), 12, Color("c7d5b9"))
	event_header_label = _add_label(ui, "事件流", Vector2(892, 180), Vector2(336, 20), 11, Color("9fbda0"))
	event_feed_label = _add_label(ui, "", Vector2(892, 204), Vector2(336, 90), 11, Color("a6bba2"))
	event_feed_label.clip_text = true
	brain_view = BRAIN_VIEW_SCRIPT.new()
	brain_view.position = Vector2(runtime_panel_rect.position.x, runtime_panel_rect.position.y + 212.0)
	brain_view.size = Vector2(runtime_panel_rect.size.x, runtime_panel_rect.size.y * 0.5)
	ui.add_child(brain_view)
	_load_brain_catalogs.call_deferred()
	var actions := HBoxContainer.new()
	actions_container = actions
	actions.position = Vector2(892, 615)
	actions.size = Vector2(352, 34)
	actions.add_theme_constant_override("separation", 6)
	ui.add_child(actions)
	var sugar_button := _make_button(actions, "放糖", Rect2(0, 0, 78, 34), _on_sugar_pressed)
	var predator_button := _make_button(actions, "放天敌", Rect2(0, 0, 106, 34), _on_predator_pressed)
	var delete_predator_button := _make_button(actions, "删除天敌", Rect2(0, 0, 108, 34), _on_delete_predator_pressed)
	brain_control_button = _make_button(actions, "连接大脑", Rect2(0, 0, 78, 34), _on_bridge_pressed)
	for action_button in [sugar_button, predator_button, delete_predator_button, brain_control_button]:
		action_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action_button.custom_minimum_size = Vector2(0, 34)
	_layout_responsive_ui()


func _add_label(parent: Control, text_value: String, pos: Vector2, size: Vector2, font_size: int, color: Color, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = pos
	label.size = size
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _make_button(parent: Control, text_value: String, rect: Rect2, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text_value
	button.position = rect.position
	button.size = rect.size
	button.custom_minimum_size = rect.size
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", Color(0.86, 0.94, 0.96))
	button.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	button.add_theme_stylebox_override("normal", _style_box(Color(0.08, 0.13, 0.19), Color(0.19, 0.31, 0.4)))
	button.add_theme_stylebox_override("hover", _style_box(Color(0.12, 0.23, 0.3), Color(0.37, 0.75, 0.83)))
	button.add_theme_stylebox_override("pressed", _style_box(Color(0.16, 0.28, 0.33), Color(0.65, 0.88, 0.86)))
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _make_slider(parent: Control, rect: Rect2, min_value: float, max_value: float, value: float, callback: Callable) -> HSlider:
	var slider := HSlider.new()
	slider.position = rect.position
	slider.size = rect.size
	slider.custom_minimum_size = rect.size
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = 0.5
	slider.value = value
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(callback)
	parent.add_child(slider)
	return slider


func _style_box(background: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = background
	box.border_color = border
	box.border_width_left = 1
	box.border_width_top = 1
	box.border_width_right = 1
	box.border_width_bottom = 1
	box.corner_radius_top_left = 7
	box.corner_radius_top_right = 7
	box.corner_radius_bottom_left = 7
	box.corner_radius_bottom_right = 7
	box.content_margin_left = 8
	box.content_margin_right = 8
	return box


func _simulate_step(dt: float) -> void:
	sim_time += dt
	neural_adapter.begin_tick()
	for index in range(flies.size()):
		_update_fly(index, dt)
	_update_predators(dt)
	_update_lifecycle(dt)
	reproduction_timer += dt
	if reproduction_timer >= 1.0:
		reproduction_timer = 0.0
		_update_reproduction()
	# Food is a finite shared reserve. There is no hidden automatic refill;
	# both banana entities expose their remaining nutrition to the renderer.
	_update_food_state()


func _update_fly(index: int, dt: float) -> void:
	var fly: Dictionary = flies[index]
	if not bool(fly.get("alive", true)):
		return
	if str(fly.get("life_stage", "adult")) != "adult":
		_update_non_adult(index, dt)
		return
	var opponent: Dictionary = _nearest_opponent(index)
	var pos: Vector2 = fly["pos"]
	var sugar_signal := _sugar_signal(pos)
	var predator_pressure := _predator_signal(pos)
	var opponent_distance: float = pos.distance_to(opponent["pos"]) if not opponent.is_empty() else INF
	var proximity: float = clamp(1.0 - opponent_distance / 170.0, 0.0, 1.0)
	var rival_fear: float = max(_rival_fear(fly, str(opponent.get("id", ""))), predator_pressure * 0.85)
	var local_light := _light_at(pos)
	var thermal_comfort: float = 1.0 - clamp(abs(float(environment["temperature"]) - 25.0) / 10.0, 0.0, 1.0)
	var humidity_comfort: float = 1.0 - clamp(abs(float(environment["humidity"]) - 60.0) / 35.0, 0.0, 1.0)

	var brain_inputs := {
		"fly_id": fly["id"],
		"life_stage": "adult",
		"sim_time_s": sim_time,
		"sugar": sugar_signal,
		"food_odor": sugar_signal,
		"food_contact_taste": _food_contact_signal(pos),
		"bitter": 0.0,
		"hunger": float(fly["hunger"]),
		"proximity": proximity,
		"stress": float(fly["stress"]),
		"rival_fear": rival_fear,
		"temperature": float(environment["temperature"]),
		"humidity": float(environment["humidity"]),
		"light": local_light,
	}
	var threat_channels := _threat_channels(pos)
	brain_inputs["threat_left"] = threat_channels["left"]
	brain_inputs["threat_right"] = threat_channels["right"]
	brain_inputs["threat_approach"] = threat_channels["approach"]
	var observation_brain: Dictionary = fly["brain"]
	var fresh_activity: Dictionary = {}
	if index == selected_index and str(fly.get("life_stage", "adult")) == "adult" and neural_steps_due > 0:
		neural_adapter.set_selection(str(fly["id"]), "adult")
		observation_brain = neural_adapter.step(fly["brain"], brain_inputs, NEURAL_WALL_STEP)
		fresh_activity = neural_adapter.take_activity(str(fly["id"]))
		neural_steps_due = maxi(0, neural_steps_due - 1)
	fly["brain"] = observation_brain
	if not fresh_activity.is_empty():
		fly["brain_activity"] = fresh_activity
		if fresh_activity.get("readout", {}) is Dictionary:
			fly["brain_readout"] = fresh_activity.get("readout", {}).duplicate(true)
			fly["brain_readout_time_ms"] = Time.get_ticks_msec()
		fly["activity_received_ms"] = Time.get_ticks_msec()
		_present_activity(fly, fresh_activity)
	fly["hunger"] = clamp(float(fly["hunger"]) + dt * 0.0014, 0.0, 1.0)
	fly["water"] = clamp(float(fly["water"]) - dt * 0.00045, 0.0, 1.0)
	fly["stress"] = move_toward(float(fly["stress"]), 0.12 + predator_pressure * 0.4, dt * 0.06)
	fly["wing_phase"] = fmod(float(fly["wing_phase"]) + dt * (18.0 if fly["flight"] else 7.0), TAU)
	fly["action_timer"] = float(fly["action_timer"]) - dt
	fly["think_timer"] = float(fly["think_timer"]) - dt
	fly["flight_cooldown"] = max(0.0, float(fly["flight_cooldown"]) - dt)
	fly["clash_cooldown"] = max(0.0, float(fly["clash_cooldown"]) - dt)

	if fly["flight"]:
		_update_flight(fly, dt)
	else:
		# Interrupt long feeding/rest timers as soon as a spider becomes a real
		# nearby threat; otherwise normal decision timers can delay escape.
		if predator_pressure > PREDATOR_ESCAPE_PRESSURE and str(fly.get("action", "")) != "撤退":
			fly["think_timer"] = 0.0
			fly["action_timer"] = 0.0
		if float(fly["think_timer"]) <= 0.0 or float(fly["action_timer"]) <= 0.0:
			if brain_control_enabled and index == selected_index and _brain_control_available(fly):
				_choose_brain_action(index, sugar_signal, proximity, rival_fear, predator_pressure)
			else:
				_choose_action(index, sugar_signal, proximity, rival_fear, predator_pressure, local_light, thermal_comfort, humidity_comfort)
		_move_ground(index, dt)
		_try_consume_food(index, dt)
		_try_clash(index, dt, opponent_distance)

	if fly["action"] == "休息":
		fly["fatigue"] = max(0.0, float(fly["fatigue"]) - dt * (0.045 + humidity_comfort * 0.02))
	else:
		var exertion := 0.002
		if fly["flight"]:
			exertion = 0.012
		elif fly["action"] in ["攻击", "追逐", "撤退"]:
			exertion = 0.009
		elif fly["action"] in ["进食", "探索"]:
			exertion = 0.004
		fly["fatigue"] = clamp(float(fly["fatigue"]) + dt * exertion, 0.0, 1.0)
	var speed_effect: float = clamp(0.68 + thermal_comfort * 0.22 + humidity_comfort * 0.1, 0.5, 1.0)
	fly["speed_effect"] = speed_effect
	flies[index] = fly


func _nearest_opponent(index: int) -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := INF
	var source: Dictionary = flies[index]
	for other_index in range(flies.size()):
		if other_index == index:
			continue
		var other: Dictionary = flies[other_index]
		if not bool(other.get("alive", true)) or str(other.get("life_stage", "adult")) != "adult":
			continue
		if str(other.get("family", "")) == str(source.get("family", "")):
			continue
		var distance: float = source["pos"].distance_to(other["pos"])
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = other
	return nearest


func _predator_signal(pos: Vector2) -> float:
	var strength := 0.0
	for predator in predators:
		if not bool(predator.get("alive", true)):
			continue
		var radius: float = float(predator.get("threat_radius", 150.0))
		var local: float = clamp(1.0 - pos.distance_to(predator["pos"]) / radius, 0.0, 1.0)
		strength = max(strength, local)
	return strength


func _food_contact_signal(pos: Vector2) -> float:
	var surface := _nearest_food_surface(pos)
	if surface.is_empty():
		return 0.0
	return clampf(1.0 - float(surface.get("distance", INF)) / maxf(float(surface.get("radius", 26.0)), 1.0), 0.0, 1.0)


func _threat_channels(pos: Vector2) -> Dictionary:
	var left := 0.0
	var right := 0.0
	var approach := 0.0
	for predator in predators:
		if not bool(predator.get("alive", true)):
			continue
		var delta := Vector2(predator["pos"]) - pos
		var pressure := clampf(1.0 - delta.length() / maxf(float(predator.get("threat_radius", 150.0)), 1.0), 0.0, 1.0)
		if delta.x < 0.0:
			left = maxf(left, pressure)
		else:
			right = maxf(right, pressure)
		approach = maxf(approach, pressure * (0.55 + 0.45 * float(predator.get("cooldown", 0.0)) / 5.0))
	return {"left": left, "right": right, "approach": clampf(approach, 0.0, 1.0)}


func _update_predators(dt: float) -> void:
	for predator_index in range(predators.size()):
		var predator: Dictionary = predators[predator_index]
		if not bool(predator.get("alive", true)):
			continue
		predator["cooldown"] = max(0.0, float(predator.get("cooldown", 0.0)) - dt)
		var target_index := _nearest_predator_target(predator["pos"], float(predator.get("threat_radius", 150.0)), float(predator.get("support_height", 0.0)))
		if target_index >= 0:
			var target_pos: Vector2 = flies[target_index]["pos"]
			var direction: Vector2 = target_pos - Vector2(predator["pos"])
			if direction.length() > PREDATOR_CAPTURE_RADIUS:
				var desired := direction.normalized() * 24.0
				var velocity: Vector2 = Vector2(predator.get("velocity", Vector2.ZERO)).move_toward(desired, 110.0 * dt)
				predator["velocity"] = velocity
				var next_pos := _clamp_room_point(Vector2(predator["pos"]) + velocity * dt)
				var support := _nearest_terrain_surface(next_pos, 18.0)
				if not support.is_empty():
					var surface: Dictionary = support["surface"]
					predator["support_id"] = str(surface.get("id", "ground"))
					predator["support_height"] = float(surface.get("height", 0.0))
					next_pos = support["projected"]
				else:
					predator["support_id"] = "ground"
					predator["support_height"] = 0.0
				predator["pos"] = next_pos
				predator["facing"] = sign(velocity.x) if abs(velocity.x) > 0.1 else float(predator.get("facing", 1.0))
			if direction.length() <= PREDATOR_CAPTURE_RADIUS and float(predator["cooldown"]) <= 0.0:
				var target_id: String = str(flies[target_index]["id"])
				_kill_fly(target_index, "被花园蜘蛛捕食")
				predator["cooldown"] = 5.0
				_event("天敌", "蜘蛛捕食了 %s，花园空出一个生态位。" % target_id)
		else:
			var wander_phase := float(predator.get("wander_phase", 0.0)) + dt
			predator["wander_phase"] = wander_phase
			var wander_velocity := Vector2(cos(wander_phase * 0.7), sin(wander_phase * 0.9)) * 6.0
			predator["velocity"] = Vector2(predator.get("velocity", Vector2.ZERO)).move_toward(wander_velocity, 42.0 * dt)
			predator["pos"] = _clamp_room_point(Vector2(predator["pos"]) + Vector2(predator["velocity"]) * dt)
		predators[predator_index] = predator


func _nearest_predator_target(origin: Vector2, radius: float, support_height: float = 0.0) -> int:
	var nearest_index := -1
	var nearest_distance := radius
	for index in range(flies.size()):
		var fly: Dictionary = flies[index]
		if not bool(fly.get("alive", true)) or str(fly.get("life_stage", "adult")) != "adult":
			continue
		if bool(fly.get("flight", false)) or float(fly.get("flight_height", 0.0)) > 0.15:
			continue
		if absf(float(fly.get("support_height", 0.0)) - support_height) > PREDATOR_VERTICAL_REACH:
			continue
		var distance := origin.distance_to(fly["pos"])
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = index
	return nearest_index


func _update_non_adult(index: int, dt: float) -> void:
	var fly: Dictionary = flies[index]
	var stage: String = str(fly.get("life_stage", "egg"))
	if stage == "egg":
		fly["action"] = "卵"
		fly["velocity"] = Vector2.ZERO
	elif stage == "pupa":
		fly["action"] = "蛹"
		fly["velocity"] = Vector2.ZERO
	elif stage == "larva":
		fly["action"] = "幼虫觅食"
		fly["hunger"] = clamp(float(fly["hunger"]) + dt * 0.0022, 0.0, 1.0)
		fly["water"] = clamp(float(fly["water"]) - dt * 0.00055, 0.0, 1.0)
		var target := _best_food_target(fly["pos"])
		fly["target"] = target
		fly["speed_effect"] = 0.55
		_move_ground(index, dt)
		var bite := _consume_food_at(index, dt, 0.12)
		# Growth follows the stage clock. Nutrition can delay it, but a normal
		# feeding larva is never trapped by a hidden score threshold.
		var growth_factor := 1.0 if bite > 0.0 else (0.32 if float(fly["hunger"]) < 0.82 and float(fly["water"]) > 0.25 else 0.08)
		fly["growth"] = clamp(float(fly["growth"]) + dt / 45.0 * growth_factor, 0.0, 1.0)
	else:
		fly["hunger"] = clamp(float(fly["hunger"]) + dt * 0.0003, 0.0, 1.0)
		fly["water"] = clamp(float(fly["water"]) - dt * 0.0001, 0.0, 1.0)
	var fresh_activity: Dictionary = {}
	if stage == "larva" and index == selected_index and neural_steps_due > 0:
		neural_adapter.set_selection(str(fly["id"]), "larva")
		var nearest_adult := _nearest_opponent(index)
		var larva_distance: float = fly["pos"].distance_to(nearest_adult["pos"]) if not nearest_adult.is_empty() else INF
		var larva_inputs := {
			"fly_id": fly["id"],
			"life_stage": "larva",
			"sim_time_s": sim_time,
			"sugar": _sugar_signal(fly["pos"]),
			"food_odor": _sugar_signal(fly["pos"]),
			"food_contact_taste": _food_contact_signal(fly["pos"]),
			"bitter": 0.0,
			"hunger": float(fly["hunger"]),
			"proximity": clamp(1.0 - larva_distance / 170.0, 0.0, 1.0),
			"stress": float(fly["stress"]),
			"rival_fear": 0.0,
			"temperature": float(environment["temperature"]),
			"humidity": float(environment["humidity"]),
			"light": _light_at(fly["pos"]),
		}
		var larva_threat_channels := _threat_channels(fly["pos"])
		larva_inputs["threat_left"] = larva_threat_channels["left"]
		larva_inputs["threat_right"] = larva_threat_channels["right"]
		larva_inputs["threat_approach"] = larva_threat_channels["approach"]
		fly["brain"] = neural_adapter.step(fly["brain"], larva_inputs, NEURAL_WALL_STEP)
		fresh_activity = neural_adapter.take_activity(str(fly["id"]))
		neural_steps_due = maxi(0, neural_steps_due - 1)
	if not fresh_activity.is_empty():
		fly["brain_activity"] = fresh_activity
		if fresh_activity.get("readout", {}) is Dictionary:
			fly["brain_readout"] = fresh_activity.get("readout", {}).duplicate(true)
			fly["brain_readout_time_ms"] = Time.get_ticks_msec()
		fly["activity_received_ms"] = Time.get_ticks_msec()
		_present_activity(fly, fresh_activity)
	elif stage != "larva":
		fly["brain_activity"] = {}
	flies[index] = fly
	var temperature_stress: bool = abs(float(environment["temperature"]) - 25.0) > 7.0
	var humidity_stress: bool = float(environment["humidity"]) < 34.0 or float(environment["humidity"]) > 78.0
	if float(fly["hunger"]) >= 0.995:
		_kill_fly(index, "饥饿")
	elif float(fly["water"]) <= 0.01:
		_kill_fly(index, "脱水")
	elif temperature_stress or humidity_stress:
		_kill_fly(index, "环境压力")


func _update_lifecycle(dt: float) -> void:
	for index in range(flies.size()):
		var fly: Dictionary = flies[index]
		if not bool(fly.get("alive", true)):
			continue
		fly["age_seconds"] = float(fly["age_seconds"]) + dt
		fly["stage_age"] = float(fly["stage_age"]) + dt
		fly["reproduction_cooldown"] = max(0.0, float(fly.get("reproduction_cooldown", 0.0)) - dt)
		var stage: String = str(fly["life_stage"])
		if stage == "egg" and float(fly["stage_age"]) >= float(fly["stage_duration"]):
			_transition_stage(index, "larva")
		elif stage == "larva" and float(fly["stage_age"]) >= float(fly["stage_duration"]):
			_transition_stage(index, "pupa")
		elif stage == "pupa" and float(fly["stage_age"]) >= float(fly["stage_duration"]):
			_transition_stage(index, "adult")
		elif stage == "adult":
			if float(fly["stage_age"]) >= float(fly.get("life_span_seconds", fly["stage_duration"])):
				_kill_fly(index, "寿命结束")
			elif float(fly["hunger"]) >= 0.995:
				_kill_fly(index, "饥饿")
			elif float(fly["water"]) <= 0.01:
				_kill_fly(index, "脱水")
		flies[index] = fly


func _transition_stage(index: int, next_stage: String) -> void:
	var fly: Dictionary = flies[index]
	var previous: String = str(fly["life_stage"])
	fly["life_stage"] = next_stage
	fly["stage_age"] = 0.0
	fly["stage_duration"] = ADULT_LIFESPAN_MIN if next_stage == "adult" else float(STAGE_DURATIONS.get(next_stage, STAGE_DURATIONS["egg"]))
	fly["action"] = "孵化" if next_stage == "larva" else ("羽化" if next_stage == "adult" else "化蛹")
	if next_stage == "adult":
		if str(fly.get("sex", "未知")) == "未知":
			# Sex is assigned exactly once at eclosion from the saved RNG stream.
			fly["sex"] = "雌" if float(fly.get("sex_roll", rng.randf())) >= 0.5 else "雄"
		fly["growth"] = 1.0
		fly["stage_age"] = 0.0
		fly["life_span_seconds"] = rng.randf_range(ADULT_LIFESPAN_MIN, ADULT_LIFESPAN_MAX)
		fly["stage_duration"] = fly["life_span_seconds"]
		fly["reproduction_cooldown"] = ADULT_MATURITY
		fly["brain"] = neural_adapter.create_state()
		fly["brain_activity"] = {}
	_record_fly_event(index, fly["action"], "%s → %s，永久编号保持不变。" % [previous, next_stage])
	flies[index] = fly
	if index == selected_index:
		neural_adapter.set_selection(str(fly["id"]), next_stage)


func _kill_fly(index: int, reason: String) -> void:
	var fly: Dictionary = flies[index]
	if not bool(fly.get("alive", true)):
		return
	fly["alive"] = false
	fly["life_stage"] = str(fly["life_stage"])
	fly["action"] = "死亡"
	fly["death_reason"] = reason
	fly["brain_activity"] = {}
	_record_fly_event(index, "死亡", reason)
	flies[index] = fly
	if index == selected_index:
		neural_adapter.clear_selection()
		brain_control_enabled = false


func _update_reproduction() -> void:
	if _active_count() >= ACTIVE_CAPACITY:
		return
	for first_index in range(flies.size()):
		var first: Dictionary = flies[first_index]
		if not _can_reproduce(first):
			continue
		var mate_index := _find_mate(first_index)
		if mate_index < 0:
			continue
		var second: Dictionary = flies[mate_index]
		var distance: float = first["pos"].distance_to(second["pos"])
		first["mate_id"] = str(second["id"])
		second["mate_id"] = str(first["id"])
		if distance > MATING_DISTANCE:
			first["action"] = "寻找配偶"
			second["action"] = "接近配偶"
			first["target"] = second["pos"]
			second["target"] = first["pos"]
			first["courtship_timer"] = min(float(first.get("courtship_timer", 0.0)) + 0.5, 3.0)
			second["courtship_timer"] = min(float(second.get("courtship_timer", 0.0)) + 0.5, 3.0)
			flies[first_index] = first
			flies[mate_index] = second
			continue
		first["action"] = "交配"
		second["action"] = "交配"
		first["mating_timer"] = float(first.get("mating_timer", 0.0)) + 0.5
		second["mating_timer"] = float(second.get("mating_timer", 0.0)) + 0.5
		if float(first["mating_timer"]) < 1.0 or float(second["mating_timer"]) < 1.0:
			flies[first_index] = first
			flies[mate_index] = second
			continue
		if _active_count() >= ACTIVE_CAPACITY:
			return
		var first_id := str(first["id"])
		var second_id := str(second["id"])
		var egg_id := _next_fly_id()
		var generation: int = max(int(first["generation"]), int(second["generation"])) + 1
		var egg_pos := _best_laying_position((first["pos"] + second["pos"]) * 0.5)
		var egg := _make_fly(egg_id, egg_pos, first["family_color"], 0.18, 0.05, 0.3, first["family"], "未知", "egg", generation, [str(first["id"]), str(second["id"])])
		_reclaim_dead_slot()
		# Reclaiming a dead array slot can shift both parents. Resolve them by
		# permanent ID before writing any post-birth state or events.
		var first_after_reclaim := _index_for_id(first_id)
		var second_after_reclaim := _index_for_id(second_id)
		if first_after_reclaim < 0 or second_after_reclaim < 0:
			return
		flies.append(egg)
		first = flies[first_after_reclaim]
		second = flies[second_after_reclaim]
		first["hunger"] = clamp(float(first["hunger"]) + 0.045, 0.0, 1.0)
		second["hunger"] = clamp(float(second["hunger"]) + 0.045, 0.0, 1.0)
		first["reproduction_cooldown"] = REPRODUCTION_COOLDOWN
		second["reproduction_cooldown"] = REPRODUCTION_COOLDOWN
		first["courtship_timer"] = 0.0
		second["courtship_timer"] = 0.0
		first["mating_timer"] = 0.0
		second["mating_timer"] = 0.0
		flies[first_after_reclaim] = first
		flies[second_after_reclaim] = second
		_record_fly_event(first_after_reclaim, "繁殖", "与 %s 完成交配并产下一枚卵。" % _display_name(second_id))
		_record_fly_event(second_after_reclaim, "繁殖", "与 %s 完成交配并产下一枚卵。" % _display_name(first_id))
		_event("生态箱", "%s 与 %s 产生后代 %s。" % [_display_name(first_id), _display_name(second_id), _display_name(egg_id)], [first_id, second_id, egg_id])
		return


func _can_reproduce(fly: Dictionary) -> bool:
	return bool(fly.get("alive", true)) and str(fly.get("life_stage", "")) == "adult" and str(fly.get("sex", "未知")) != "未知" and float(fly.get("stage_age", 0.0)) >= ADULT_MATURITY and float(fly.get("reproduction_cooldown", 0.0)) <= 0.0 and float(fly.get("hunger", 1.0)) < 0.86 and float(fly.get("water", 0.0)) > 0.18 and float(fly.get("fatigue", 1.0)) < 0.90


func _find_mate(index: int) -> int:
	var source: Dictionary = flies[index]
	var best := -1
	var best_distance := INF
	for other_index in range(flies.size()):
		if other_index == index:
			continue
		var other: Dictionary = flies[other_index]
		if not _can_reproduce(other) or str(other.get("family", "")) != str(source.get("family", "")) or str(other.get("sex", "未知")) == str(source.get("sex", "未知")):
			continue
		var distance: float = source["pos"].distance_to(other["pos"])
		if distance < best_distance:
			best_distance = distance
			best = other_index
	return best


func _best_laying_position(near: Vector2) -> Vector2:
	var target := _best_food_target(near)
	return _resolve_ground_collision(target + Vector2(rng.randf_range(-18.0, 18.0), rng.randf_range(-12.0, 12.0)))


func _active_count() -> int:
	var count := 0
	for fly in flies:
		if bool(fly.get("alive", true)):
			count += 1
	return count


func _reclaim_dead_slot() -> void:
	if flies.size() < ACTIVE_CAPACITY:
		return
	for index in range(flies.size()):
		if not bool(flies[index].get("alive", true)):
			flies.remove_at(index)
			if selected_index == index:
				selected_index = 0
			elif selected_index > index:
				selected_index -= 1
			return


func _brain_control_available(fly: Dictionary) -> bool:
	if neural_adapter.bridge_state != "malecns":
		return false
	var readout = fly.get("brain_readout", {})
	if not readout is Dictionary or readout.is_empty():
		return false
	return Time.get_ticks_msec() - int(fly.get("brain_readout_time_ms", 0)) <= 1500


func _choose_brain_action(index: int, sugar_signal: float, proximity: float, rival_fear: float, predator_pressure: float) -> void:
	var fly: Dictionary = flies[index]
	var readout: Dictionary = fly.get("brain_readout", {})
	var forward := clampf(float(readout.get("forward", 0.0)), 0.0, 1.0)
	var steer := clampf(float(readout.get("steer", 0.0)), 0.0, 1.0)
	var escape := clampf(float(readout.get("escape", 0.0)), 0.0, 1.0)
	var backward := clampf(float(readout.get("backward", 0.0)), 0.0, 1.0)
	var punch := clampf(float(readout.get("punch", 0.0)), 0.0, 1.0)
	var kick := clampf(float(readout.get("kick", 0.0)), 0.0, 1.0)
	var opponent := _nearest_opponent(index)
	var opponent_distance: float = fly["pos"].distance_to(opponent["pos"]) if not opponent.is_empty() else INF
	var action := "探索"
	var target := _random_walk_target(fly["pos"])
	var reason := "MaleCNS 读出选择继续探索。"
	if escape > 0.32 or predator_pressure > PREDATOR_ESCAPE_PRESSURE:
		action = "撤退"
		var danger: Vector2 = _nearest_predator_position(fly["pos"]) if predator_pressure > 0.1 else (Vector2(opponent["pos"]) if not opponent.is_empty() else Vector2(fly["pos"]))
		target = _away_target(fly["pos"], danger)
		reason = "脑控读出 escape 触发逃离。"
	elif backward > forward + 0.12:
		action = "撤退"
		target = _away_target(fly["pos"], opponent["pos"]) if not opponent.is_empty() else _random_walk_target(fly["pos"])
		reason = "脑控读出 backward 触发后退。"
	elif (punch > 0.32 or kick > 0.32) and not opponent.is_empty() and opponent_distance < 58.0:
		action = "攻击"
		target = opponent["pos"]
		reason = "脑控读出 punch/kick 触发对抗。"
	elif forward > 0.18:
		if sugar_signal > 0.12 and float(fly["hunger"]) > 0.15:
			action = "进食"
			target = _best_food_target(fly["pos"])
			reason = "脑控读出 forward 驱动接近食物。"
		else:
			action = "探索"
			target = _clamp_room_point(fly["pos"] + Vector2(fly["facing"], 0).rotated(float(fly.get("brain_turn_sign", 1.0)) * (0.35 + steer) * 1.2) * 120.0)
			reason = "脑控读出 forward/steer 驱动探索。"
	elif float(fly["fatigue"]) > 0.8:
		action = "休息"
		target = fly["pos"]
		reason = "脑控读出较弱且疲劳较高，进入休息。"
	else:
		action = "探索"
		reason = "脑控读出保持低强度探索。"
	if steer > 0.25:
		fly["brain_turn_sign"] = -float(fly.get("brain_turn_sign", 1.0))
	fly["action"] = action
	fly["target"] = target
	fly["action_timer"] = {"攻击": 0.55, "撤退": 0.9, "进食": 1.2, "探索": 1.0, "休息": 1.4}.get(action, 1.0)
	fly["think_timer"] = 0.18
	_record_fly_event(index, "脑控·" + action, reason)


func _choose_action(index: int, sugar_signal: float, proximity: float, rival_fear: float, predator_pressure: float, local_light: float, thermal_comfort: float, humidity_comfort: float) -> void:
	var fly: Dictionary = flies[index]
	var opponent: Dictionary = _nearest_opponent(index)
	var pos: Vector2 = fly["pos"]
	var opponent_distance: float = pos.distance_to(opponent["pos"]) if not opponent.is_empty() else INF
	var courage := float(fly["courage"])
	var hunger := float(fly["hunger"])
	var fatigue := float(fly["fatigue"])
	var action := "探索"
	var reason := "正在扫描花园里的气味、光线和叶片遮蔽。"
	var target := _random_walk_target(pos)
	var attack_ready := not opponent.is_empty() and opponent_distance < 43.0 and hunger > 0.28 and fatigue < 0.84 and courage + rng.randf_range(-0.1, 0.1) > 0.47 and rival_fear < 0.7

	if predator_pressure > PREDATOR_ESCAPE_PRESSURE:
		action = "撤退"
		var nearest_predator := _nearest_predator_position(pos)
		target = _away_target(pos, nearest_predator)
		reason = "天敌进入气味范围，触发快速逃离并寻找草叶遮蔽。"
	elif attack_ready and float(fly["clash_cooldown"]) <= 0.0:
		action = "攻击"
		target = opponent["pos"]
		reason = "距离很近、饥饿度较高，且当前的威胁评估允许一次短促冲撞。"
	elif not opponent.is_empty() and opponent_distance < 135.0 and hunger > 0.38 and fatigue < 0.78 and courage > 0.42 and rival_fear < 0.82:
		action = "追逐"
		target = opponent["pos"]
		reason = "对手进入注意范围，接近食物的动力暂时超过退缩倾向。"
	elif sugar_signal > 0.16 and hunger > 0.16:
		action = "进食"
		target = _best_food_target(pos)
		reason = "糖感觉输入与饥饿叠加，游戏行为规则选择接近食物。"
	elif (not opponent.is_empty() and opponent_distance < 170.0 and rival_fear > 0.57) or float(fly["stress"]) > 0.72:
		action = "撤退"
		target = _away_target(pos, opponent["pos"]) if not opponent.is_empty() else _random_walk_target(pos)
		reason = "对手记忆或当前压力较高，谨慎倾向暂时占优。"
	elif fatigue > 0.78:
		action = "休息"
		target = pos
		reason = "疲劳积累，停止追逐并在叶片阴影附近恢复。"
	elif local_light > 86.0 and float(environment["light"]) > 70.0:
		action = "探索"
		target = _away_target(pos, Vector2(735, 122))
		reason = "局部光照偏强，改变路线寻找较舒适的区域。"
	else:
		action = "探索"
		reason = "没有单一刺激占优，继续在草叶和香蕉周围搜索。"

	if float(fly["flight_cooldown"]) <= 0.0 and action in ["探索", "进食", "追逐"] and rng.randf() < 0.045 + float(fly["curiosity"]) * 0.025:
		_start_flight(index, target)
		return

	fly["action"] = action
	fly["target"] = target
	# Hold decisions long enough for the eye to read the intention and avoid
	# rapid target thrashing that looked like twitching.
	fly["action_timer"] = {"攻击": 0.7, "追逐": 1.8, "进食": 2.6, "撤退": 1.5, "休息": 2.2, "探索": 2.4}.get(action, 1.8)
	fly["think_timer"] = 0.65 + rng.randf_range(0.0, 0.35)
	_record_fly_event(index, action, reason)


func _nearest_predator_position(pos: Vector2) -> Vector2:
	var nearest := pos
	var distance := INF
	for predator in predators:
		if not bool(predator.get("alive", true)):
			continue
		var current := pos.distance_to(predator["pos"])
		if current < distance:
			distance = current
			nearest = predator["pos"]
	return nearest


func _start_flight(index: int, target_hint: Vector2) -> void:
	var fly: Dictionary = flies[index]
	var start: Vector2 = fly["pos"]
	var target := target_hint
	if not ROOM_RECT.grow(-ROOM_MARGIN).has_point(target) or _is_inside_blocking_furniture(target):
		target = _find_flight_target(start)
	if start.distance_to(target) < 70.0:
		target = _find_flight_target(start)
	var landing := _nearest_terrain_surface(target)
	if landing.is_empty() and rng.randf() < 0.38 and not terrain_surfaces.is_empty():
		var surface: Dictionary = terrain_surfaces[rng.randi_range(0, terrain_surfaces.size() - 1)]
		landing = _surface_projection(Vector2(surface.get("center", target)), surface)
	if not landing.is_empty():
		target = landing["projected"]
	fly["flight"] = true
	fly["flight_timer"] = 0.0
	fly["flight_start"] = start
	fly["flight_target"] = _resolve_ground_collision(target)
	# Takeoff releases the previous branch/leaf constraint; support is
	# reacquired only at the landing endpoint.
	fly["support_id"] = "ground"
	fly["support_kind"] = "ground"
	fly["support_height"] = 0.0
	fly["flight_surface_id"] = str(landing.get("surface", {}).get("id", "")) if not landing.is_empty() else ""
	fly["flight_duration"] = clampf(start.distance_to(target) / 120.0, 0.7, 4.0)
	fly["flight_cooldown"] = 3.0
	fly["action"] = "飞行"
	fly["action_timer"] = 1.0
	_record_fly_event(index, "飞行", "短距离飞行掠过草叶，寻找新的落点。")


func _update_flight(fly: Dictionary, dt: float) -> void:
	fly["flight_timer"] = float(fly["flight_timer"]) + dt
	var duration := float(fly.get("flight_duration", 1.5))
	var progress := clampf(float(fly["flight_timer"]) / duration, 0.0, 1.0)
	var start: Vector2 = fly["flight_start"]
	var target: Vector2 = fly["flight_target"]
	var previous: Vector2 = fly["pos"]
	var eased := progress * progress * (3.0 - 2.0 * progress)
	fly["pos"] = start.lerp(target, eased)
	fly["flight_height"] = sin(progress * PI) * 0.9
	fly["velocity"] = (Vector2(fly["pos"]) - previous) / dt
	if progress >= 1.0:
		fly["flight"] = false
		fly["flight_height"] = 0.0
		fly["pos"] = _apply_support(fly, _resolve_ground_collision(target), str(fly.get("flight_surface_id", "")))
		fly["flight_surface_id"] = ""
		fly["velocity"] = Vector2.ZERO
		fly["route"] = PackedVector2Array()
		fly["action"] = "降落"
		fly["action_timer"] = 0.5
		fly["think_timer"] = 0.5


func _move_ground(index: int, dt: float) -> void:
	var fly: Dictionary = flies[index]
	if bool(fly["flight"]):
		return
	if str(fly["action"]) in ["休息", "降落"]:
		fly["velocity"] = Vector2.ZERO
		return
	var pos: Vector2 = fly["pos"]
	var safe_pos := _resolve_ground_collision(pos)
	if safe_pos.distance_to(pos) > 0.1:
		pos = safe_pos
		fly["pos"] = pos
	if str(fly.get("support_id", "ground")) != "ground":
		var support_surface := _surface_by_id(str(fly.get("support_id", "")))
		var target_support_distance := INF
		if not support_surface.is_empty():
			target_support_distance = float(_surface_projection(Vector2(fly["target"]), support_surface).get("distance", INF))
		if support_surface.is_empty() or target_support_distance > float(support_surface.get("radius", 24.0)) * 1.15:
			fly["support_id"] = "ground"
			fly["support_kind"] = "ground"
			fly["support_height"] = 0.0
		else:
			var supported := _apply_support(fly, pos, str(fly.get("support_id", "")))
			if supported.distance_to(pos) <= 1.0:
				pos = supported
				fly["pos"] = pos
			else:
				fly["support_id"] = "ground"
				fly["support_kind"] = "ground"
				fly["support_height"] = 0.0
	var target: Vector2 = _resolve_ground_collision(fly["target"])
	var route: PackedVector2Array = fly.get("route", PackedVector2Array())
	if Vector2(fly.get("route_target", Vector2(INF, INF))).distance_to(target) > 12.0 or route.is_empty():
		route = _route_to(pos, target)
		fly["route_target"] = target
	while not route.is_empty() and pos.distance_to(route[0]) < 5.0:
		route.remove_at(0)
	if route.is_empty():
		fly["velocity"] = Vector2.ZERO
		if str(fly["action"]) != "进食":
			fly["think_timer"] = 0.0
		fly["route"] = route
		return
	var offset := route[0] - pos
	var base_speed := 45.0
	if str(fly["action"]) in ["追逐", "撤退", "攻击"]:
		base_speed = 72.0
	var speed := base_speed * float(fly.get("speed_effect", 0.85))
	var desired := offset.normalized() * minf(speed, offset.length() / dt)
	var velocity: Vector2 = Vector2(fly["velocity"]).move_toward(desired, 280.0 * dt)
	var next_pos := _resolve_ground_collision(pos + velocity * dt)
	next_pos = _apply_support(fly, next_pos, str(fly.get("support_id", "")))
	var moved := next_pos.distance_to(pos)
	fly["stuck_time"] = float(fly.get("stuck_time", 0.0)) + dt if moved < 0.12 else 0.0
	if float(fly["stuck_time"]) > 0.8:
		fly["target"] = _random_walk_target(pos)
		route.clear()
		fly["stuck_time"] = 0.0
		fly["think_timer"] = 1.2
	fly["route"] = route
	fly["velocity"] = (next_pos - pos) / dt
	fly["pos"] = next_pos
	if abs(velocity.x) > 14.0:
		fly["facing"] = sign(velocity.x)


func _route_to(start: Vector2, target: Vector2) -> PackedVector2Array:
	if navigation_grid == null:
		navigation_grid = AStarGrid2D.new()
		navigation_grid.region = Rect2i(0, 0, 40, 30)
		navigation_grid.cell_size = Vector2(20, 20)
		navigation_grid.offset = ROOM_RECT.position + Vector2(20, 20)
		navigation_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		navigation_grid.update()
		for x in range(40):
			for y in range(30):
				var cell := Vector2i(x, y)
				navigation_grid.set_point_solid(cell, _is_inside_blocking_furniture(navigation_grid.get_point_position(cell)))
	var a := _nearest_open_cell(start)
	var b := _nearest_open_cell(target)
	var route := navigation_grid.get_point_path(a, b)
	if not route.is_empty() and not _is_inside_blocking_furniture(target):
		route.append(target)
	return route


func _nearest_open_cell(point: Vector2) -> Vector2i:
	var rounded := Vector2i(((point - navigation_grid.offset) / 20.0).round())
	rounded = Vector2i(clampi(rounded.x, 0, 39), clampi(rounded.y, 0, 29))
	if not navigation_grid.is_point_solid(rounded):
		return rounded
	var nearest := Vector2i(20, 15)
	var distance := INF
	for x in range(40):
		for y in range(30):
			var cell := Vector2i(x, y)
			if not navigation_grid.is_point_solid(cell):
				var candidate := point.distance_squared_to(navigation_grid.get_point_position(cell))
				if candidate < distance:
					distance = candidate
					nearest = cell
	return nearest


func _try_consume_food(index: int, dt: float) -> void:
	var fly: Dictionary = flies[index]
	if fly["flight"] or fly["action"] != "进食":
		return
	var bite := _consume_food_at(index, dt, 0.18)
	if bite > 0.0:
		fly = flies[index]
		if rng.randf() < 0.08:
			_record_fly_event(index, "进食", "在裸露果肉表面摄取营养并补水。")


func _consume_food_at(index: int, dt: float, rate: float) -> float:
	if index < 0 or index >= flies.size():
		return 0.0
	var fly: Dictionary = flies[index]
	if bool(fly.get("flight", false)):
		return 0.0
	var target := _food_surface_at(Vector2(fly["pos"]))
	if target.is_empty() or float(target.get("distance", INF)) > float(target.get("radius", 26.0)):
		return 0.0
	var fly_height := float(fly.get("support_height", 0.0)) + float(fly.get("flight_height", 0.0))
	var food_height := float(target.get("height", 0.05))
	if absf(fly_height - food_height) > 0.24:
		return 0.0
	var food_index := int(target.get("food_index", -1))
	if food_index < 0 or food_index >= foods.size():
		return 0.0
	var food: Dictionary = foods[food_index]
	var available := float(food.get("amount", 0.0))
	if available <= 0.01:
		return 0.0
	var bite: float = minf(available, dt * rate)
	food["amount"] = available - bite
	foods[food_index] = food
	var hunger_recovery_per_food := 0.07 if str(fly.get("life_stage", "adult")) == "larva" else 0.04
	fly["hunger"] = max(0.0, float(fly.get("hunger", 0.0)) - bite * hunger_recovery_per_food)
	fly["water"] = min(1.0, float(fly.get("water", 0.0)) + bite * 0.03)
	fly["stress"] = max(0.0, float(fly.get("stress", 0.0)) - bite / 900.0)
	flies[index] = fly
	return bite


func _nearest_food_surface(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for food_index in range(foods.size()):
		var food: Dictionary = foods[food_index]
		if float(food.get("amount", 0.0)) <= 0.01:
			continue
		var remaining_ratio: float = clampf(float(food["amount"]) / maxf(float(food.get("max_amount", 1.0)), 1.0), 0.05, 1.0)
		for surface in food.get("surfaces", []):
			var surface_pos: Vector2 = surface["pos"]
			var distance: float = pos.distance_to(surface_pos)
			var occupants: Array = surface.get("occupants", [])
			var crowd_penalty := float(occupants.size()) * 18.0
			var score: float = distance + crowd_penalty - remaining_ratio * 24.0
			if score < best_score:
				best_score = score
				best = {"food_index": food_index, "surface_id": surface["id"], "pos": surface_pos, "radius": float(surface.get("radius", 26.0)), "height": float(surface.get("height", 0.05)), "distance": distance}
	return best


func _food_surface_at(pos: Vector2) -> Dictionary:
	# Contact is a geometric fact. Do not let a crowding score for another
	# surface make a fly standing on food fail to eat.
	var best: Dictionary = {}
	var best_distance := INF
	for food_index in range(foods.size()):
		var food: Dictionary = foods[food_index]
		if float(food.get("amount", 0.0)) <= 0.01:
			continue
		for surface in food.get("surfaces", []):
			var surface_pos: Vector2 = surface.get("pos", food.get("center", pos))
			var distance := pos.distance_to(surface_pos)
			if distance <= float(surface.get("radius", 26.0)) and distance < best_distance:
				best_distance = distance
				best = {"food_index": food_index, "surface_id": str(surface.get("id", "")), "pos": surface_pos, "radius": float(surface.get("radius", 26.0)), "height": float(surface.get("height", 0.05)), "distance": distance}
	return best


func _update_food_state() -> void:
	# Rebuild surface occupancy from world positions so crowding affects
	# routing even when a fly changes targets between fixed simulation ticks.
	for food in foods:
		for surface in food.get("surfaces", []):
			surface["occupants"] = []
	for fly in flies:
		if not bool(fly.get("alive", true)):
			continue
		var fly_pos: Vector2 = fly.get("pos", Vector2.ZERO)
		var nearest_food_surface := _food_surface_at(fly_pos)
		if nearest_food_surface.is_empty() or float(nearest_food_surface.get("distance", INF)) > float(nearest_food_surface.get("radius", 26.0)):
			continue
		var food_index := int(nearest_food_surface.get("food_index", -1))
		if food_index < 0 or food_index >= foods.size():
			continue
		for surface in foods[food_index].get("surfaces", []):
			if str(surface.get("id", "")) == str(nearest_food_surface.get("surface_id", "")):
				surface["occupants"].append(str(fly.get("id", "")))
				break


func _try_clash(index: int, dt: float, opponent_distance: float) -> void:
	if opponent_distance > 30.0:
		return
	var fly: Dictionary = flies[index]
	var opponent: Dictionary = _nearest_opponent(index)
	if opponent.is_empty():
		return
	var opponent_index := _index_for_id(str(opponent["id"]))
	if opponent_index < 0:
		return
	if fly["flight"] or opponent["flight"] or float(fly["clash_cooldown"]) > 0.0:
		return
	var action: String = fly["action"]
	var opposing_action: String = opponent["action"]
	if action == "攻击" or opposing_action == "攻击" or action == "威胁" or opposing_action == "威胁":
		var attacker_index := index if action == "攻击" else opponent_index
		var defender_index := opponent_index if attacker_index == index else index
		var attacker: Dictionary = flies[attacker_index]
		var defender: Dictionary = flies[defender_index]
		var force := 0.46 + float(attacker["courage"]) * 0.35 + rng.randf_range(-0.1, 0.1)
		var resistance := 0.38 + float(defender["courage"]) * 0.25 + float(defender["stress"]) * 0.12
		var direction: Vector2 = (defender["pos"] - attacker["pos"]).normalized()
		if direction.length() < 0.1:
			direction = Vector2.RIGHT
		attacker["pos"] = _resolve_ground_collision(attacker["pos"] - direction * 6.0)
		defender["pos"] = _resolve_ground_collision(defender["pos"] + direction * 8.0)
		attacker["fatigue"] = clamp(float(attacker["fatigue"]) + 0.035, 0.0, 1.0)
		defender["stress"] = clamp(float(defender["stress"]) + 0.12, 0.0, 1.0)
		attacker["clash_cooldown"] = 0.85
		defender["clash_cooldown"] = 0.85
		var winner := attacker_index if force >= resistance else defender_index
		var loser := defender_index if winner == attacker_index else attacker_index
		var winner_id: String = flies[winner]["id"]
		var loser_id: String = flies[loser]["id"]
		var loser_memory: Dictionary = flies[loser]["memory"]
		var rival_map: Dictionary = loser_memory["rivals"]
		var rival_record: Dictionary = rival_map.get(winner_id, {"losses": 0, "wins": 0})
		rival_record["losses"] = int(rival_record["losses"]) + 1
		rival_map[winner_id] = rival_record
		loser_memory["rivals"] = rival_map
		loser_memory["losses"] = int(loser_memory["losses"]) + 1
		flies[loser]["memory"] = loser_memory
		var winner_memory: Dictionary = flies[winner]["memory"]
		winner_memory["wins"] = int(winner_memory["wins"]) + 1
		flies[winner]["memory"] = winner_memory
		flies[winner]["stress"] = max(0.0, float(flies[winner]["stress"]) - 0.05)
		flies[loser]["stress"] = clamp(float(flies[loser]["stress"]) + 0.14, 0.0, 1.0)
		_record_fly_event(winner, "胜出", "短促冲撞后占据更有利的位置。")
		_record_fly_event(loser, "受挫", "冲撞后退开，对手记忆增加。")


func _index_for_id(fly_id: String) -> int:
	for index in range(flies.size()):
		if str(flies[index].get("id", "")) == fly_id:
			return index
	return -1


func _sugar_signal(pos: Vector2) -> float:
	var strength := 0.0
	for food in foods:
		if float(food.get("amount", 0.0)) <= 0.01:
			continue
		var remaining: float = clampf(float(food["amount"]) / maxf(float(food.get("max_amount", 1.0)), 1.0), 0.0, 1.0)
		strength = max(strength, clamp(1.0 - pos.distance_to(food["center"]) / 260.0, 0.0, 1.0) * (0.55 + remaining * 0.35))
	return strength


func _best_food_target(pos: Vector2) -> Vector2:
	var surface := _nearest_food_surface(pos)
	return surface["pos"] if not surface.is_empty() else ROOM_RECT.get_center()


func _rival_fear(fly: Dictionary, opponent_id: String) -> float:
	var rivals: Dictionary = fly["memory"]["rivals"]
	if not rivals.has(opponent_id):
		return 0.0
	var record: Dictionary = rivals[opponent_id]
	return clamp(float(record.get("losses", 0)) * 0.16 - float(record.get("wins", 0)) * 0.06, 0.0, 0.75)


func _random_walk_target(pos: Vector2) -> Vector2:
	for _attempt in range(12):
		var target := Vector2(
			rng.randf_range(ROOM_RECT.position.x + 26.0, ROOM_RECT.position.x + ROOM_RECT.size.x - 26.0),
			rng.randf_range(ROOM_RECT.position.y + 34.0, ROOM_RECT.position.y + ROOM_RECT.size.y - 26.0)
		)
		if not _is_inside_blocking_furniture(target):
			return target
	return pos


func _away_target(pos: Vector2, danger: Vector2) -> Vector2:
	var away := (pos - danger).normalized()
	if away.length() < 0.1:
		away = Vector2.RIGHT
	var best := _resolve_ground_collision(ROOM_RECT.get_center())
	var best_score := -INF
	for i in range(16):
		var heading := away.rotated(float(i) * TAU / 16.0)
		var candidate := _clamp_room_point(pos + heading * 140.0)
		if candidate.distance_to(pos) < 45.0 or _is_inside_blocking_furniture(candidate):
			continue
		var inset := ROOM_RECT.grow(-45.0)
		var score := candidate.distance_to(danger) + (35.0 if inset.has_point(candidate) else 0.0)
		if score > best_score:
			best_score = score
			best = candidate
	return best


func _find_flight_target(start: Vector2) -> Vector2:
	for _attempt in range(15):
		var target := Vector2(
			rng.randf_range(ROOM_RECT.position.x + 28.0, ROOM_RECT.position.x + ROOM_RECT.size.x - 28.0),
			rng.randf_range(ROOM_RECT.position.y + 38.0, ROOM_RECT.position.y + ROOM_RECT.size.y - 30.0)
		)
		if not _is_inside_blocking_furniture(target):
			return target
	return _clamp_room_point(start + Vector2(120, -80))


func _clamp_room_point(point: Vector2) -> Vector2:
	return Vector2(
		clamp(point.x, ROOM_RECT.position.x + ROOM_MARGIN, ROOM_RECT.position.x + ROOM_RECT.size.x - ROOM_MARGIN),
		clamp(point.y, ROOM_RECT.position.y + ROOM_MARGIN, ROOM_RECT.position.y + ROOM_RECT.size.y - ROOM_MARGIN)
	)


func _is_inside_blocking_furniture(point: Vector2) -> bool:
	# Exposed banana flesh is an allowed support/feeding surface even though
	# its surrounding fruit shell occupies the same logical neighborhood.
	for food in foods:
		for surface in food.get("surfaces", []):
			if point.distance_to(surface.get("pos", point)) <= float(surface.get("radius", 26.0)):
				return false
	for item in furniture:
		if bool(item["blocks_flight"]) and item["rect"].grow(16.0).has_point(point):
			return true
	return false


func _resolve_ground_collision(point: Vector2) -> Vector2:
	var resolved := _clamp_room_point(point)
	for attempt in range(4):
		if not _is_inside_blocking_furniture(resolved):
			return resolved
		var best := resolved
		var best_distance := INF
		var rectangles: Array = []
		for item in furniture:
			if bool(item["blocks_flight"]):
				rectangles.append(item["rect"])
		for food in foods:
			if str(food.get("kind", "banana")) == "banana" and float(food.get("amount", 0.0)) > 0.01:
				var center: Vector2 = food.get("center", ROOM_RECT.get_center())
				rectangles.append(Rect2(center - Vector2(48.0, 30.0), Vector2(96.0, 60.0)))
		for raw_rect in rectangles:
			var rect: Rect2 = raw_rect.grow(17)
			if not rect.has_point(resolved):
				continue
			for candidate in [Vector2(rect.position.x - 1, resolved.y), Vector2(rect.end.x + 1, resolved.y), Vector2(resolved.x, rect.position.y - 1), Vector2(resolved.x, rect.end.y + 1)]:
				var safe := _clamp_room_point(candidate)
				if not _is_inside_blocking_furniture(safe) and resolved.distance_to(safe) < best_distance:
					best_distance = resolved.distance_to(safe)
					best = safe
		if best == resolved:
			return ROOM_RECT.get_center()
		resolved = best
	return resolved


func _light_at(_pos: Vector2) -> float:
	return float(environment["light"])


func _record_fly_event(index: int, action: String, reason: String) -> void:
	var fly: Dictionary = flies[index]
	var events: Array = fly["recent_events"]
	var routine := action in ["探索", "进食", "追逐", "撤退", "休息", "飞行", "攻击", "降落"]
	for previous in events:
		if routine and str(previous.get("action", "")) == action:
			return
	events.append({"t": sim_time, "action": action, "reason": reason})
	if events.size() > 100:
		events.pop_front()
	fly["recent_events"] = events
	_event(str(fly["id"]), action + " · " + reason)


func _event(actor: String, text_value: String, participants: Array = []) -> void:
	event_seq += 1
	event_log.append({"t": sim_time, "actor": actor, "participants": participants.duplicate(), "text": text_value})
	if event_log.size() > 50:
		event_log.pop_front()


func _save_world() -> void:
	if test_mode or world_initializing:
		return
	var saved_flies: Array = []
	for fly in flies:
		saved_flies.append({
			"id": fly.get("id", ""),
			"family": fly.get("family", ""),
			"sex": fly.get("sex", "未知"),
			"life_stage": fly.get("life_stage", "adult"),
			"alive": fly.get("alive", true),
			"age_seconds": fly.get("age_seconds", 0.0),
			"stage_age": fly.get("stage_age", 0.0),
			"stage_duration": fly.get("stage_duration", ADULT_LIFESPAN_MIN),
			"life_span_seconds": fly.get("life_span_seconds", ADULT_LIFESPAN_MIN),
			"growth": fly.get("growth", 0.0),
			"generation": fly.get("generation", 0),
			"parent_ids": fly.get("parent_ids", []),
			"death_reason": fly.get("death_reason", ""),
			"reproduction_cooldown": fly.get("reproduction_cooldown", 0.0),
			"mate_id": fly.get("mate_id", ""),
			"courtship_timer": fly.get("courtship_timer", 0.0),
			"mating_timer": fly.get("mating_timer", 0.0),
			"sex_roll": fly.get("sex_roll", 0.5),
			"hunger": fly.get("hunger", 0.0),
			"fatigue": fly.get("fatigue", 0.0),
			"stress": fly.get("stress", 0.0),
			"water": fly.get("water", 0.0),
			"courage": fly.get("courage", 0.5),
			"curiosity": fly.get("curiosity", 0.5),
			"action": fly.get("action", "探索"),
			"target_pos": [float(fly["target"].x), float(fly["target"].y)],
			"flight_start": [float(fly.get("flight_start", fly["pos"]).x), float(fly.get("flight_start", fly["pos"]).y)],
			"flight_target": [float(fly.get("flight_target", fly["target"]).x), float(fly.get("flight_target", fly["target"]).y)],
			"flight_duration": float(fly.get("flight_duration", 1.5)),
			"flight_height": float(fly.get("flight_height", 0.0)),
			"flight_surface_id": str(fly.get("flight_surface_id", "")),
			"velocity": [float(fly["velocity"].x), float(fly["velocity"].y)],
			"flight": fly.get("flight", false),
			"flight_timer": fly.get("flight_timer", 0.0),
			"flight_cooldown": fly.get("flight_cooldown", 0.0),
			"clash_cooldown": fly.get("clash_cooldown", 0.0),
			"action_timer": fly.get("action_timer", 0.0),
			"think_timer": fly.get("think_timer", 0.0),
			"memory": fly.get("memory", {}).duplicate(true),
			"recent_events": fly.get("recent_events", []).duplicate(true),
			"pos": [float(fly["pos"].x), float(fly["pos"].y)],
			"support_id": str(fly.get("support_id", "ground")),
			"support_kind": str(fly.get("support_kind", "ground")),
			"support_height": float(fly.get("support_height", 0.0)),
		})
	var saved_predators: Array = []
	for predator in predators:
		saved_predators.append({
			"kind": str(predator.get("kind", "spider")),
			"pos": [float(predator["pos"].x), float(predator["pos"].y)],
			"support_id": str(predator.get("support_id", "ground")),
			"support_height": float(predator.get("support_height", 0.0)),
			"threat_radius": float(predator.get("threat_radius", 150.0)),
			"cooldown": float(predator.get("cooldown", 0.0)),
			"wander_phase": float(predator.get("wander_phase", 0.0)),
			"alive": bool(predator.get("alive", true)),
		})
	var saved_foods: Array = []
	for food in foods:
		var saved_surfaces: Array = []
		for surface in food.get("surfaces", []):
			saved_surfaces.append({
				"id": str(surface.get("id", "")),
				"pos": [float(surface["pos"].x), float(surface["pos"].y)],
				"radius": float(surface.get("radius", 26.0)),
				"height": float(surface.get("height", 0.05)),
			})
		saved_foods.append({
			"id": str(food.get("id", "")),
			"kind": str(food.get("kind", "banana")),
			"center": [float(food["center"].x), float(food["center"].y)],
			"rotation": float(food.get("rotation", 0.0)),
			"variant": int(food.get("variant", 0)),
			"amount": float(food.get("amount", 0.0)),
			"max_amount": float(food.get("max_amount", BANANA_MAX_NUTRITION)),
			"surfaces": saved_surfaces,
		})
	var payload := {
		"schema_version": WORLD_SAVE_SCHEMA,
		"garden_version": GARDEN_VERSION,
		"engine_version": Engine.get_version_info().get("string", "unknown"),
		"config_version": 1,
		"world_uuid": world_uuid,
		"initial_population": initial_population,
		"next_id_number": next_id_number,
		"next_food_id": next_food_id,
		"rng_state": rng.state,
		"sim_time": sim_time,
		"event_seq": event_seq,
		"event_log": event_log,
		"reproduction_timer": reproduction_timer,
		"foods": saved_foods,
		"paused": paused,
		"environment": environment,
		"predators": saved_predators,
		"flies": saved_flies,
	}
	var save_path_absolute := ProjectSettings.globalize_path(WORLD_SAVE_PATH)
	var temp_path := save_path_absolute + ".tmp"
	var backup_path := save_path_absolute + ".bak"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.close()
	if FileAccess.file_exists(WORLD_SAVE_PATH):
		DirAccess.copy_absolute(WORLD_SAVE_PATH, backup_path)
		DirAccess.remove_absolute(WORLD_SAVE_PATH)
	var rename_error := DirAccess.rename_absolute(temp_path, save_path_absolute)
	if rename_error != OK and FileAccess.file_exists(backup_path):
		DirAccess.copy_absolute(backup_path, save_path_absolute)


func _load_world_snapshot() -> void:
	if not FileAccess.file_exists(WORLD_SAVE_PATH):
		return
	var file := FileAccess.open(WORLD_SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return
	var schema_version := int(parsed.get("schema_version", 0))
	if schema_version < 1 or schema_version > WORLD_SAVE_SCHEMA:
		return
	var saved_garden_version := int(parsed.get("garden_version", 0))
	if saved_garden_version not in [2, 3, GARDEN_VERSION]:
		return
	var saved_flies = parsed.get("flies", [])
	if not saved_flies is Array or saved_flies.size() < 2:
		return
	if saved_flies.size() > ACTIVE_CAPACITY:
		return
	var restored: Array = []
	var max_saved_number := 0
	var seen_ids: Dictionary = {}
	for record in saved_flies:
		if not record is Dictionary:
			continue
		var fly_id := str(record.get("id", ""))
		if fly_id.is_empty():
			continue
		if seen_ids.has(fly_id):
			return
		seen_ids[fly_id] = true
		if fly_id.begins_with("FLY-"):
			max_saved_number = max(max_saved_number, fly_id.substr(4).to_int())
		var family := str(record.get("family", "赤枝"))
		var color := Color(0.43, 0.84, 0.98) if family == "赤枝" else Color(0.99, 0.62, 0.38)
		var raw_pos = record.get("pos", [])
		var start_pos := Vector2(445, 420)
		if raw_pos is Array and raw_pos.size() >= 2:
			start_pos = _clamp_room_point(Vector2(float(raw_pos[0]), float(raw_pos[1])))
		var stage := str(record.get("life_stage", "adult"))
		if not STAGE_DURATIONS.has(stage):
			stage = "adult"
		var fly := _make_fly(
			fly_id,
			start_pos,
			color,
			clamp(float(record.get("hunger", 0.3)), 0.0, 1.0),
			clamp(float(record.get("fatigue", 0.2)), 0.0, 1.0),
			clamp(float(record.get("courage", 0.5)), 0.0, 1.0),
			family,
			str(record.get("sex", "未知")),
			stage,
			int(record.get("generation", 0)),
			record.get("parent_ids", []) if record.get("parent_ids", []) is Array else []
		)
		fly["alive"] = bool(record.get("alive", true))
		fly["age_seconds"] = max(0.0, float(record.get("age_seconds", 0.0)))
		fly["stage_age"] = max(0.0, float(record.get("stage_age", 0.0)))
		fly["stage_duration"] = max(1.0, float(record.get("stage_duration", ADULT_LIFESPAN_MIN if stage == "adult" else STAGE_DURATIONS.get(stage, STAGE_DURATIONS["egg"]))))
		fly["life_span_seconds"] = max(ADULT_LIFESPAN_MIN, float(record.get("life_span_seconds", fly.get("life_span_seconds", ADULT_LIFESPAN_MIN)))) if stage == "adult" else float(record.get("life_span_seconds", 0.0))
		fly["growth"] = clamp(float(record.get("growth", fly["growth"])), 0.0, 1.0)
		fly["death_reason"] = str(record.get("death_reason", ""))
		fly["reproduction_cooldown"] = max(0.0, float(record.get("reproduction_cooldown", 0.0)))
		fly["mate_id"] = str(record.get("mate_id", ""))
		fly["courtship_timer"] = max(0.0, float(record.get("courtship_timer", 0.0)))
		fly["mating_timer"] = max(0.0, float(record.get("mating_timer", 0.0)))
		fly["sex_roll"] = clamp(float(record.get("sex_roll", fly.get("sex_roll", 0.5))), 0.0, 1.0)
		fly["stress"] = clamp(float(record.get("stress", fly["stress"])), 0.0, 1.0)
		fly["water"] = clamp(float(record.get("water", fly["water"])), 0.0, 1.0)
		fly["curiosity"] = clamp(float(record.get("curiosity", fly["curiosity"])), 0.0, 1.0)
		fly["action"] = str(record.get("action", fly["action"]))
		var saved_target = record.get("target_pos", [])
		if saved_target is Array and saved_target.size() >= 2:
			fly["target"] = _clamp_room_point(Vector2(float(saved_target[0]), float(saved_target[1])))
		var saved_flight_start = record.get("flight_start", [])
		if saved_flight_start is Array and saved_flight_start.size() >= 2:
			fly["flight_start"] = _clamp_room_point(Vector2(float(saved_flight_start[0]), float(saved_flight_start[1])))
		var saved_flight_target = record.get("flight_target", [])
		if saved_flight_target is Array and saved_flight_target.size() >= 2:
			fly["flight_target"] = _clamp_room_point(Vector2(float(saved_flight_target[0]), float(saved_flight_target[1])))
		var saved_velocity = record.get("velocity", [])
		if saved_velocity is Array and saved_velocity.size() >= 2:
			fly["velocity"] = Vector2(float(saved_velocity[0]), float(saved_velocity[1]))
		fly["support_id"] = str(record.get("support_id", "ground"))
		fly["support_kind"] = str(record.get("support_kind", "ground"))
		fly["support_height"] = float(record.get("support_height", 0.0))
		fly["flight"] = bool(record.get("flight", false))
		fly["flight_timer"] = max(0.0, float(record.get("flight_timer", 0.0)))
		fly["flight_duration"] = clampf(float(record.get("flight_duration", fly.get("flight_duration", 1.5))), 0.2, 8.0)
		fly["flight_height"] = clampf(float(record.get("flight_height", 0.0)), 0.0, 2.0)
		fly["flight_surface_id"] = str(record.get("flight_surface_id", ""))
		fly["flight_cooldown"] = max(0.0, float(record.get("flight_cooldown", 0.0)))
		fly["clash_cooldown"] = max(0.0, float(record.get("clash_cooldown", 0.0)))
		fly["action_timer"] = max(0.0, float(record.get("action_timer", 0.0)))
		fly["think_timer"] = max(0.0, float(record.get("think_timer", 0.0)))
		fly["memory"] = record.get("memory", fly["memory"]).duplicate(true) if record.get("memory", fly["memory"]) is Dictionary else fly["memory"]
		fly["recent_events"] = record.get("recent_events", []).duplicate(true) if record.get("recent_events", []) is Array else []
		if not bool(fly["alive"]):
			fly["action"] = "死亡"
		restored.append(fly)
	if restored.size() != saved_flies.size():
		return
	if restored.size() < 2:
		return
	flies = restored
	world_uuid = str(parsed.get("world_uuid", world_uuid))
	var saved_population := int(parsed.get("initial_population", restored.size()))
	if saved_population in [4, 8, 30]:
		initial_population = saved_population
	next_id_number = max(max_saved_number + 1, int(parsed.get("next_id_number", next_id_number)))
	next_food_id = max(1, int(parsed.get("next_food_id", next_food_id)))
	if parsed.has("rng_state"):
		rng.state = int(parsed.get("rng_state", rng.state))
	sim_time = max(0.0, float(parsed.get("sim_time", 0.0)))
	event_seq = max(0, int(parsed.get("event_seq", event_seq)))
	var saved_event_log = parsed.get("event_log", [])
	if saved_event_log is Array:
		event_log = saved_event_log
	reproduction_timer = max(0.0, float(parsed.get("reproduction_timer", 0.0)))
	_initialize_foods()
	var saved_foods = parsed.get("foods", [])
	if saved_foods is Array and not saved_foods.is_empty():
		foods.clear()
		for raw_food in saved_foods:
			if not raw_food is Dictionary:
				continue
			var raw_center = raw_food.get("center", [])
			if not raw_center is Array or raw_center.size() < 2:
				continue
			var center := _clamp_room_point(Vector2(float(raw_center[0]), float(raw_center[1])))
			var loaded_food_id := str(raw_food.get("id", "banana"))
			var food_kind := str(raw_food.get("kind", "banana"))
			var rotation := float(raw_food.get("rotation", 0.0))
			if food_kind == "banana":
				if loaded_food_id == "banana_a":
					center = FOOD_POS
					rotation = 0.16
				elif loaded_food_id == "banana_b":
					center = FOOD_POS_B
					rotation = -0.18
			if loaded_food_id.begins_with("candy-"):
				next_food_id = max(next_food_id, loaded_food_id.trim_prefix("candy-").to_int() + 1)
			var food := _make_banana_food(loaded_food_id, center, rotation, int(raw_food.get("variant", 0)))
			food["kind"] = food_kind
			food["max_amount"] = max(1.0, float(raw_food.get("max_amount", BANANA_MAX_NUTRITION)))
			food["amount"] = clamp(float(raw_food.get("amount", food["max_amount"])), 0.0, food["max_amount"])
			var raw_surfaces = raw_food.get("surfaces", [])
			if raw_surfaces is Array and not raw_surfaces.is_empty() and not (food_kind == "banana" and saved_garden_version < GARDEN_VERSION):
				food["surfaces"] = []
				for raw_surface in raw_surfaces:
					if not raw_surface is Dictionary:
						continue
					var raw_surface_pos = raw_surface.get("pos", [])
					if raw_surface_pos is Array and raw_surface_pos.size() >= 2:
						food["surfaces"].append({"id": str(raw_surface.get("id", "surface")), "pos": _clamp_room_point(Vector2(float(raw_surface_pos[0]), float(raw_surface_pos[1]))), "radius": float(raw_surface.get("radius", 26.0)), "height": float(raw_surface.get("height", 0.05)), "occupants": []})
			foods.append(food)
	_update_food_state()
	paused = bool(parsed.get("paused", false))
	var saved_environment = parsed.get("environment", {})
	if saved_environment is Dictionary:
		environment["temperature"] = clamp(float(saved_environment.get("temperature", 25.0)), 18.0, 32.0)
		environment["humidity"] = clamp(float(saved_environment.get("humidity", 60.0)), 30.0, 80.0)
		environment["light"] = clamp(float(saved_environment.get("light", 65.0)), 0.0, 100.0)
	predators.clear()
	var saved_predators = parsed.get("predators", [])
	if saved_predators is Array:
		for raw_predator in saved_predators:
			if not raw_predator is Dictionary:
				continue
			var raw_pos = raw_predator.get("pos", [])
			if raw_pos is Array and raw_pos.size() >= 2 and predators.size() < 3:
				predators.append(_make_predator(Vector2(float(raw_pos[0]), float(raw_pos[1])), raw_predator))
	selected_index = clamp(selected_index, 0, flies.size() - 1)
	_event("系统", "读取生态箱快照，保留永久编号与虫生记录。")


func _load_history() -> void:
	# Migrate old standalone insect memories; current worlds persist these
	# directly in flyworld_world.json and no longer write competition archives.
	if not FileAccess.file_exists(LEGACY_HISTORY_PATH):
		return
	var file := FileAccess.open(LEGACY_HISTORY_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var saved_memories = parsed.get("memories", [])
	if saved_memories is Array and saved_memories.size() == flies.size():
		for i in range(flies.size()):
			if saved_memories[i] is Dictionary:
				flies[i]["memory"] = saved_memories[i]


func _on_sugar_pressed() -> void:
	tool_mode = "sugar"


func _on_predator_pressed() -> void:
	if predators.size() >= 3:
		return
	tool_mode = "predator"


func _on_delete_predator_pressed() -> void:
	if predators.is_empty():
		return
	tool_mode = "delete_predator"


func _on_pause_pressed() -> void:
	paused = not paused
	pause_button.text = "继续" if paused else "暂停"


func _on_speed_pressed(value: float) -> void:
	if not [1.0, 2.0, 5.0, 10.0].has(value):
		return
	speed_multiplier = value


func _on_bridge_pressed() -> void:
	bridge_startup_deadline = 0
	if neural_adapter.is_bridge_active():
		neural_adapter.disconnect_bridge()
		if brain_view != null:
			brain_view.set_activity({}, {})
	else:
		neural_adapter.connect_bridge()


func _on_new_round_pressed() -> void:
	initial_population = 8
	pause_button.text = "暂停"
	# A new round is a fresh numbered world: the first orange and blue adults
	# always start at 01 again. Historical files remain on disk, but they are
	# not used to seed the new round's live records.
	_reset_flies()
	selected_index = clamp(selected_index, 0, flies.size() - 1)
	neural_adapter.begin_world(world_uuid)
	if not flies.is_empty():
		neural_adapter.set_selection(str(flies[selected_index]["id"]), str(flies[selected_index].get("life_stage", "adult")))


func _on_temperature_changed(value: float) -> void:
	environment["temperature"] = value


func _on_humidity_changed(value: float) -> void:
	environment["humidity"] = value


func _on_light_changed(value: float) -> void:
	environment["light"] = value


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_ESCAPE:
			tool_mode = ""
		return
	if not event is InputEventMouseButton:
		return

	var in_garden := runtime_garden_rect.has_point(event.position)
	# GardenView3D owns camera gestures; handle each wheel event only once.
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and in_garden:
		tool_mode = ""
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed or not in_garden:
		return

	if tool_mode == "delete_predator":
		var spider_index := int(garden_view.pick_spider(event.position))
		if spider_index >= 0 and spider_index < predators.size():
			predators.remove_at(spider_index)
			_event("天敌", "天敌离开了花园。")
		tool_mode = ""
		return

	var point: Vector2 = garden_view.screen_to_ground(event.position)
	if tool_mode.is_empty():
		var picked: int = _index_for_id(garden_view.pick_fly(event.position))
		if picked >= 0 and picked < flies.size():
			selected_index = picked
			_clear_brain_activity()
			neural_adapter.set_selection(str(flies[selected_index]["id"]), str(flies[selected_index]["life_stage"]))
			_refresh_ui()
		return

	if not point.is_finite() or not ROOM_RECT.grow(-ROOM_MARGIN).has_point(point) or _is_inside_blocking_furniture(point):
		return
	if tool_mode == "sugar":
		foods.append(_make_sugar_food(point))
		tool_mode = ""
		_event("环境", "糖果放在了花园里。")
		return
	if tool_mode == "predator":
		if predators.size() < 3:
			predators.append(_make_predator(point))
			_event("天敌", "一只天敌进入了花园。")
		tool_mode = ""
		return
	tool_mode = ""


func _present_activity(fly: Dictionary, activity: Dictionary) -> void:
	if brain_view == null:
		return
	# The local proxy is useful for ecological behavior, but it is not a brain
	# recording. Never present its synthetic state as a neural signal.
	if neural_adapter.bridge_state != "malecns":
		return
	var stage := str(fly["life_stage"])
	if brain_view_stage != stage:
		brain_view.set_catalog(larva_brain_catalog if stage == "larva" else adult_brain_catalog, stage)
		brain_view_stage = stage
	last_observed_id = str(fly["id"])
	last_observed_stage = stage
	brain_view.set_activity({}, activity)


func _clear_brain_activity() -> void:
	for index in range(flies.size()):
		flies[index]["brain_activity"] = {}
		flies[index]["activity_received_ms"] = 0
		flies[index]["brain_readout"] = {}
		flies[index]["brain_readout_time_ms"] = 0
	brain_control_enabled = false
	if brain_view != null:
		brain_view.set_activity({}, {})


func _refresh_ui() -> void:
	if flies.is_empty() or not is_instance_valid(selected_label):
		return
	selected_index = clamp(selected_index, 0, flies.size() - 1)
	var fly: Dictionary = flies[selected_index]
	selected_label.text = "%s · %s · %s\n行动：%s%s · 饥饿%d%% 水分%d%% 压力%d%%" % [
		_display_name(fly["id"]), fly["sex"], _stage_label(str(fly.get("life_stage", "adult"))),
		fly["action"], " · 飞行中" if fly["flight"] else "",
		int(float(fly["hunger"]) * 100.0), int(float(fly.get("water", 0.0)) * 100.0), int(float(fly["stress"]) * 100.0),
	]
	if event_feed_label != null:
		var lines: Array[String] = []
		var seen_events := {}
		var selected_id := str(fly["id"])
		for global_index in range(event_log.size() - 1, -1, -1):
			var global_event: Dictionary = event_log[global_index]
			var participants: Array = global_event.get("participants", []) if global_event.get("participants", []) is Array else []
			if str(global_event.get("actor", "")) != selected_id and not participants.has(selected_id):
				continue
			var event_key := _event_summary(str(global_event.get("text", "")))
			var event_sentence := _format_event_line(global_event).left(36)
			if not event_sentence.is_empty() and not seen_events.has(event_key):
				seen_events[event_key] = true
				lines.append(event_sentence)
			if lines.size() >= 4:
				break
		if lines.size() < 4:
			var recent: Array = fly.get("recent_events", [])
			for recent_index in range(recent.size() - 1, -1, -1):
				var recent_event: Dictionary = recent[recent_index]
				var recent_key := _event_summary(str(recent_event.get("action", "")))
				var recent_sentence := _format_event_line({
					"t": recent_event.get("t", sim_time),
					"text": str(recent_event.get("action", "")) + " · " + str(recent_event.get("reason", "")),
				}).left(36)
				if not recent_sentence.is_empty() and not seen_events.has(recent_key):
					seen_events[recent_key] = true
					lines.append(recent_sentence)
				if lines.size() >= 4:
					break
		event_feed_label.text = "\n".join(lines)
	temperature_value.text = "温度   %.1f°C" % float(environment["temperature"])
	humidity_value.text = "湿度   %.0f%%" % float(environment["humidity"])
	light_value.text = "光照   %.0f%%" % float(environment["light"])
	top_state_label.text = "%d/%d  · %.0fs · x%d%s" % [_active_count(), ACTIVE_CAPACITY, sim_time, int(speed_multiplier), " · 已暂停" if paused else ""]
	var stage := str(fly.get("life_stage", "adult"))
	if brain_control_button != null:
		if neural_adapter.bridge_state == "connecting":
			brain_control_button.text = "连接中"
		elif neural_adapter.bridge_state == "malecns":
			brain_control_button.text = "断开大脑"
		else:
			brain_control_button.text = "连接大脑"
		brain_control_button.disabled = false
	var id := str(fly["id"])
	if id != last_observed_id or stage != last_observed_stage:
		fly["brain_activity"] = {}
		last_observed_id = id
		last_observed_stage = stage
	var observable := bool(fly.get("alive", true)) and stage in ["adult", "larva"]
	brain_view.visible = observable
	# Never expose a hover tooltip or explanatory overlay over the garden.
	brain_view.tooltip_text = ""
	if observable:
		if stage != brain_view_stage:
			brain_view.set_catalog(larva_brain_catalog if stage == "larva" else adult_brain_catalog, stage)
			brain_view_stage = stage
		var activity: Dictionary = fly.get("brain_activity", {})
		if neural_adapter.bridge_state != "malecns" or (not paused and Time.get_ticks_msec() - int(fly.get("activity_received_ms", 0)) > 1500):
			activity = {}
			fly["brain_activity"] = {}
			fly["activity_received_ms"] = 0
			fly["brain_readout"] = {}
			fly["brain_readout_time_ms"] = 0
			flies[selected_index] = fly
		brain_view.set_activity({}, activity)


func _event_summary(text_value: String) -> String:
	var separator_index := text_value.find(" · ")
	return text_value if separator_index < 0 else text_value.left(separator_index)


func _format_event_line(event: Dictionary) -> String:
	var seconds := maxi(0, int(float(event.get("t", sim_time))))
	var stamp := "%02d:%02d" % [seconds / 60, seconds % 60]
	var text_value := str(event.get("text", ""))
	var separator_index := text_value.find(" · ")
	if separator_index >= 0:
		text_value = text_value.left(separator_index) + "：" + text_value.substr(separator_index + 3)
	return stamp + "  " + text_value


func _stage_label(stage: String) -> String:
	return {"egg": "卵", "larva": "幼虫", "pupa": "蛹", "adult": "成虫"}.get(stage, stage)


func _load_brain_catalogs() -> void:
	adult_brain_catalog = _read_json_catalog("res://assets/morphology/adult.json")
	larva_brain_catalog = _read_json_catalog("res://assets/morphology/larva.json")
	if brain_view != null and adult_brain_catalog.size() > 0:
		brain_view.set_catalog(adult_brain_catalog, "adult")
		brain_view_stage = "adult"


func _read_json_catalog(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _draw() -> void:
	var viewport_size := get_viewport_rect().size
	if runtime_panel_rect.size == Vector2.ZERO:
		runtime_panel_rect = _calculate_panel_rect()
		runtime_garden_rect = _calculate_garden_rect()
	draw_rect(Rect2(Vector2.ZERO, viewport_size), Color("12251d"))
	draw_rect(Rect2(Vector2(0, 0), Vector2(viewport_size.x, TOP_BAR_HEIGHT)), Color(0.06, 0.15, 0.11, 0.86))
	draw_rect(runtime_panel_rect, Color(0.035, 0.11, 0.08, 0.73))
	draw_line(Vector2(runtime_panel_rect.position.x, runtime_panel_rect.position.y), runtime_panel_rect.position + Vector2(0, runtime_panel_rect.size.y), Color(0.37, 0.62, 0.42, 0.45), 1.0)
	var panel_height := runtime_panel_rect.size.y
	var state_height := minf(SIDEBAR_STATE_HEIGHT, maxf(74.0, panel_height * 0.18))
	var event_height := minf(SIDEBAR_EVENT_HEIGHT, maxf(92.0, panel_height * 0.22))
	var event_y := runtime_panel_rect.position.y + state_height
	var brain_y := event_y + event_height
	var controls_y := runtime_panel_rect.end.y - SIDEBAR_CONTROLS_HEIGHT
	draw_line(Vector2(runtime_panel_rect.position.x + 12, event_y), Vector2(runtime_panel_rect.end.x - 12, event_y), Color(0.25, 0.46, 0.31, 0.50), 1.0)
	draw_line(Vector2(runtime_panel_rect.position.x, brain_y), Vector2(runtime_panel_rect.end.x, brain_y), Color(0.25, 0.46, 0.31, 0.50), 1.0)
	draw_line(Vector2(runtime_panel_rect.position.x + 12, controls_y), Vector2(runtime_panel_rect.end.x - 12, controls_y), Color(0.25, 0.46, 0.31, 0.50), 1.0)
