extends SceneTree
## Headless smoke test for glissading and self-arrest, played like a player:
## take the crampons off (F), sit down on a 30-35 deg firm snow slope (Space),
## let it run, dig the heels and spike in (hold S), then roll onto the axe
## (Space) and check the arrest holds.
##
## Passes when the free glide accelerates, braking clearly cuts that
## acceleration, and the arrest stops the climber within a few body lengths
## and stands them back up. A fatal event or a fall is reported as a failure.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_slide.gd
##
## The RNG is seeded so the run is repeatable. A "-s" script is compiled
## before the autoloads exist, so autoloads and project classes are reached
## dynamically (see smoke_goal.gd).

const MOUNTAIN := "knife_edge"
const SEARCH_RADIUS := 160.0
const GLIDE_SECONDS := 2.0
const BRAKE_SECONDS := 3.0
const ARREST_LIMIT_SECONDS := 6.0

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _failures: Array[String] = []
var _slide_started := false
var _slide_ended := false
var _slide_outcome := -1
var _fatal := false
var _states: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	seed(424242)
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_event_bus = root.get_node_or_null("/root/EventBus")
	if _state_manager == null or _enums == null or _locator == null or _event_bus == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_event_bus.slide_started.connect(func(_speed: float, _slope: float) -> void: _slide_started = true)
	_event_bus.slide_ended.connect(func(outcome: int, _speed: float) -> void:
		_slide_ended = true
		_slide_outcome = outcome
	)
	_event_bus.fatal_event_started.connect(func(_phase: int) -> void: _fatal = true)
	_event_bus.player_movement_changed.connect(func(_old: int, new_state: int) -> void:
		var names: Array = _enums.PlayerMovementState.keys()
		_states.append(names[new_state])
	)

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

	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	var slides: Object = _locator.get_service("SlideSystem")
	if player == null or not is_instance_valid(terrain) or not is_instance_valid(slides):
		_finish("no player, terrain or slide system")
		return

	# Never glissade in crampons: take them off on the summit first
	await _tap("crampons_toggle")
	await _seconds(player.gear_action_duration + 0.5)
	_expect(player.footwear == int(_enums.Footwear["BOOTS"]), "crampons off before glissading")

	# Find a firm snow slope with a long clear run below it
	var firm: int = _enums.SurfaceType["SNOW_FIRM"]
	var cells: Array = terrain.find_cells(player.global_position, SEARCH_RADIUS,
		func(cell: Object) -> bool:
			return cell.slope_angle >= 31.0 and cell.slope_angle <= 35.0 \
				and int(cell.surface_type) == firm and cell.distance_to_cliff > 80.0)
	var best: Object = null
	for cell in cells:
		var clear := true
		for step in range(1, 6):
			var below: Vector3 = cell.position + cell.slope_direction * (step * 5.0)
			if terrain.get_slope_at(below) < 26.0:
				clear = false
				break
		if clear:
			best = cell
			break
	_expect(best != null, "found a 31-35 deg firm snow slope with a clear run (%d candidates)" % cells.size())
	if best == null:
		_finish("")
		return
	var spot: Vector3 = best.position
	spot.y = terrain.get_height_at(spot) + 0.3
	print("[smoke_slide] slide spot %s: slope %.1f deg, %s, cliff %.0f m away" % [
		spot, best.slope_angle, _enums.SurfaceType.keys()[best.surface_type], best.distance_to_cliff])
	player.global_position = spot
	player.velocity = Vector3.ZERO
	await _seconds(0.5)

	# Face downhill and sit down
	var downhill: Vector3 = best.slope_direction
	if downhill.length_squared() > 0.01:
		player.look_at(player.global_position + downhill, Vector3.UP)
	await _tap("slide_initiate")
	await _seconds(0.2)
	_expect(_slide_started, "Space on the slope starts a glissade")
	if not _slide_started:
		_finish("")
		return

	# Free glide
	var v0: float = player.velocity.length()
	await _seconds(GLIDE_SECONDS)
	var v1: float = player.velocity.length()
	var free_gain := (v1 - v0) / GLIDE_SECONDS

	# Brake: heels and spike
	Input.action_press("move_back")
	await _seconds(BRAKE_SECONDS)
	var v2: float = player.velocity.length()
	Input.action_release("move_back")
	var brake_gain := (v2 - v1) / BRAKE_SECONDS
	print("[smoke_slide] free glide %.1f -> %.1f m/s (%.2f m/s^2), braking %.1f -> %.1f m/s (%.2f m/s^2)" % [
		v0, v1, free_gain, v1, v2, brake_gain])
	_expect(free_gain > 1.0, "an unbraked glissade on firm snow accelerates (%.2f m/s^2)" % free_gain)
	_expect(brake_gain < free_gain - 1.0, "heels and spike take most of the acceleration out")
	_expect(_slide_ended == false, "the glissade is still running when the brake comes off")

	# Self-arrest
	var arrest_start: Vector3 = player.global_position
	var arrest_speed: float = player.velocity.length()
	await _tap("slide_initiate")
	var waited := 0.0
	while waited < ARREST_LIMIT_SECONDS and not _slide_ended and not _fatal:
		await physics_frame
		waited += 1.0 / 60.0
	var arrest_distance: float = player.global_position.distance_to(arrest_start)
	var outcome_names: Array = _enums.SlideOutcome.keys()
	print("[smoke_slide] arrest from %.1f m/s: %s after %.1f s and %.1f m" % [
		arrest_speed, outcome_names[_slide_outcome] if _slide_ended else "still sliding", waited, arrest_distance])
	_expect(not _fatal, "no fatal event")
	_expect(_slide_ended and "ARRESTED" in _states, "the axe arrest holds")
	_expect(arrest_distance < 20.0, "the arrest stops the slide within %.0f m" % arrest_distance)

	await _seconds(2.0)
	var on_feet := [int(_enums.PlayerMovementState["STANDING"]), int(_enums.PlayerMovementState["DOWNCLIMBING"])]
	_expect(int(player.current_state) in on_feet, "back on your feet after the arrest (state %s)" % _states.back())
	_expect(_state_manager.current_state == int(states["DESCENT"]), "the run carries on")
	print("[smoke_slide] movement states: %s" % str(_states))
	_finish("")


func _tap(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await physics_frame
	Input.action_release(action)


func _seconds(seconds: float) -> void:
	for i in range(int(ceil(seconds * 60.0))):
		await physics_frame


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("[smoke_slide] ok: %s" % what)
	else:
		print("[smoke_slide] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[smoke_slide] PASS")
		quit(0)
	else:
		print("[smoke_slide] FAIL: %s" % "; ".join(_failures))
		quit(1)
