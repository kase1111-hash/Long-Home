extends SceneTree
## Headless smoke test for the foot mechanics, played through the real game:
##   1. downclimbing a steep snow face: the climber turns to the slope, clings
##      to it and moves down it slowly, one placement at a time
##   2. crampons: F takes them off (a timed job, slower on a steep face), the
##      footing loses grip, F puts them back on
##   3. landings: a 1 m hop is nothing, a 3 m drop is a hard landing, a 6 m
##      drop breaks something
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_mechanics.gd
##
## Runs at 4x (240 physics ticks/s, time_scale 4). The RNG is seeded so slips
## are repeatable. A "-s" script is compiled before the autoloads exist, so
## autoloads and project classes are reached dynamically (see smoke_goal.gd).

const MOUNTAIN := "knife_edge"
const SPEED_UP := 4.0
const SEARCH_RADIUS := 260.0
const DOWNCLIMB_SECONDS := 20.0

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _failures: Array[String] = []
var _states_seen: Dictionary = {}
var _incidents: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	seed(20261003)
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_event_bus = root.get_node_or_null("/root/EventBus")
	if _state_manager == null or _enums == null or _locator == null or _event_bus == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_event_bus.player_movement_changed.connect(func(_old: int, new_state: int) -> void:
		var names: Array = _enums.PlayerMovementState.keys()
		_states_seen[names[new_state]] = true
	)
	_event_bus.incident_recorded.connect(func(kind: String, _context: Dictionary) -> void:
		_incidents.append(kind)
	)

	if not await _boot_descent():
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	if player == null or not is_instance_valid(terrain):
		_finish("no player or terrain")
		return

	Engine.physics_ticks_per_second = int(60 * SPEED_UP)
	Engine.time_scale = SPEED_UP

	await _check_downclimb(player, terrain)
	await _check_crampons(player)
	await _check_landings(player, terrain)

	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("[smoke_mechanics] movement states seen: %s" % str(_states_seen.keys()))
	_finish("")


# =============================================================================
# DOWNCLIMBING
# =============================================================================

func _check_downclimb(player: Node3D, terrain: Object) -> void:
	var snow := [
		int(_enums.SurfaceType["SNOW_FIRM"]), int(_enums.SurfaceType["SNOW_SOFT"]),
		int(_enums.SurfaceType["SNOW_PACKED"]),
	]
	var cells: Array = terrain.find_cells(player.global_position, SEARCH_RADIUS,
		func(cell: Object) -> bool:
			return cell.slope_angle >= 38.0 and cell.slope_angle <= 44.0 \
				and int(cell.surface_type) in snow and cell.distance_to_cliff > 15.0)
	# Prefer a spot with steep snow continuing below it
	var best: Object = null
	for cell in cells:
		var below: Vector3 = cell.position + cell.slope_direction * 6.0
		if terrain.get_slope_at(below) >= 36.0:
			best = cell
			break
	_expect(best != null, "found a 38-44 deg snow face to downclimb (%d candidates)" % cells.size())
	if best == null:
		return

	var spot: Vector3 = best.position
	spot.y = terrain.get_height_at(spot) + 0.4
	player.global_position = spot
	player.velocity = Vector3.ZERO
	print("[smoke_mechanics] downclimb spot %s: slope %.1f deg, %s" % [
		spot, best.slope_angle, _enums.SurfaceType.keys()[best.surface_type]])
	await _physics_seconds(1.0)
	var downclimbing: int = _enums.PlayerMovementState["DOWNCLIMBING"]
	_expect(player.current_state == downclimbing,
		"standing on %.0f deg snow turns into downclimbing (state %s)" % [best.slope_angle, _state_name(player.current_state)])
	var footwear_names: Array = _enums.Footwear.keys()
	print("[smoke_mechanics] footwear %s, grip margin %.2f" % [footwear_names[player.footwear], player.grip_margin])

	# Hold forward with the camera looking down the fall line
	var pivot: Node = player.get_node_or_null("CameraPivot")
	var start_y: float = player.global_position.y
	var path := 0.0
	var last: Vector3 = player.global_position
	var elapsed := 0.0
	var min_contact := INF
	var max_contact := -INF
	Input.action_press("move_forward")
	while elapsed < DOWNCLIMB_SECONDS:
		await physics_frame
		elapsed += 1.0 / 60.0
		var cell: Object = terrain.get_cell_at(player.global_position)
		if cell != null and pivot != null and cell.slope_direction.length_squared() > 0.01:
			var down: Vector3 = cell.slope_direction
			pivot.yaw = atan2(-down.x, -down.z)
		path += player.global_position.distance_to(last)
		last = player.global_position
		if player.current_state == downclimbing:
			var contact: float = player.get_height_above_terrain()
			min_contact = minf(min_contact, contact)
			max_contact = maxf(max_contact, contact)
		if player.current_state != downclimbing and elapsed > 1.0:
			break
	Input.action_release("move_forward")

	var dropped: float = start_y - player.global_position.y
	var pace: float = path / maxf(elapsed, 0.01)
	print("[smoke_mechanics] downclimbed %.1f m down (%.1f m of face) in %.1f s: %.2f m/s, contact %.2f..%.2f m, state %s" % [
		dropped, path, elapsed, pace, min_contact, max_contact, _state_name(player.current_state)])
	_expect(dropped > 2.0, "downclimbing makes progress down the face (%.1f m)" % dropped)
	_expect(pace > 0.1 and pace < 0.75, "downclimbing is slow and deliberate (%.2f m/s)" % pace)
	_expect(max_contact < 0.9 and min_contact > -0.5, "the climber stays on the face, neither floating nor sinking")
	_expect(not _states_seen.has("FALLING"), "a 40 deg snow face with crampons and axe does not throw the climber off")


# =============================================================================
# CRAMPONS
# =============================================================================

func _check_crampons(player: Node3D) -> void:
	var crampons: int = _enums.Footwear["CRAMPONS"]
	var boots: int = _enums.Footwear["BOOTS"]
	if player.footwear != crampons:
		_expect(false, "climber starts the descent with crampons on")
		return
	var with_points: float = player.grip_margin

	_tap("crampons_toggle")
	await physics_frame
	_expect(player.gear_action == &"crampons", "F starts taking the crampons off")
	var duration: float = player.gear_action_duration
	await _physics_seconds(duration + 0.5)
	_expect(player.footwear == boots, "crampons come off after %.1f s" % duration)
	await _physics_seconds(0.5)
	var in_boots: float = player.grip_margin
	print("[smoke_mechanics] grip margin with crampons %.2f, in boots %.2f" % [with_points, in_boots])
	_expect(in_boots < with_points - 0.15, "boots grip a steep snow face far worse than crampons")

	_tap("crampons_toggle")
	await physics_frame
	var on_time: float = player.gear_action_duration
	_expect(on_time > duration, "strapping crampons on takes longer than taking them off (%.1f s)" % on_time)
	await _physics_seconds(on_time + 0.5)
	_expect(player.footwear == crampons, "crampons back on")


# =============================================================================
# LANDINGS
# =============================================================================

func _check_landings(player: Node3D, terrain: Object) -> void:
	var start: Vector3 = terrain.start_position
	var falling: int = _enums.PlayerMovementState["FALLING"]
	var standing: int = _enums.PlayerMovementState["STANDING"]

	await _drop(player, terrain, start, 1.0)
	_expect(not _incidents.has("hard_landing") and not _incidents.has("fall_injury"), "a 1 m hop is nothing")

	_states_seen.erase("FALLING")
	await _drop(player, terrain, start, 3.0)
	_expect(_states_seen.has("FALLING"), "a 3 m drop is a fall")
	_expect(_incidents.has("hard_landing") or _incidents.has("fall_injury"), "a 3 m drop is a hard landing")
	_expect(player.current_state == standing, "back on your feet after the 3 m drop (state %s)" % _state_name(player.current_state))

	var injuries_before: int = player.body_state.injuries.size() if player.body_state else 0
	await _drop(player, terrain, start, 6.0)
	var injuries_after: int = player.body_state.injuries.size() if player.body_state else 0
	_expect(injuries_after > injuries_before, "a 6 m drop onto the summit plateau hurts (%d -> %d injuries)" % [injuries_before, injuries_after])
	_expect(player.current_state != falling, "the fall ends on landing (state %s)" % _state_name(player.current_state))


func _drop(player: Node3D, terrain: Object, at: Vector3, height: float) -> void:
	var spot := at
	spot.y = terrain.get_height_at(spot) + height
	player.global_position = spot
	player.velocity = Vector3.ZERO
	await _physics_seconds(maxf(sqrt(2.0 * height / 9.8) + 1.5, 2.0))


# =============================================================================
# HARNESS
# =============================================================================

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
	var conditions: Resource = conditions_script.create_moderate()
	conditions.mountain_id = MOUNTAIN
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
func _physics_seconds(seconds: float) -> void:
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
		print("[smoke_mechanics] ok: %s" % what)
	else:
		print("[smoke_mechanics] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	if _failures.is_empty():
		print("[smoke_mechanics] PASS")
		quit(0)
	else:
		print("[smoke_mechanics] FAIL: %s" % "; ".join(_failures))
		quit(1)
