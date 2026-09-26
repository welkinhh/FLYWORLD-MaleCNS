extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func run() -> void:
	var game := (load("res://Main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.set_process(false)
	await process_frame
	var brain = game.brain_view
	brain.show_connectome_edges = true
	brain.set_catalog(game.adult_brain_catalog, "adult")
	check(brain.full_brain_instance != null, "adult point cloud was not loaded")
	check(brain.connectome_edges_instance != null, "real connectome edge LOD was not loaded")
	check(brain.branch_lod_instance == null, "hidden adult branch LOD should not be loaded during startup")
	var adult_snapshot := {"points": brain.full_brain_positions.size(), "edges": brain.connectome_edges_instance != null, "branches": brain.branch_lod_instance != null}
	if brain.connectome_edges_instance != null:
		var mesh := brain.connectome_edges_instance.mesh as ArrayMesh
		check(mesh != null and mesh.get_surface_count() == 1, "edge mesh surface missing")
		if mesh != null:
			check(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() >= 500000, "edge LOD is unexpectedly sparse")
	brain.diagnostic_point_cloud = true
	brain.set_catalog(game.adult_brain_catalog, "adult")
	check(is_instance_valid(brain.branch_lod_instance) and brain.branch_lod_instance.visible, "diagnostic toggle did not load visible geometry")
	brain._build_full_brain()
	check(is_instance_valid(brain.branch_lod_instance) and brain.branch_lod_instance.visible, "fresh build ignored the diagnostic toggle")
	brain.diagnostic_point_cloud = false
	brain.set_catalog(game.adult_brain_catalog, "adult")
	check(not brain.branch_lod_instance.visible, "diagnostic toggle did not hide geometry")
	brain.set_catalog(game.larva_brain_catalog, "larva")
	await process_frame
	check(brain.full_brain_instance == null, "adult point cloud survived larva switch")
	check(brain.branch_lod_instance != null, "full larval branch LOD was not loaded")
	var larva_snapshot := {"points": brain.full_brain_positions.size(), "edges": brain.connectome_edges_instance != null, "branches": brain.branch_lod_instance != null}
	print("BRAIN_EDGES_REGRESSION ", JSON.stringify({"failures": failures, "adult": adult_snapshot, "larva": larva_snapshot}))
	game.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
