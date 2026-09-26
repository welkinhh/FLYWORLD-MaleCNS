extends SubViewportContainer

## The supplied backyard illustration is the environment. Living creatures are
## rendered from the supplied sprite atlas at their simulated world positions.

const WORLD_RECT := Rect2(32, 78, 820, 620)
const UNIT := 0.026
const DEFAULT_CAMERA_SIZE := 16.8
const MIN_CAMERA_SIZE := 10.0
const MAX_CAMERA_SIZE := 24.0
const ADULT_VISUAL_SCALE := 2.88
const OTHER_VISUAL_SCALE := 2.4
const ACTOR_DEPTH := 12.0
const BACKGROUND_DEPTH := 30.0

var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var background_sprite: Sprite3D
var atlas_textures: Dictionary = {}
var actors: Dictionary = {}
var food_nodes: Dictionary = {}
var spider_nodes: Array[Node3D] = []
var visual_time := 0.0
var last_world := ""
var camera_pan := Vector2.ZERO
var camera_dragging := false
var camera_drag_start := Vector2.ZERO
var camera_drag_start_pan := Vector2.ZERO
var light_level := 65.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	stretch = true
	viewport = SubViewport.new()
	viewport.size = Vector2i(maxi(1, int(size.x)), maxi(1, int(size.y)))
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.1
	camera.far = 80.0
	world.add_child(camera)
	reset_camera()
	_load_sprite_atlas()
	_create_background()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and viewport != null:
		viewport.size = Vector2i(maxi(1, int(size.x)), maxi(1, int(size.y)))
		_update_background()


func _load_sprite_atlas() -> void:
	var texture := ResourceLoader.load("res://assets/sprites/creature_sheet.jpg") as Texture2D
	if texture == null:
		return
	var sheet := texture.get_image()
	if sheet == null or sheet.is_empty():
		return
	sheet.convert(Image.FORMAT_RGBA8)
	var crops := {
		"fly_red": Rect2i(55, 12, 385, 365),
		"fly_blue": Rect2i(455, 18, 402, 360),
		"sugar": Rect2i(865, 55, 395, 335),
		"larva": Rect2i(55, 456, 420, 315),
		"pupa": Rect2i(515, 435, 310, 320),
		"spider": Rect2i(770, 430, 480, 310),
	}
	for key in crops:
		var crop: Rect2i = crops[key]
		if crop.position.x + crop.size.x > sheet.get_width() or crop.position.y + crop.size.y > sheet.get_height():
			continue
		var sprite_image := sheet.get_region(crop)
		for y in range(sprite_image.get_height()):
			for x in range(sprite_image.get_width()):
				var pixel := sprite_image.get_pixel(x, y)
				var minimum := minf(pixel.r, minf(pixel.g, pixel.b))
				var spread := maxf(pixel.r, maxf(pixel.g, pixel.b)) - minimum
				if minimum > 0.88 and spread < 0.14:
					pixel.a = clampf((0.995 - minimum) / 0.115, 0.0, 1.0)
					sprite_image.set_pixel(x, y, pixel)
		atlas_textures[key] = ImageTexture.create_from_image(sprite_image)


func _create_background() -> void:
	var texture := ResourceLoader.load("res://assets/environment/backyard_ground.jpg") as Texture2D
	if texture == null:
		return
	background_sprite = Sprite3D.new()
	background_sprite.name = "IllustratedBackyard"
	background_sprite.texture = texture
	background_sprite.shaded = false
	background_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	world.add_child(background_sprite)
	_update_background()


func _update_background() -> void:
	if background_sprite == null or camera == null or viewport == null:
		return
	var texture_size := background_sprite.texture.get_size()
	var view_aspect := float(viewport.size.x) / maxf(float(viewport.size.y), 1.0)
	background_sprite.pixel_size = maxf(
		camera.size / float(texture_size.y),
		camera.size * view_aspect / float(texture_size.x)
	)
	background_sprite.position = Vector3(-camera_pan.x * UNIT, camera_pan.y * UNIT, -BACKGROUND_DEPTH)
	var illumination := lerpf(0.48, 1.0, clampf(light_level / 100.0, 0.0, 1.0))
	background_sprite.modulate = Color(illumination, illumination, illumination)


func _make_sprite(parent: Node3D, key: String, pixel_size: float, scale: float = 1.0) -> Sprite3D:
	if not atlas_textures.has(key):
		return null
	var sprite := Sprite3D.new()
	sprite.name = "ReferenceSprite"
	sprite.texture = atlas_textures[key]
	sprite.pixel_size = pixel_size
	sprite.shaded = false
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.scale = Vector3.ONE * scale
	sprite.position.y = float(sprite.texture.get_height()) * pixel_size * scale * 0.5
	parent.add_child(sprite)
	return sprite


func _logical_to_view(point: Vector2) -> Vector2:
	var viewport_size := Vector2(viewport.size)
	var center := WORLD_RECT.get_center() + camera_pan
	var scale := viewport_size.y * UNIT / camera.size
	return viewport_size * 0.5 + (point - center) * scale


func to_world(point: Vector2, height: float = 0.0) -> Vector3:
	var view_point := _logical_to_view(point)
	view_point.y -= height / camera.size * float(viewport.size.y)
	return camera.project_position(view_point, ACTOR_DEPTH)


func screen_to_ground(point: Vector2) -> Vector2:
	var local := point - global_position
	var viewport_size := Vector2(viewport.size)
	var logical_per_pixel := camera.size / (UNIT * maxf(viewport_size.y, 1.0))
	return WORLD_RECT.get_center() + camera_pan + (local - viewport_size * 0.5) * logical_per_pixel


func pick_fly(point: Vector2) -> String:
	var best_id := ""
	var best_distance := 30.0
	for id in actors:
		var root: Node3D = actors[id]
		var sprite := root.get_node_or_null("ReferenceSprite") as Sprite3D
		var pick_position: Vector3 = sprite.global_position if sprite != null else root.global_position
		var projected := global_position + camera.unproject_position(pick_position)
		var distance := point.distance_to(projected)
		if distance < best_distance:
			best_distance = distance
			best_id = str(id)
	return best_id


func pick_spider(point: Vector2) -> int:
	for index in range(spider_nodes.size()):
		var spider := spider_nodes[index]
		var sprite := spider.get_node_or_null("ReferenceSprite") as Sprite3D
		if sprite == null:
			continue
		var projected := global_position + camera.unproject_position(sprite.global_position)
		if point.distance_to(projected) < 34.0:
			return index
	return -1


func zoom_by(amount: float) -> void:
	if camera == null:
		return
	camera.size = clampf(camera.size + amount, MIN_CAMERA_SIZE, MAX_CAMERA_SIZE)
	_update_background()


func reset_camera() -> void:
	if camera == null:
		return
	camera_pan = Vector2.ZERO
	camera.position = Vector3.ZERO
	camera.look_at(Vector3(0, 0, -1), Vector3.UP)
	camera.size = DEFAULT_CAMERA_SIZE
	_update_background()


func _make_actor(fly: Dictionary) -> Node3D:
	var root := Node3D.new()
	var stage := str(fly.get("life_stage", "adult"))
	var visual_scale := ADULT_VISUAL_SCALE if stage == "adult" else OTHER_VISUAL_SCALE
	root.scale = Vector3.ONE * visual_scale
	root.set_meta("stage", stage)
	world.add_child(root)

	var sprite_key := "fly_red" if str(fly.get("family", "")) == "赤枝" else "fly_blue"
	var pixel_size := 0.00048
	var sprite_scale := 1.0
	if stage == "larva":
		sprite_key = "larva"
		pixel_size = 0.00044
	elif stage == "pupa":
		sprite_key = "pupa"
		pixel_size = 0.00065
	elif stage == "egg":
		sprite_key = "pupa"
		pixel_size = 0.00065
		sprite_scale = 0.36
	var sprite := _make_sprite(root, sprite_key, pixel_size, sprite_scale)
	if stage == "egg" and sprite != null:
		sprite.modulate = Color("fff2d6")
	var image_height := float(sprite.texture.get_height()) * pixel_size * sprite_scale if sprite != null else 0.12

	var label := Label3D.new()
	label.name = "Number"
	label.text = "%02d" % str(fly.get("id", "")).get_slice("-", 1).to_int()
	label.font_size = 24
	label.pixel_size = 0.0035
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.outline_size = 5
	label.modulate = Color("ff9a3d") if str(fly.get("family", "")) == "赤枝" else Color("48d6df")
	label.outline_modulate = Color("17251f")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = image_height + float(label.font_size) * label.pixel_size * 0.5 + 0.025
	root.add_child(label)
	return root


func _sync_foods(foods: Array) -> void:
	var current := {}
	for food in foods:
		var id := str(food.get("id", ""))
		# The opened bananas are painted into the supplied backyard image.
		if id.is_empty() or str(food.get("kind", "banana")) == "banana":
			continue
		current[id] = true
		if not food_nodes.has(id):
			var candy := Node3D.new()
			candy.name = id
			candy.scale = Vector3.ONE * 0.90
			world.add_child(candy)
			_make_sprite(candy, "sugar", 0.0009)
			food_nodes[id] = candy
		var candy_node: Node3D = food_nodes[id]
		candy_node.position = to_world(food["center"])
		candy_node.visible = float(food.get("amount", 1.0)) > 0.01
	for id in food_nodes.keys():
		if not current.has(id):
			food_nodes[id].queue_free()
			food_nodes.erase(id)


func _sync_spiders(predators: Array) -> void:
	while spider_nodes.size() > predators.size():
		spider_nodes.pop_back().queue_free()
	while spider_nodes.size() < predators.size():
		var spider := Node3D.new()
		world.add_child(spider)
		_make_sprite(spider, "spider", 0.0010)
		spider_nodes.append(spider)
	for index in range(predators.size()):
		var predator: Dictionary = predators[index]
		var spider: Node3D = spider_nodes[index]
		spider.position = to_world(predator["pos"], minf(float(predator.get("support_height", 0.0)), 0.12))
		var sprite := spider.get_node_or_null("ReferenceSprite") as Sprite3D
		if sprite != null:
			var velocity: Vector2 = predator.get("velocity", Vector2.ZERO)
			if absf(velocity.x) > 0.2:
				sprite.flip_h = velocity.x < 0.0


func sync_state(flies: Array, predators: Array, foods: Array, selected_id: String, delta: float, is_paused: bool, _light: float, world_id: String, _terrain_surfaces: Array = []) -> void:
	if world == null:
		return
	if world_id != last_world:
		for actor in actors.values():
			actor.queue_free()
		actors.clear()
		for food_node in food_nodes.values():
			food_node.queue_free()
		food_nodes.clear()
		last_world = world_id
	if not is_paused:
		visual_time += delta
	_update_background()
	var living := {}
	for fly in flies:
		if not bool(fly.get("alive", true)):
			continue
		var id := str(fly["id"])
		living[id] = true
		if actors.has(id) and actors[id].get_meta("stage") != str(fly.get("life_stage", "adult")):
			actors[id].queue_free()
			actors.erase(id)
		if not actors.has(id):
			actors[id] = _make_actor(fly)
		var actor: Node3D = actors[id]
		var lift := float(fly.get("flight_height", 0.0)) + minf(float(fly.get("support_height", 0.0)), 0.08)
		actor.position = to_world(Vector2(fly.get("render_pos", fly["pos"])), lift)
		var sprite := actor.get_node_or_null("ReferenceSprite") as Sprite3D
		if sprite != null and str(fly.get("life_stage", "adult")) == "adult":
			var velocity: Vector2 = fly.get("velocity", Vector2.ZERO)
			if absf(velocity.x) > 0.2:
				sprite.flip_h = velocity.x < 0.0
			var flap := sin(visual_time * 54.0 + float(fly.get("wing_phase", 0.0)))
			sprite.rotation.z = flap * 0.018 if bool(fly.get("flight", false)) and not is_paused else 0.0
		var label := actor.get_node_or_null("Number") as Label3D
		if label != null:
			var selected := str(fly["id"]) == selected_id
			label.modulate = Color("ffdc81") if selected else (Color("ff9a3d") if str(fly.get("family", "")) == "赤枝" else Color("48d6df"))
	for id in actors.keys():
		if not living.has(id):
			actors[id].queue_free()
			actors.erase(id)
	_sync_foods(foods)
	_sync_spiders(predators)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			camera_dragging = event.pressed
			camera_drag_start = event.position
			camera_drag_start_pan = camera_pan
			if event.pressed:
				accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom_by(-0.55)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom_by(0.55)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			reset_camera()
			accept_event()
	elif event is InputEventMouseMotion and camera_dragging:
		var movement: Vector2 = event.position - camera_drag_start
		var logical_per_pixel := camera.size / (UNIT * maxf(float(viewport.size.y), 1.0))
		camera_pan = camera_drag_start_pan - movement * logical_per_pixel
		_update_background()
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		camera_dragging = false
