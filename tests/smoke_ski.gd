extends SceneTree
## Headless smoke test for skiing (or the splitboard with --board), played
## like a player on the "Ski Descent" loadout:
##   1. on a snow slope, T steps into the skis (a timed job: crampons off,
##      bindings on); they come on across the slope and the edges hold
##   2. turn into the fall line and let them run: skiing is fast
##   3. hold S: the skis swing across and the skid scrubs the speed off
##   4. turn across the slope and come to a stop on the edges
##   5. T steps back out onto your boots
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_ski.gd [-- --board]
##
## Runs at 4x with a seeded RNG. A "-s" script is compiled before the
## autoloads exist, so autoloads and project classes are reached dynamically.

const MOUNTAIN := "knife_edge"
const SPEED_UP := 4.0
const SEARCH_RADIUS := 200.0

var board := false
var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _failures: Array[String] = []
var _states_seen: Array[String] = []
var _fatal := false
var _crashes := 0
var _label := "smoke_ski"


func _init() -> void:
	board = "--board" in OS.get_cmdline_user_args()
	if board:
		_label = "smoke_board"
	call_deferred("_run")


func _run() -> void:
	seed(31415)
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_event_bus = root.get_node_or_null("/root/EventBus")
	if _state_manager == null or _enums == null or _locator == null or _event_bus == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_event_bus.player_movement_changed.connect(func(_old: int, new_state: int) -> void:
		var names: Array = _enums.PlayerMovementState.keys()
		_states_seen.append(names[new_state])
	)
	_event_bus.fatal_event_started.connect(func(_phase: int) -> void: _fatal = true)
	_event_bus.incident_recorded.connect(func(kind: String, _context: Dictionary) -> void:
		if kind == "ski_crash":
			_crashes += 1
	)
	_event_bus.diegetic_message.connect(func(text: String, _duration: float) -> void:
		print("[%s] \"%s\"" % [_label, text])
	)

	if not await _boot_descent():
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	if player == null or not is_instance_valid(terrain):
		_finish("no player or terrain")
		return

	# A long snow slope, steep enough to run, not steep enough to frighten
	var snow := [int(_enums.SurfaceType["SNOW_FIRM"]), int(_enums.SurfaceType["SNOW_SOFT"]), int(_enums.SurfaceType["SNOW_PACKED"])]
	var cells: Array = terrain.find_cells(player.global_position, SEARCH_RADIUS,
		func(cell: Object) -> bool:
			return cell.slope_angle >= 22.0 and cell.slope_angle <= 30.0 \
				and int(cell.surface_type) in snow and cell.distance_to_cliff > 80.0)
	var best: Object = null
	for cell in cells:
		var clear := true
		for step in range(1, 9):
			var at: Vector3 = cell.position + cell.slope_direction * (step * 6.0)
			var slope: float = terrain.get_slope_at(at)
			if slope < 12.0 or slope > 38.0 or not int(terrain.get_surface_at(at)) in snow:
				clear = false
				break
		if clear:
			best = cell
			break
	_expect(best != null, "found a long 22-30 deg snow slope (%d candidates)" % cells.size())
	if best == null:
		_finish("")
		return
	var spot: Vector3 = best.position
	spot.y = terrain.get_height_at(spot) + 0.3
	player.global_position = spot
	player.velocity = Vector3.ZERO
	var downhill: Vector3 = best.slope_direction
	player.look_at(player.global_position + downhill, Vector3.UP)
	print("[%s] slope %s: %.0f deg, %s" % [_label, spot, best.slope_angle, _enums.SurfaceType.keys()[best.surface_type]])

	Engine.physics_ticks_per_second = int(60 * SPEED_UP)
	Engine.time_scale = SPEED_UP
	await _seconds(0.5)

	# 1. Step in
	var want: int = _enums.Footwear["SNOWBOARD"] if board else _enums.Footwear["SKIS"]
	await _tap("skis_toggle")
	var duration: float = player.gear_action_duration
	_expect(player.gear_action == &"skis", "T starts stepping into the bindings (%.1f s)" % duration)
	await _seconds(duration + 0.5)
	var skiing: int = _enums.PlayerMovementState["SKIING"]
	_expect(player.footwear == want and player.current_state == skiing,
		"on the %s and skiing (state %s)" % ["board" if board else "skis", _state_name(player.current_state)])
	if player.current_state != skiing:
		_finish("")
		return
	await _seconds(1.5)
	var parked: float = player.velocity.length()
	_expect(parked < 0.6, "skis come on across the slope and the edges hold (%.2f m/s)" % parked)

	# 2. Into the fall line
	var run_start: Vector3 = player.global_position
	await _turn_toward_fall_line(player, terrain, 15.0)
	await _seconds(3.5)
	var run_speed: float = player.velocity.length()
	print("[%s] after 3.5 s in the fall line: %.1f m/s, %.0f m from the start" % [_label, run_speed, player.global_position.distance_to(run_start)])
	_expect(run_speed > 7.0, "pointing them down the hill is fast (%.1f m/s)" % run_speed)

	# 3. Brake
	Input.action_press("move_back")
	await _seconds(2.5)
	Input.action_release("move_back")
	var braked: float = player.velocity.length()
	print("[%s] after 2.5 s of skidding: %.1f m/s" % [_label, braked])
	_expect(braked < run_speed * 0.6, "a skid scrubs the speed off (%.1f -> %.1f m/s)" % [run_speed, braked])

	# 4. Across the slope to a stop
	var stopped := false
	for i in range(8):
		Input.action_press("move_back")
		await _seconds(0.5)
		Input.action_release("move_back")
		if player.velocity.length() < 0.6:
			stopped = true
			break
	_expect(stopped, "turned across the slope, the skier stops on the edges (%.2f m/s)" % player.velocity.length())
	_expect(not _fatal, "no fatal event")
	print("[%s] crashes: %d" % [_label, _crashes])

	# 5. Step out
	if player.current_state == skiing:
		await _tap("skis_toggle")
		await _seconds(player.gear_action_duration + 0.5)
	var on_feet := [int(_enums.PlayerMovementState["STANDING"]), int(_enums.PlayerMovementState["DOWNCLIMBING"])]
	_expect(player.footwear == int(_enums.Footwear["BOOTS"]) and int(player.current_state) in on_feet,
		"T steps out onto your boots (state %s)" % _state_name(player.current_state))

	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("[%s] movement states: %s" % [_label, str(_states_seen)])
	_finish("")


## Steer with A/D until the skis point within tolerance of the fall line
func _turn_toward_fall_line(player: Node3D, terrain: Object, tolerance: float) -> void:
	for i in range(240):
		var cell: Object = terrain.get_cell_at(player.global_position)
		if cell == null or cell.slope_direction.length_squared() < 0.01:
			break
		var heading: Vector3 = player.ski.heading
		var angle: float = rad_to_deg(heading.signed_angle_to(cell.slope_direction, Vector3.UP))
		Input.action_release("move_left")
		Input.action_release("move_right")
		if absf(angle) < tolerance:
			break
		# A turns the skis anticlockwise seen from above
		Input.action_press("move_left" if angle > 0.0 else "move_right")
		await physics_frame
	Input.action_release("move_left")
	Input.action_release("move_right")


func _boot_descent() -> bool:
	var packed: PackedScene = load("res://src/scenes/main.tscn") as PackedScene
	var main_scene: Node = packed.instantiate()
	root.add_child(main_scene)
	await _wait(3)

	var states: Dictionary = _enums.GameState
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	if is_instance_valid(mountain_db):
		mountain_db.select_mountain(MOUNTAIN)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(1)
	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var gear_script: GDScript = load("res://src/core/data/gear_state.gd") as GDScript
	var conditions: Resource = conditions_script.create_moderate()
	conditions.mountain_id = MOUNTAIN
	var gear: Resource = gear_script.create_ski_loadout()
	if board:
		gear.remove_item(int(_enums.GearType["SKIS"]))
		gear.add_item(gear_script.GearItem.new(int(_enums.GearType["SNOWBOARD"]), 1.0, 3.5))
	conditions.gear_state = gear
	_state_manager.start_run(MOUNTAIN, conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	await _wait(30)
	if _state_manager.current_state != int(states["DESCENT"]):
		_finish("could not start a descent on '%s'" % MOUNTAIN)
		return false
	return true


func _tap(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await physics_frame
	Input.action_release(action)


## Wait this many simulated seconds of physics
func _seconds(seconds: float) -> void:
	var ticks := int(ceil(seconds * Engine.physics_ticks_per_second / Engine.time_scale))
	for i in range(ticks):
		await physics_frame


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _state_name(state: int) -> String:
	var names: Array = _enums.PlayerMovementState.keys()
	return names[state]


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("[%s] ok: %s" % [_label, what])
	else:
		print("[%s] FAILED: %s" % [_label, what])
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	if _failures.is_empty():
		print("[%s] PASS" % _label)
		quit(0)
	else:
		print("[%s] FAIL: %s" % [_label, "; ".join(_failures)])
		quit(1)
