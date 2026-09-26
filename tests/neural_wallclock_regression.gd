extends SceneTree

## Sustained integration check for the real MaleCNS WebSocket bridge.
## The script is intentionally wall-clock based: it exercises the same
## exported-game startup path and leaves the ecology running while the Python
## service processes fixed 1 ms model steps.

const WALL_SECONDS := 1800.0
const SAMPLE_SECONDS := 30.0

var game
var started_at := 0
var next_sample_at := 0
var activity_count := 0
var bridge_seen := false
var failure_reasons: Array[String] = []
var max_latency_ms := 0.0
var min_actual_dt_s := INF
var max_actual_dt_s := 0.0
var last_activity_seq := -1


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	game = (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	for argument in OS.get_cmdline_user_args():
		if str(argument).begins_with("--flyworld-neural-seconds="):
			var requested := float(str(argument).get_slice("=", 1))
			if requested > 0.0:
				# Keep short smoke runs available while the acceptance run remains
				# the default 30-minute wall-clock test.
				set_meta("wall_seconds", requested)
	started_at = Time.get_ticks_msec()
	next_sample_at = started_at + int(SAMPLE_SECONDS * 1000.0)
	var wall_seconds := float(get_meta("wall_seconds", WALL_SECONDS))
	# SceneTree scripts do not expose Node.set_process(). Awaiting process_frame
	# keeps the normal Main._process loop alive while this harness samples it.
	while true:
		await process_frame
		var now := Time.get_ticks_msec()
		var elapsed := float(now - started_at) / 1000.0
		var adapter = game.neural_adapter
		if adapter.bridge_state == "malecns":
			bridge_seen = true
		var fly_index := clampi(int(game.selected_index), 0, max(0, game.flies.size() - 1))
		if not game.flies.is_empty():
			var fly: Dictionary = game.flies[fly_index]
			var activity: Dictionary = fly.get("brain_activity", {})
			var seq := int(activity.get("request_seq", -1))
			if seq > last_activity_seq:
				last_activity_seq = seq
				activity_count += 1
				max_latency_ms = maxf(max_latency_ms, float(activity.get("compute_latency_ms", 0.0)))
				var actual_dt := float(activity.get("actual_model_dt_s", 0.0))
				if actual_dt > 0.0:
					min_actual_dt_s = minf(min_actual_dt_s, actual_dt)
					max_actual_dt_s = maxf(max_actual_dt_s, actual_dt)
		if now >= next_sample_at:
			print("NEURAL_WALLCLOCK_SAMPLE ", JSON.stringify({
				"elapsed_s": elapsed,
				"bridge_state": adapter.bridge_state,
				"activities": activity_count,
				"last_seq": last_activity_seq,
				"max_latency_ms": max_latency_ms,
				"min_actual_dt_s": min_actual_dt_s if is_finite(min_actual_dt_s) else 0.0,
				"max_actual_dt_s": max_actual_dt_s,
			}))
			next_sample_at += int(SAMPLE_SECONDS * 1000.0)
		if elapsed >= wall_seconds:
			_finish(elapsed)
			return


func _finish(elapsed: float) -> void:
	if not bridge_seen:
		failure_reasons.append("MaleCNS bridge never reached malecns state")
	if activity_count < 10:
		failure_reasons.append("fewer than ten real activity responses were observed")
	if min_actual_dt_s == INF or abs(min_actual_dt_s - 0.001) > 0.000001 or abs(max_actual_dt_s - 0.001) > 0.000001:
		failure_reasons.append("activity responses did not report the requested 1 ms model step")
	var result := {
		"elapsed_s": elapsed,
		"bridge_seen": bridge_seen,
		"activity_count": activity_count,
		"last_seq": last_activity_seq,
		"max_latency_ms": max_latency_ms,
		"min_actual_dt_s": min_actual_dt_s if is_finite(min_actual_dt_s) else 0.0,
		"max_actual_dt_s": max_actual_dt_s,
		"failures": failure_reasons,
	}
	print("NEURAL_WALLCLOCK_REGRESSION ", JSON.stringify(result))
	var file := FileAccess.open("res://build/neural_wallclock_regression.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result))
	game.queue_free()
	quit(0 if failure_reasons.is_empty() else 1)
