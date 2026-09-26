class_name NeuralAdapter
extends RefCounted

## Stable interface for the fly brain.
##
## The local proxy keeps the game playable without Python. When the local
## WebSocket service is available, the same state shape carries MaleCNS or
## Winding L1EM observations and rejects stale selection results.

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8765
const PROTOCOL_VERSION := 2
const INTERACTION_MODEL_DT := 0.001

var bridge: WebSocketPeer
var bridge_host := DEFAULT_HOST
var bridge_port := DEFAULT_PORT
var bridge_state := "local"
var hello_sent := false
var reconnect_requested := false
var last_bridge_error := ""
var pending_brain: Dictionary = {}
var pending_activity: Dictionary = {}
var bridge_in_flight: Dictionary = {}
var pending_seq: Dictionary = {}
var latest_seq: Dictionary = {}
var tick_id := 0
var request_seq := 0
var world_uuid := ""
var epoch := 0
var selection_session := 0
var selected_fly_id := ""
var selected_life_stage := ""


func create_state() -> Dictionary:
	return {
		"sugar": 0.04,
		"bitter": 0.02,
		"approach": 0.05,
		"threat": 0.05,
		"motor": 0.02,
	}


func step(previous: Dictionary, inputs: Dictionary, dt: float) -> Dictionary:
	if bridge_state == "python_proxy" or bridge_state == "malecns":
		var fly_id: String = str(inputs.get("fly_id", ""))
		if fly_id != "":
			if not bridge_in_flight.has(fly_id):
				request_seq += 1
				var life_stage := str(inputs.get("life_stage", "adult"))
				var sim_time_s := float(inputs.get("sim_time_s", 0.0))
				var is_larva := life_stage == "larva"
				_send_json({
					"type": "sensory",
					"protocol_version": PROTOCOL_VERSION,
					"world_uuid": world_uuid,
					"epoch": epoch,
					"selection_session": selection_session,
					"fly_id": fly_id,
					"life_stage": life_stage,
					"dataset_id": "Winding2023-L1EM" if is_larva and bridge_state == "malecns" else ("MaleCNS-v1.0" if bridge_state == "malecns" else "local-proxy"),
					"model_version": "L1EM connectome LIF-lite v1" if is_larva and bridge_state == "malecns" else ("MaleCNS v1.0" if bridge_state == "malecns" else "python_proxy_v1"),
					"seq": request_seq,
					"tick": tick_id,
					"dt": dt,
					"sim_time_s": sim_time_s,
					"window_start_s": max(0.0, sim_time_s - dt),
					"window_end_s": sim_time_s,
					"input_world_time_s": sim_time_s,
					"requested_model_dt_s": INTERACTION_MODEL_DT,
					"model_window_s": 0.02,
					"inputs": inputs,
					"normalized_inputs": {
						"sugar": clamp(float(inputs.get("sugar", 0.0)), 0.0, 1.0),
						"food_odor": clamp(float(inputs.get("food_odor", inputs.get("sugar", 0.0))), 0.0, 1.0),
						"food_contact_taste": clamp(float(inputs.get("food_contact_taste", 0.0)), 0.0, 1.0),
						"bitter": clamp(float(inputs.get("bitter", 0.0)), 0.0, 1.0),
						"hunger": clamp(float(inputs.get("hunger", 0.0)), 0.0, 1.0),
						"proximity": clamp(float(inputs.get("proximity", 0.0)), 0.0, 1.0),
						"stress": clamp(float(inputs.get("stress", 0.0)), 0.0, 1.0),
						"rival_fear": clamp(float(inputs.get("rival_fear", 0.0)), 0.0, 1.0),
						"temperature": clamp((float(inputs.get("temperature", 25.0)) - 18.0) / 14.0, 0.0, 1.0),
						"humidity": clamp((float(inputs.get("humidity", 60.0)) - 30.0) / 50.0, 0.0, 1.0),
						"light": clamp(float(inputs.get("light", 65.0)) / 100.0, 0.0, 1.0),
						"threat_left": clamp(float(inputs.get("threat_left", 0.0)), 0.0, 1.0),
						"threat_right": clamp(float(inputs.get("threat_right", 0.0)), 0.0, 1.0),
						"threat_approach": clamp(float(inputs.get("threat_approach", 0.0)), 0.0, 1.0),
					},
				})
				bridge_in_flight[fly_id] = request_seq
			if pending_brain.has(fly_id):
				var remote_brain: Dictionary = pending_brain[fly_id]
				pending_brain.erase(fly_id)
				pending_seq.erase(fly_id)
				return remote_brain
	var next: Dictionary = previous.duplicate()
	var sugar_input: float = float(inputs.get("sugar", 0.0))
	var bitter_input: float = float(inputs.get("bitter", 0.0))
	var hunger: float = float(inputs.get("hunger", 0.0))
	var proximity: float = float(inputs.get("proximity", 0.0))
	var stress: float = float(inputs.get("stress", 0.0))
	var rival_fear: float = float(inputs.get("rival_fear", 0.0))
	var response_rate: float = clamp(dt * 12.0, 0.05, 0.45)
	var approach_target: float = clamp(sugar_input * 0.72 + hunger * 0.5 - bitter_input * 0.88, -1.0, 1.0)
	var threat_target: float = clamp(proximity * 0.58 + stress * 0.48 + rival_fear * 0.45, 0.0, 1.0)
	var motor_target: float = clamp(abs(approach_target) * 0.55 + threat_target * 0.45, 0.0, 1.0)
	next["sugar"] = lerp(float(previous.get("sugar", 0.0)), sugar_input, response_rate)
	next["bitter"] = lerp(float(previous.get("bitter", 0.0)), bitter_input, response_rate)
	next["approach"] = lerp(float(previous.get("approach", 0.0)), approach_target, response_rate * 0.82)
	next["threat"] = lerp(float(previous.get("threat", 0.0)), threat_target, response_rate * 0.9)
	next["motor"] = lerp(float(previous.get("motor", 0.0)), motor_target, response_rate)
	return next


func begin_tick() -> void:
	tick_id += 1


func take_activity(fly_id: String) -> Dictionary:
	# Only the real MaleCNS session is allowed to publish a neural frame. A
	# Python proxy response is still useful for protocol diagnostics, but it is
	# not an attached brain signal and must never reach the visual layer.
	if bridge_state != "malecns":
		pending_activity.erase(fly_id)
		return {}
	if not pending_activity.has(fly_id):
		return {}
	var activity: Dictionary = pending_activity[fly_id]
	pending_activity.erase(fly_id)
	return activity


func begin_world(next_world_uuid: String) -> void:
	_send_cancel()
	world_uuid = next_world_uuid
	epoch += 1
	selection_session += 1
	selected_fly_id = ""
	selected_life_stage = ""
	pending_brain.clear()
	pending_activity.clear()
	pending_seq.clear()
	latest_seq.clear()
	bridge_in_flight.clear()
	if bridge_state == "malecns" or bridge_state == "python_proxy":
		_send_json({"type": "reset", "protocol_version": PROTOCOL_VERSION, "world_uuid": world_uuid, "epoch": epoch})


func set_selection(fly_id: String, life_stage: String) -> void:
	if selected_fly_id == fly_id and selected_life_stage == life_stage:
		return
	_send_cancel()
	selection_session += 1
	selected_fly_id = fly_id
	selected_life_stage = life_stage
	pending_brain.clear()
	pending_activity.clear()
	pending_seq.clear()
	bridge_in_flight.clear()


func clear_selection() -> void:
	set_selection("", "")


func _send_cancel() -> void:
	if selected_fly_id.is_empty() or (bridge_state != "malecns" and bridge_state != "python_proxy"):
		return
	_send_json({
		"type": "cancel",
		"protocol_version": PROTOCOL_VERSION,
		"world_uuid": world_uuid,
		"epoch": epoch,
		"selection_session": selection_session,
		"fly_id": selected_fly_id,
		"life_stage": selected_life_stage,
	})


func connect_bridge(host: String = DEFAULT_HOST, port: int = DEFAULT_PORT) -> void:
	disconnect_bridge()
	bridge_host = host
	bridge_port = port
	bridge = WebSocketPeer.new()
	# MaleCNS sparse spike windows can exceed Godot's default 64KiB inbound
	# packet limit. Keep a bounded queue while accepting one full source-ID
	# activity frame.
	bridge.inbound_buffer_size = 512 * 1024
	bridge.max_queued_packets = 32
	bridge_state = "connecting"
	hello_sent = false
	reconnect_requested = false
	last_bridge_error = ""
	var error := bridge.connect_to_url("ws://%s:%d" % [bridge_host, bridge_port])
	if error != OK:
		bridge_state = "local"
		reconnect_requested = true
		last_bridge_error = "connect_error_%s" % error


func poll_bridge() -> void:
	if bridge == null:
		return
	bridge.poll()
	var connection_status := bridge.get_ready_state()
	if connection_status == WebSocketPeer.STATE_OPEN:
		if not hello_sent:
			_send_json({"type": "hello", "protocol": PROTOCOL_VERSION})
			hello_sent = true
		_read_bridge_messages()
	elif connection_status == WebSocketPeer.STATE_CLOSED:
		_mark_bridge_disconnected("socket_closed")
	elif connection_status == WebSocketPeer.STATE_CLOSING:
		_mark_bridge_disconnected("socket_closing")


func _read_bridge_messages() -> void:
	while bridge != null and bridge.get_available_packet_count() > 0:
		var packet := bridge.get_packet()
		var line := packet.get_string_from_utf8().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if not parsed is Dictionary:
			continue
		if parsed.get("type", "") == "hello" and int(parsed.get("protocol_version", parsed.get("protocol", 0))) == PROTOCOL_VERSION:
			bridge_state = "malecns" if parsed.get("mode", "") == "malecns" else "python_proxy"
			reconnect_requested = false
			last_bridge_error = ""
		elif parsed.get("type", "") == "hello":
			_mark_bridge_disconnected("protocol_version_mismatch")
		elif parsed.get("type", "") == "error":
			last_bridge_error = str(parsed.get("code", "bridge_error"))
			_mark_bridge_disconnected(last_bridge_error)
		elif parsed.get("type", "") == "step_ack":
			var fly_id: String = str(parsed.get("fly_id", ""))
			var brain = parsed.get("brain", {})
			var response_seq := int(parsed.get("seq", 0))
			var response_stage := str(parsed.get("life_stage", ""))
			var response_world := str(parsed.get("world_uuid", ""))
			var response_epoch := int(parsed.get("epoch", -1))
			var response_session := int(parsed.get("selection_session", -1))
			var valid_context := fly_id != "" and fly_id == selected_fly_id and response_stage == selected_life_stage and response_world == world_uuid and response_epoch == epoch and response_session == selection_session and response_seq > int(latest_seq.get(fly_id, 0))
			var in_flight_seq := int(bridge_in_flight.get(fly_id, -1))
			# A stale A response must not release a new A request after A -> B -> A.
			if response_seq == in_flight_seq:
				bridge_in_flight.erase(fly_id)
			if valid_context and response_seq == in_flight_seq and brain is Dictionary:
				latest_seq[fly_id] = response_seq
				pending_seq[fly_id] = response_seq
				pending_brain[fly_id] = brain
			var activity = parsed.get("activity", {})
			if valid_context and response_seq == in_flight_seq and activity is Dictionary:
				pending_activity[fly_id] = activity


func _send_json(payload: Dictionary) -> void:
	if bridge == null or bridge.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	bridge.send_text(JSON.stringify(payload))


func disconnect_bridge() -> void:
	if bridge != null:
		bridge.close()
	bridge = null
	bridge_state = "local"
	hello_sent = false
	pending_brain.clear()
	pending_activity.clear()
	pending_seq.clear()
	bridge_in_flight.clear()
	reconnect_requested = false
	last_bridge_error = ""


func _mark_bridge_disconnected(reason: String) -> void:
	if bridge != null:
		bridge.close()
	bridge = null
	bridge_state = "local"
	hello_sent = false
	pending_brain.clear()
	pending_activity.clear()
	pending_seq.clear()
	bridge_in_flight.clear()
	reconnect_requested = true
	last_bridge_error = reason


func is_bridge_active() -> bool:
	return bridge_state == "connecting" or bridge_state == "python_proxy" or bridge_state == "malecns"
