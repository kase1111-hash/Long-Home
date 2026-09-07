extends SceneTree
## Headless gameplay smoke test: actually walks the climber down the mountain.
##
## Follows TerrainService.corridor (the guaranteed summit-to-base-camp line)
## by steering the camera toward the next corridor point and holding
## move_forward, exactly as a player would. Passes when the run ends with a
## return outcome at base camp; fails on a fatal event, incapacitation, a
## stall, or running out of time. Prints progress every few simulated seconds.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_walk.gd [-- --mountain=<id>]
##
## Runs the simulation at 4x (240 physics ticks/s, time_scale 4) so a full
## descent takes about a minute of wall-clock time.
##
## Implementation note: a "-s" script is compiled before the autoloads exist,
## so autoloads and project classes are reached dynamically (see smoke_goal.gd).

const SPEED_UP := 4.0
const MAX_SIM_SECONDS := 600.0
const STALL_SECONDS := 20.0
const WAYPOINT_RADIUS := 6.0
const REPORT_EVERY := 15.0

var mountain: String = "knife_edge"
var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _failures: Array[String] = []
var _fatal_started: bool = false
var _states_seen: Dictionary = {}


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := str(arg)
		if text.begins_with("--mountain="):
			mountain = text.trim_prefix("--mountain=")
	call_deferred("_run")


func _run() -> void:
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_event_bus = root.get_node_or_null("/root/EventBus")
	if _state_manager == null or _enums == null or _locator == null or _event_bus == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_event_bus.fatal_event_started.connect(func(_phase: int) -> void: _fatal_started = true)
	_event_bus.player_movement_changed.connect(func(_old: int, new_state: int) -> void:
		var names: Array = _enums.PlayerMovementState.keys()
		_states_seen[names[new_state]] = true
	)

	var packed: PackedScene = load("res://src/scenes/main.tscn") as PackedScene
	var main_scene: Node = packed.instantiate()
	root.add_child(main_scene)
	await _wait(3)

	var states: Dictionary = _enums.GameState
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	if is_instance_valid(mountain_db):
		mountain_db.select_mountain(mountain)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(1)
	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var conditions: Resource = conditions_script.create_moderate()
	conditions.mountain_id = mountain
	var run: Object = _state_manager.start_run(mountain, conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	await _wait(30)
	if _state() != int(states["DESCENT"]) or run == null:
		_finish("could not start a descent on '%s'" % mountain)
		return

	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	if player == null or not is_instance_valid(terrain):
		_finish("no player or terrain")
		return
	var pivot: Node = player.get_node_or_null("CameraPivot")
	var corridor: PackedVector3Array = terrain.corridor
	var goal: Vector3 = terrain.goal_position
	if corridor.is_empty():
		corridor = PackedVector3Array([player.global_position, goal])
	print("[smoke_walk] %s: corridor %d points, start %s, goal %s" % [mountain, corridor.size(), player.global_position, goal])

	# Speed the simulation up without changing the physics step length
	Engine.physics_ticks_per_second = int(60 * SPEED_UP)
	Engine.time_scale = SPEED_UP

	var start_elev: float = player.global_position.y
	var next_index := _nearest_corridor_index(corridor, player.global_position)
	var sim_time := 0.0
	var last_report := 0.0
	var last_progress_time := 0.0
	var best_distance := _xz_distance(player.global_position, goal)
	var max_slope := 0.0
	var tick := 1.0 / Engine.physics_ticks_per_second * SPEED_UP

	Input.action_press("move_forward")
	while sim_time < MAX_SIM_SECONDS:
		await physics_frame
		sim_time += tick

		if _state() != int(states["DESCENT"]):
			break
		if _fatal_started:
			_failures.append("fatal event started at %s after %.0f s" % [player.global_position, sim_time])
			break

		# Steer: aim the camera (movement is camera-relative) at the next corridor point
		var pos: Vector3 = player.global_position
		while next_index < corridor.size() - 1 and _xz_distance(pos, corridor[next_index]) < WAYPOINT_RADIUS:
			next_index += 1
		var target: Vector3 = corridor[next_index] if next_index < corridor.size() else goal
		if next_index >= corridor.size() - 1:
			target = goal
		var to_target := target - pos
		to_target.y = 0.0
		if pivot != null and to_target.length_squared() > 0.01:
			var dir := to_target.normalized()
			pivot.yaw = atan2(-dir.x, -dir.z)

		var slope: float = terrain.get_slope_at(pos)
		max_slope = maxf(max_slope, slope)

		var distance := _xz_distance(pos, goal)
		if distance < best_distance - 1.0:
			best_distance = distance
			last_progress_time = sim_time
		elif sim_time - last_progress_time > STALL_SECONDS:
			var state_names: Array = _enums.PlayerMovementState.keys()
			_failures.append("stalled for %.0f s at %s (slope %.1f deg, state %s, next corridor point %d/%d at %s)" % [
				STALL_SECONDS, pos, slope, state_names[player.current_state], next_index, corridor.size(), target])
			break

		if sim_time - last_report >= REPORT_EVERY:
			last_report = sim_time
			var state_names: Array = _enums.PlayerMovementState.keys()
			print("[smoke_walk] t=%3.0fs elev %.0f m (-%.0f) | %.0f m to camp | slope %.0f deg | %s | speed %.1f m/s" % [
				sim_time, pos.y, start_elev - pos.y, distance, slope, state_names[player.current_state], player.velocity.length()])
	Input.action_release("move_forward")
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60

	var outcomes: Dictionary = _enums.ResolutionType
	var outcome_names: Array = outcomes.keys()
	print("[smoke_walk] finished after %.0f s: state %d, outcome %s, elevation drop %.0f m, states seen %s, max slope %.1f deg" % [
		sim_time, _state(), outcome_names[run.outcome] if run.is_complete else "(run still active)",
		start_elev - player.global_position.y, str(_states_seen.keys()), max_slope])

	if _failures.is_empty():
		if _state() != int(states["RESOLUTION"]):
			_failures.append("did not reach base camp within %.0f s (%.0f m left)" % [MAX_SIM_SECONDS, _xz_distance(player.global_position, goal)])
		elif run.outcome != int(outcomes["CLEAN_RETURN"]) and run.outcome != int(outcomes["INJURED_RETURN"]):
			_failures.append("run ended with %s instead of a return" % outcome_names[run.outcome])
	_finish("")


func _nearest_corridor_index(corridor: PackedVector3Array, pos: Vector3) -> int:
	var best := 0
	var best_d := INF
	for i in range(corridor.size()):
		var d := _xz_distance(pos, corridor[i])
		if d < best_d:
			best_d = d
			best = i
	return mini(best + 1, corridor.size() - 1)


func _xz_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _state() -> int:
	var state: int = _state_manager.current_state
	return state


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[smoke_walk] PASS")
		quit(0)
	else:
		print("[smoke_walk] FAIL: %s" % "; ".join(_failures))
		quit(1)
