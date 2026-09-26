extends SubViewportContainer

## A small, inspectable 3D tube renderer for real SWC morphology slices.
##
## The source catalog is generated from MaleCNS/L1EM SWC files. This node only
## renders the supplied parent-child paths; it never invents connections.
## Activity arrives as source neuron IDs. Point markers show the complete
## source-ID frame; morphology pulses are drawn only for IDs that have a
## loaded parent-child segment list. They are a visual traversal of topology,
## not a measured voltage or axonal conduction-delay simulation.

const TUBE_SIDES := 6
const DEFAULT_SIZE := Vector2i(330, 128)
const SIGNAL_TRAVEL_SECONDS := 0.36
const SIGNAL_TRAIL := 0.12
const SIGNAL_EVENT_LIMIT := 24

var viewport: SubViewport
var brain_world: Node3D
var brain_root: Node3D
var camera: Camera3D
var active_neuron_materials: Dictionary = {}
var morphology_segments: Dictionary = {}
var full_brain_instance: MeshInstance3D
var active_spike_instance: MeshInstance3D
var propagation_instance: MeshInstance3D
var propagation_material: StandardMaterial3D
var connectome_edges_instance: MeshInstance3D
var branch_lod_instance: MeshInstance3D
var summary_instance: MeshInstance3D
var full_brain_positions := PackedVector3Array()
var last_spike_signature := ""
var point_index: Dictionary = {}
var branch_positions := PackedVector3Array()
var branch_neuron_ranges: Dictionary = {}
var pulse_left: Dictionary = {}
var propagation_events: Array[Dictionary] = []
var last_activity_seq := -1
var activity_paused := false
var current_stage := "adult"
# The bundled MaleCNS position asset is the structural whole-brain backdrop;
# SWC tubes are overlaid as the verified detailed subset. Activity remains a
# separate source-ID layer and is never inferred from the backdrop.
var diagnostic_point_cloud := false
var show_connectome_edges := false
var yaw := 0.3
var pitch := -0.32
var zoom := 5.2
var dragging := false
var last_mouse := Vector2.ZERO
var catalog: Dictionary = {}
var last_activity: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	stretch = false
	clip_contents = true
	viewport = SubViewport.new()
	viewport.size = DEFAULT_SIZE
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_2X
	add_child(viewport)
	brain_world = Node3D.new()
	viewport.add_child(brain_world)
	brain_root = Node3D.new()
	brain_world.add_child(brain_root)
	var environment := WorldEnvironment.new()
	var world_environment := Environment.new()
	world_environment.background_mode = Environment.BG_COLOR
	world_environment.background_color = Color(0.012, 0.025, 0.04, 0.0)
	world_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world_environment.ambient_light_color = Color(0.16, 0.28, 0.35)
	world_environment.ambient_light_energy = 0.5
	world_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = world_environment
	brain_world.add_child(environment)
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 0.0, zoom)
	camera.current = true
	camera.fov = 42.0
	brain_world.add_child(camera)
	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-28.0, -35.0, 0.0)
	key_light.light_color = Color(0.44, 0.76, 0.9)
	key_light.light_energy = 1.6
	brain_world.add_child(key_light)
	var fill_light := OmniLight3D.new()
	fill_light.position = Vector3(-1.8, 1.2, 2.4)
	fill_light.light_color = Color(0.55, 0.3, 0.9)
	fill_light.light_energy = 1.5
	fill_light.omni_range = 8.0
	brain_world.add_child(fill_light)
	_apply_camera_transform()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and viewport != null:
		viewport.size = Vector2i(max(1, int(size.x)), max(1, int(size.y)))


func set_catalog(next_catalog: Dictionary, stage: String) -> void:
	# Reuse geometry for the same catalog, while honoring diagnostic toggles.
	if current_stage == stage and catalog == next_catalog:
		if stage == "adult" and full_brain_instance != null and is_instance_valid(full_brain_instance) and summary_instance != null and is_instance_valid(summary_instance):
			if show_connectome_edges and not is_instance_valid(connectome_edges_instance):
				_build_connectome_edges()
			if is_instance_valid(connectome_edges_instance):
				connectome_edges_instance.visible = show_connectome_edges
			if diagnostic_point_cloud and not is_instance_valid(branch_lod_instance):
				_build_branch_lod()
			if is_instance_valid(branch_lod_instance):
				branch_lod_instance.visible = diagnostic_point_cloud
			full_brain_instance.visible = diagnostic_point_cloud
			return
		if stage == "larva" and branch_lod_instance != null and is_instance_valid(branch_lod_instance):
			catalog = next_catalog
			return
	catalog = next_catalog
	current_stage = stage
	_build_catalog()
	if current_stage == "adult":
		_build_full_brain()
	elif current_stage == "larva":
		_build_larva_branch_lod()


func set_activity(_brain: Dictionary, activity: Dictionary = {}) -> void:
	var expected := "Winding2023-L1EM" if current_stage == "larva" else "MaleCNS-v1.0"
	if str(activity.get("dataset_id", "")) != expected:
		activity = {}
	last_activity = activity
	var seq := int(activity.get("request_seq", -1))
	if activity.is_empty():
		pulse_left.clear()
		propagation_events.clear()
		last_activity_seq = -1
	elif seq != last_activity_seq:
		for raw_id in activity.get("spike_ids", []):
			if active_neuron_materials.has(str(raw_id)):
				pulse_left[str(raw_id)] = 0.20
		for spike in activity.get("spike_events", []):
			if spike is Dictionary and active_neuron_materials.has(str(spike.get("neuron_id", ""))):
				pulse_left[str(spike.get("neuron_id", ""))] = 0.20
		_queue_propagation_events(activity)
		last_activity_seq = seq
	_apply_pulses()
	_update_spike_overlay(activity.get("spike_ids", []))
	_update_propagation_overlay()


func _process(delta: float) -> void:
	if activity_paused:
		return
	for neuron_id in pulse_left.keys():
		pulse_left[neuron_id] = maxf(0.0, float(pulse_left[neuron_id]) - delta)
	for event in propagation_events:
		event["elapsed"] = float(event.get("elapsed", 0.0)) + delta
	while not propagation_events.is_empty() and float(propagation_events[0].get("elapsed", 0.0)) >= float(propagation_events[0].get("duration", SIGNAL_TRAVEL_SECONDS)):
		propagation_events.pop_front()
	_apply_pulses()
	_update_propagation_overlay()


func _apply_pulses() -> void:
	for neuron_id in active_neuron_materials:
		var material: StandardMaterial3D = active_neuron_materials[neuron_id]
		# Short visual persistence of a received spike, never a synthetic spike.
		var value := clampf(float(pulse_left.get(str(neuron_id), 0.0)) / 0.20, 0.0, 1.0)
		# Keep the morphology readable while the moving propagation layer carries
		# the high-contrast signal. This avoids making the entire neuron flash as
		# a single object.
		material.emission_energy_multiplier = 0.35 + value * 1.2
		material.albedo_color = material.emission.lightened(0.12 + value * 0.35)


func _build_full_brain() -> void:
	if brain_root == null or current_stage != "adult":
		return
	if full_brain_instance != null and is_instance_valid(full_brain_instance):
		full_brain_instance.queue_free()
	if active_spike_instance != null and is_instance_valid(active_spike_instance):
		active_spike_instance.queue_free()
	if connectome_edges_instance != null and is_instance_valid(connectome_edges_instance):
		connectome_edges_instance.queue_free()
	if branch_lod_instance != null and is_instance_valid(branch_lod_instance):
		branch_lod_instance.queue_free()
	full_brain_instance = null
	active_spike_instance = null
	connectome_edges_instance = null
	branch_lod_instance = null
	full_brain_positions.clear()
	var path := "res://assets/morphology/adult_full_brain.bin"
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 4:
		return
	var count := int(file.get_32())
	var raw_positions := PackedVector3Array()
	var raw_ids := PackedInt64Array()
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for index in range(count):
		if file.get_position() + 20 > file.get_length():
			break
		var neuron_id := int(file.get_64())
		var point := Vector3(file.get_float(), file.get_float(), file.get_float())
		raw_ids.append(neuron_id)
		raw_positions.append(point)
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	var extent := maximum - minimum
	# Use the same transform recorded by the SWC catalog. The previous
	# implementation normalized the whole-brain point cloud independently,
	# which displaced detailed branches from the real brain backdrop.
	var transform: Dictionary = catalog.get("coordinate_transform", {})
	var center := (minimum + maximum) * 0.5
	var span: float = max(extent.x, max(extent.y, extent.z))
	var display_span: float = 3.7
	var raw_center = transform.get("center", [])
	if raw_center is Array and raw_center.size() >= 3:
		center = Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))
	span = maxf(1.0, float(transform.get("span", span)))
	display_span = float(transform.get("display_span", display_span))
	var scale: float = display_span / span
	for index in range(raw_positions.size()):
		full_brain_positions.append((raw_positions[index] - center) * scale)
		point_index[int(raw_ids[index])] = index
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = full_brain_positions
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.10, 0.40, 0.58, 0.42)
	material.vertex_color_use_as_albedo = false
	material.point_size = 1.45
	mesh.surface_set_material(0, material)
	full_brain_instance = MeshInstance3D.new()
	full_brain_instance.mesh = mesh
	full_brain_instance.visible = diagnostic_point_cloud
	full_brain_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brain_root.add_child(full_brain_instance)
	# The full center cloud is hidden in the default view; its sampled summary
	# points are the visible whole-brain scaffold. Avoid parsing two additional
	# high-density layers synchronously during startup when both are hidden.
	if show_connectome_edges:
		_build_connectome_edges()
	if diagnostic_point_cloud:
		_build_branch_lod()
	_build_summary_points(full_brain_positions, Color(0.28, 0.72, 0.86, 0.45), 120)


func _build_branch_lod() -> void:
	# The full source stream is an optional rebuild output. The viewer uses a
	# deterministic compact stream derived from every 14th source skeleton so
	# opening or switching a fly never blocks on a 160 MB sequential parse.
	var path := "res://assets/morphology/adult_runtime_branches.bin"
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return
	if file.get_buffer(4).get_string_from_ascii() != "FWBR":
		return
	var version := int(file.get_32())
	var count := int(file.get_32())
	if version != 1 or count <= 0:
		return
	var vertices := PackedVector3Array()
	for record_index in range(count):
		if file.get_position() + 12 > file.get_length():
			break
		file.get_64() # source body ID is retained in the asset; geometry is indexed by record.
		var node_count := int(file.get_32())
		var points := PackedVector3Array()
		var parents := PackedInt32Array()
		points.resize(node_count)
		parents.resize(node_count)
		for node_index in range(node_count):
			if file.get_position() + 20 > file.get_length():
				return
			points[node_index] = Vector3(file.get_float(), file.get_float(), file.get_float())
			file.get_float() # radius
			parents[node_index] = file.get_32()
		for node_index in range(node_count):
			var parent_index := int(parents[node_index])
			if parent_index >= 0 and parent_index < node_count:
				vertices.append(points[parent_index])
				vertices.append(points[node_index])
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.20, 0.82, 0.92, 0.10)
	material.no_depth_test = false
	mesh.surface_set_material(0, material)
	branch_lod_instance = MeshInstance3D.new()
	branch_lod_instance.mesh = mesh
	branch_lod_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brain_root.add_child(branch_lod_instance)
	branch_lod_instance.visible = diagnostic_point_cloud


func _build_larva_branch_lod() -> void:
	var path := "res://assets/morphology/larva_full_branches.bin"
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12 or file.get_buffer(4).get_string_from_ascii() != "FWBR":
		return
	var version := int(file.get_32())
	var count := int(file.get_32())
	if version != 1 or count <= 0:
		return
	var vertices := PackedVector3Array()
	branch_positions.clear()
	branch_neuron_ranges.clear()
	for _record_index in range(count):
		if file.get_position() + 12 > file.get_length():
			break
		var source_id := str(file.get_64())
		var node_count := int(file.get_32())
		var points := PackedVector3Array()
		var parents := PackedInt32Array()
		points.resize(node_count)
		parents.resize(node_count)
		var range_start := vertices.size()
		for node_index in range(node_count):
			if file.get_position() + 20 > file.get_length():
				return
			points[node_index] = Vector3(file.get_float(), file.get_float(), file.get_float())
			file.get_float()
			parents[node_index] = file.get_32()
		for node_index in range(node_count):
			var parent_index := int(parents[node_index])
			if parent_index >= 0 and parent_index < node_count:
				vertices.append(points[parent_index])
				vertices.append(points[node_index])
		var source_segments: Array = []
		var source_edge_count := 0
		for node_index in range(node_count):
			var parent_index := int(parents[node_index])
			if parent_index < 0 or parent_index >= node_count:
				continue
			var s0 := float(source_edge_count) / maxf(float(node_count), 1.0)
			var s1 := float(source_edge_count + 1) / maxf(float(node_count), 1.0)
			source_segments.append({"a": points[parent_index], "b": points[node_index], "s0": s0, "s1": s1})
			source_edge_count += 1
		if not source_segments.is_empty():
			morphology_segments[source_id] = source_segments
		branch_neuron_ranges[source_id] = Vector2i(range_start, vertices.size())
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	branch_positions = vertices
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.80, 0.38, 0.95, 0.12)
	material.no_depth_test = false
	mesh.surface_set_material(0, material)
	branch_lod_instance = MeshInstance3D.new()
	branch_lod_instance.mesh = mesh
	branch_lod_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brain_root.add_child(branch_lod_instance)
	_build_summary_points(branch_positions, Color(0.78, 0.44, 0.92, 0.46), 8)


func _build_connectome_edges() -> void:
	var path := "res://assets/morphology/adult_connectome_edges.bin"
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 8:
		return
	if file.get_buffer(4).get_string_from_ascii() != "FWED":
		return
	var count := int(file.get_32())
	var vertices := PackedVector3Array()
	vertices.resize(count * 2)
	var cursor := 0
	for _edge in range(count):
		if file.get_position() + 28 > file.get_length():
			break
		vertices[cursor] = Vector3(file.get_float(), file.get_float(), file.get_float())
		vertices[cursor + 1] = Vector3(file.get_float(), file.get_float(), file.get_float())
		file.get_float() # weight is retained in the asset; alpha is a shared LOD material.
		cursor += 2
	if cursor < vertices.size():
		vertices.resize(cursor)
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.52, 0.28, 0.72, 0.10)
	material.no_depth_test = true
	mesh.surface_set_material(0, material)
	connectome_edges_instance = MeshInstance3D.new()
	connectome_edges_instance.mesh = mesh
	connectome_edges_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brain_root.add_child(connectome_edges_instance)
	connectome_edges_instance.visible = show_connectome_edges


func _build_summary_points(points: PackedVector3Array, color: Color, stride: int) -> void:
	if points.is_empty() or brain_root == null:
		return
	if summary_instance != null and is_instance_valid(summary_instance):
		summary_instance.queue_free()
	var sampled := PackedVector3Array()
	var step := maxi(1, stride)
	for index in range(0, points.size(), step):
		sampled.append(points[index])
	if sampled.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = sampled
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.point_size = 2.2
	mesh.surface_set_material(0, material)
	summary_instance = MeshInstance3D.new()
	summary_instance.mesh = mesh
	summary_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brain_root.add_child(summary_instance)


func _update_spike_overlay(raw_ids: Variant) -> void:
	if brain_root == null or not raw_ids is Array:
		return
	var ids: Array = raw_ids
	var signature_parts := PackedStringArray()
	for value in ids:
		signature_parts.append(str(value))
	var signature := ",".join(signature_parts)
	if signature == last_spike_signature:
		return
	last_spike_signature = signature
	if active_spike_instance != null and is_instance_valid(active_spike_instance):
		active_spike_instance.queue_free()
	active_spike_instance = null
	if ids.is_empty() or (current_stage == "adult" and full_brain_positions.is_empty()) or (current_stage == "larva" and branch_positions.is_empty()):
		return
	var vertices := PackedVector3Array()
	if current_stage == "adult":
		for id in ids:
			if point_index.has(int(id)):
				vertices.append(full_brain_positions[int(point_index[int(id)])])
	else:
		for id in ids:
			var range_value: Vector2i = branch_neuron_ranges.get(str(id), Vector2i(-1, -1))
			if range_value.x < 0:
				continue
			for vertex_index in range(range_value.x, min(range_value.y, branch_positions.size())):
				vertices.append(branch_positions[vertex_index])
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.82, 0.25, 1.0)
	material.point_size = 5.0
	mesh.surface_set_material(0, material)
	active_spike_instance = MeshInstance3D.new()
	active_spike_instance.mesh = mesh
	active_spike_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brain_root.add_child(active_spike_instance)


func _build_catalog() -> void:
	if brain_root == null:
		return
	for child in brain_root.get_children():
		child.queue_free()
	full_brain_instance = null
	active_spike_instance = null
	connectome_edges_instance = null
	summary_instance = null
	full_brain_positions.clear()
	point_index.clear()
	branch_positions.clear()
	branch_neuron_ranges.clear()
	last_spike_signature = ""
	last_activity = {}
	pulse_left.clear()
	last_activity_seq = -1
	active_neuron_materials.clear()
	morphology_segments.clear()
	propagation_events.clear()
	propagation_instance = null
	propagation_material = null
	var neurons = catalog.get("neurons", [])
	for neuron in neurons:
		if not neuron is Dictionary:
			continue
		var mesh := _build_neuron_mesh(neuron)
		if mesh == null:
			continue
		var material := _make_neuron_material(str(neuron.get("label", "")))
		mesh.surface_set_material(0, material)
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_instance.set_meta("neuron_id", str(neuron.get("neuron_id", "")))
		mesh_instance.set_meta("dataset", str(catalog.get("dataset", "")))
		brain_root.add_child(mesh_instance)
		var neuron_id := str(neuron.get("neuron_id", ""))
		active_neuron_materials[neuron_id] = material
		morphology_segments[neuron_id] = _build_morphology_segments(neuron)
	_setup_propagation_layer()
	set_activity({}, last_activity)


func _build_morphology_segments(neuron: Dictionary) -> Array:
	var raw_nodes = neuron.get("nodes", [])
	if not raw_nodes is Array or raw_nodes.size() < 2:
		return []
	var nodes: Dictionary = {}
	for raw_node in raw_nodes:
		if not raw_node is Dictionary:
			continue
		var node_id := str(raw_node.get("id", ""))
		var point = raw_node.get("p", [])
		if node_id.is_empty() or not point is Array or point.size() < 3:
			continue
		nodes[node_id] = {
			"point": Vector3(float(point[0]), float(point[1]), float(point[2])),
			"parent": str(raw_node.get("parent", "-1")),
		}
	if nodes.size() < 2:
		return []
	var distances: Dictionary = {}
	for node_id in nodes:
		var parent_id := str(nodes[node_id].get("parent", "-1"))
		if parent_id == "-1" or not nodes.has(parent_id):
			distances[node_id] = 0.0
	# SWC files are parent-before-child trees, but resolving by passes keeps the
	# loader correct if a source file stores a branch out of order.
	for _pass in range(nodes.size()):
		var resolved := true
		for node_id in nodes:
			if distances.has(node_id):
				continue
			var parent_id := str(nodes[node_id].get("parent", "-1"))
			if not distances.has(parent_id):
				resolved = false
				continue
			var parent_point: Vector3 = nodes[parent_id]["point"]
			var point: Vector3 = nodes[node_id]["point"]
			distances[node_id] = float(distances[parent_id]) + parent_point.distance_to(point)
		if resolved:
			break
	var max_distance := 0.0
	for distance in distances.values():
		max_distance = maxf(max_distance, float(distance))
	max_distance = maxf(max_distance, 0.001)
	var segments: Array = []
	for node_id in nodes:
		var parent_id := str(nodes[node_id].get("parent", "-1"))
		if parent_id == "-1" or not nodes.has(parent_id):
			continue
		var start: Vector3 = nodes[parent_id]["point"]
		var finish: Vector3 = nodes[node_id]["point"]
		var start_distance := float(distances.get(parent_id, 0.0)) / max_distance
		var finish_distance := float(distances.get(node_id, start_distance * max_distance)) / max_distance
		segments.append({"a": start, "b": finish, "s0": start_distance, "s1": maxf(start_distance + 0.0001, finish_distance)})
	return segments


func _setup_propagation_layer() -> void:
	if brain_root == null:
		return
	propagation_material = StandardMaterial3D.new()
	propagation_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	propagation_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	propagation_material.albedo_color = Color(1.0, 0.88, 0.32, 1.0)
	propagation_material.emission_enabled = true
	propagation_material.emission = Color(1.0, 0.58, 0.16)
	propagation_material.emission_energy_multiplier = 2.8
	propagation_material.point_size = 7.0
	propagation_instance = MeshInstance3D.new()
	propagation_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	propagation_instance.visible = false
	brain_root.add_child(propagation_instance)


func _queue_propagation_events(activity: Dictionary) -> void:
	var queued := {}
	for raw_id in activity.get("spike_ids", []):
		var neuron_id := str(raw_id)
		if not morphology_segments.has(neuron_id) or queued.has(neuron_id):
			continue
		propagation_events.append({"neuron_id": neuron_id, "elapsed": 0.0, "duration": SIGNAL_TRAVEL_SECONDS})
		queued[neuron_id] = true
	for spike in activity.get("spike_events", []):
		if not spike is Dictionary:
			continue
		var neuron_id := str(spike.get("neuron_id", ""))
		if neuron_id.is_empty() or not morphology_segments.has(neuron_id) or queued.has(neuron_id):
			continue
		propagation_events.append({"neuron_id": neuron_id, "elapsed": 0.0, "duration": SIGNAL_TRAVEL_SECONDS})
		queued[neuron_id] = true
	while propagation_events.size() > SIGNAL_EVENT_LIMIT:
		propagation_events.pop_front()


func _update_propagation_overlay() -> void:
	if propagation_instance == null or not is_instance_valid(propagation_instance):
		return
	if propagation_events.is_empty():
		propagation_instance.visible = false
		return
	var vertices := PackedVector3Array()
	for event in propagation_events:
		var neuron_id := str(event.get("neuron_id", ""))
		var segments: Array = morphology_segments.get(neuron_id, [])
		if segments.is_empty():
			continue
		var progress := clampf(float(event.get("elapsed", 0.0)) / maxf(float(event.get("duration", SIGNAL_TRAVEL_SECONDS)), 0.001), 0.0, 1.0)
		for segment in segments:
			var start_progress := float(segment.get("s0", 0.0))
			var end_progress := float(segment.get("s1", 1.0))
			if progress < start_progress - SIGNAL_TRAIL or progress > end_progress + SIGNAL_TRAIL:
				continue
			var point_a: Vector3 = segment["a"]
			var point_b: Vector3 = segment["b"]
			if progress >= start_progress and progress <= end_progress:
				var local := inverse_lerp(start_progress, end_progress, progress)
				vertices.append(point_a.lerp(point_b, local))
			elif progress > end_progress:
				vertices.append(point_b)
			else:
				vertices.append(point_a)
	if vertices.is_empty():
		propagation_instance.visible = false
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh.surface_set_material(0, propagation_material)
	propagation_instance.mesh = mesh
	propagation_instance.visible = true


func _make_neuron_material(label: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var color := Color(0.26, 0.8, 0.96) if current_stage == "adult" else Color(0.8, 0.48, 0.95)
	if "Taste" in label:
		color = Color(1.0, 0.68, 0.28)
	elif "DNa02" in label or "DNp01" in label:
		color = Color(0.98, 0.37, 0.47)
	elif "MDN" in label:
		color = Color(0.7, 0.45, 1.0)
	material.albedo_color = color.darkened(0.35)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.45
	material.roughness = 0.4
	material.metallic = 0.05
	return material


func _build_neuron_mesh(neuron: Dictionary) -> ArrayMesh:
	var raw_nodes = neuron.get("nodes", [])
	if not raw_nodes is Array or raw_nodes.size() < 2:
		return null
	var nodes: Dictionary = {}
	for raw_node in raw_nodes:
		if not raw_node is Dictionary:
			continue
		var node_id := str(raw_node.get("id", ""))
		var point = raw_node.get("p", [])
		if node_id == "" or not point is Array or point.size() < 3:
			continue
		nodes[node_id] = {
			"point": Vector3(float(point[0]), float(point[1]), float(point[2])),
			"radius": max(0.008, float(raw_node.get("r", 0.008))),
			"parent": str(raw_node.get("parent", "-1")),
		}
	if nodes.size() < 2:
		return null
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segment_count := 0
	for node_id in nodes:
		var node: Dictionary = nodes[node_id]
		var parent_id: String = node["parent"]
		if parent_id == "-1" or not nodes.has(parent_id):
			continue
		var parent: Dictionary = nodes[parent_id]
		_add_tube_segment(surface, parent["point"], node["point"], parent["radius"], node["radius"])
		segment_count += 1
	if segment_count == 0:
		return null
	return surface.commit()


func _add_tube_segment(surface: SurfaceTool, start: Vector3, finish: Vector3, start_radius: float, finish_radius: float) -> void:
	var direction := finish - start
	if direction.length_squared() < 0.000001:
		return
	direction = direction.normalized()
	var helper := Vector3.UP if abs(direction.dot(Vector3.UP)) < 0.88 else Vector3.RIGHT
	var side := direction.cross(helper).normalized()
	var other_side := direction.cross(side).normalized()
	var start_ring: Array = []
	var finish_ring: Array = []
	for i in range(TUBE_SIDES):
		var angle := TAU * float(i) / float(TUBE_SIDES)
		var radial := side * cos(angle) + other_side * sin(angle)
		start_ring.append(start + radial * start_radius)
		finish_ring.append(finish + radial * finish_radius)
	for i in range(TUBE_SIDES):
		var next := (i + 1) % TUBE_SIDES
		_add_triangle(surface, start_ring[i], finish_ring[i], finish_ring[next], (start_ring[i] - start).normalized())
		_add_triangle(surface, start_ring[i], finish_ring[next], start_ring[next], (start_ring[i] - start).normalized())


func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	surface.set_normal(normal)
	surface.add_vertex(a)
	surface.set_normal(normal)
	surface.add_vertex(b)
	surface.set_normal(normal)
	surface.add_vertex(c)


func _apply_camera_transform() -> void:
	if camera == null or brain_root == null:
		return
	camera.position = Vector3(0.0, 0.0, zoom)
	brain_root.rotation = Vector3(pitch, yaw, 0.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
			last_mouse = event.position
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom = clamp(zoom - 0.35, 2.5, 9.0)
			_apply_camera_transform()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom = clamp(zoom + 0.35, 2.5, 9.0)
			_apply_camera_transform()
			accept_event()
	elif event is InputEventMouseMotion and dragging:
		var movement: Vector2 = event.position - last_mouse
		last_mouse = event.position
		yaw += movement.x * 0.012
		pitch = clamp(pitch + movement.y * 0.012, -1.35, 1.35)
		_apply_camera_transform()
		accept_event()
