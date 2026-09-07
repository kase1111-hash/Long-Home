extends SceneTree
## Headless smoke test for the sliding mechanic: teleports the climber onto
## the nearest slideable snow slope, presses Space, and lets the slide run.
## Rides the slide for 15 s, then self-arrests with Space like a player would.
## Passes when the slide starts, ends (clean stop, arrest, tumble, catch...)
## and the game keeps running without script errors; a fatal event during
## the slide is reported but is a legitimate outcome, not a failure.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_slide.gd
##
## Implementation note: a "-s" script is compiled before the autoloads exist,
## so autoloads and project classes are reached dynamically (see smoke_goal.gd).

const MOUNTAIN := "knife_edge"
const SEARCH_RADIUS := 120.0
const SLIDE_MAX_SECONDS := 60.0
const ARREST_AFTER_SECONDS := 15.0

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
	if player == null or not is_instance_valid(terrain):
		_finish("no player or terrain")
		return

	# Find a slideable cell with open snow below it (not next to a cliff)
	var cells: Array = terrain.find_cells(player.global_position, SEARCH_RADIUS,
		func(cell: Object) -> bool: return cell.is_slideable and cell.distance_to_cliff > 40.0)
	_expect(not cells.is_empty(), "found a slideable cell within %.0f m of the summit (%d)" % [SEARCH_RADIUS, cells.size()])
	if cells.is_empty():
		_finish("")
		return
	var best: Object = cells[0]
	for cell in cells:
		if cell.slope_angle > best.slope_angle:
			best = cell
	var spot: Vector3 = best.position
	spot.y = terrain.get_height_at(spot) + 0.5
	print("[smoke_slide] slide spot %s: slope %.1f deg, surface %s, cliff %.0f m away" % [
		spot, best.slope_angle, _enums.SurfaceType.keys()[best.surface_type], best.distance_to_cliff])
	player.global_position = spot
	await _wait(30)
	_expect(player.is_on_floor(), "climber stands on the slope before sliding")

	# Face downhill and go
	var downhill: Vector3 = best.slope_direction
	if downhill.length_squared() > 0.01:
		player.look_at(player.global_position + downhill, Vector3.UP)
	Input.action_press("slide_initiate")
	await physics_frame
	await physics_frame
	Input.action_release("slide_initiate")

	var waited := 0.0
	var next_report := 5.0
	var arrested := false
	while waited < SLIDE_MAX_SECONDS and not _slide_ended and not _fatal:
		await physics_frame
		waited += 1.0 / 60.0
		if waited > 4.0 and not _slide_started:
			break
		if waited >= next_report:
			next_report += 5.0
			print("[smoke_slide] t=%2.0fs speed %.1f m/s, slope %.0f deg, at %s" % [
				waited, player.velocity.length(), terrain.get_slope_at(player.global_position), player.global_position])
		# A player rides the slide for a while, then digs the axe in
		if waited >= ARREST_AFTER_SECONDS and not arrested:
			arrested = true
			print("[smoke_slide] self-arrest (Space) at %.0f s" % waited)
			Input.action_press("slide_initiate")
			await physics_frame
			await physics_frame
			Input.action_release("slide_initiate")
	_expect(_slide_started, "slide started (Space on a slideable slope)")
	if _slide_started:
		var outcome_names: Array = _enums.SlideOutcome.keys()
		if _fatal:
			print("[smoke_slide] slide ended in a fatal event after %.1f s (legitimate outcome)" % waited)
		else:
			_expect(_slide_ended, "slide ended within %.0f s" % SLIDE_MAX_SECONDS)
			if _slide_ended:
				print("[smoke_slide] slide outcome: %s after %.1f s" % [outcome_names[_slide_outcome], waited])
	await _wait(60)
	_expect(_state_manager.current_state == int(states["DESCENT"]) or _fatal or _state_manager.current_state == int(states["RESOLUTION"]),
		"game still in a valid state afterwards (state %d)" % _state_manager.current_state)
	print("[smoke_slide] movement states: %s" % str(_states))
	_finish("")


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
