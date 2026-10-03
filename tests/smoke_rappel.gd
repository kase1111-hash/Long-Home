extends SceneTree
## Headless smoke test for rappelling, played like a player:
##   1. stand at the lip of a cliff band and press R: the climber builds an
##      anchor (a timed job); R again strips it and puts them back on their feet
##   2. R again: build, weight-test, thread, and they are on the rope
##   3. hold W looking down the face: the rope runs, the climber goes down the
##      cliff, touches down on easier ground and pulls the rope after them
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_rappel.gd [-- --mountain=<id>]
##
## Runs at 4x (240 physics ticks/s, time_scale 4) with a seeded RNG. A "-s"
## script is compiled before the autoloads exist, so autoloads and project
## classes are reached dynamically (see smoke_goal.gd).

const SPEED_UP := 4.0
const SEARCH_RADIUS := 400.0
const DEPLOY_LIMIT := 120.0
const RAPPEL_LIMIT := 150.0

var mountain: String = "north_face"
var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _failures: Array[String] = []
var _states_seen: Array[String] = []
var _messages: Array[String] = []
var _fatal := false


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := str(arg)
		if text.begins_with("--mountain="):
			mountain = text.trim_prefix("--mountain=")
	call_deferred("_run")


func _run() -> void:
	seed(77001)
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
	_event_bus.diegetic_message.connect(func(text: String, _duration: float) -> void:
		_messages.append(text)
		print("[smoke_rappel] \"%s\"" % text)
	)
	_event_bus.fatal_event_started.connect(func(_phase: int) -> void: _fatal = true)

	if not await _boot_descent():
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	var rope: Object = _locator.get_service("RopeService")
	if player == null or not is_instance_valid(terrain) or not is_instance_valid(rope):
		_finish("no player, terrain or rope service")
		return

	# The lip of a cliff band: a stance with a steep face just below it
	var lip: Object = _find_lip(player, terrain, rope)
	_expect(lip != null, "found the lip of a cliff band with an anchor")
	if lip == null:
		_finish("")
		return
	var spot: Vector3 = lip.position
	spot.y = terrain.get_height_at(spot) + 0.3
	player.global_position = spot
	player.velocity = Vector3.ZERO
	var down: Vector3 = lip.slope_direction
	var pivot: Node = player.get_node_or_null("CameraPivot")
	if pivot != null:
		pivot.yaw = atan2(-down.x, -down.z)
	player.look_at(player.global_position + down, Vector3.UP)
	print("[smoke_rappel] lip %s: slope %.0f deg, %s, cliff %.1f m away" % [
		spot, lip.slope_angle, _enums.SurfaceType.keys()[lip.surface_type], lip.distance_to_cliff])

	Engine.physics_ticks_per_second = int(60 * SPEED_UP)
	Engine.time_scale = SPEED_UP
	await _seconds(1.0)

	var roping: int = _enums.PlayerMovementState["ROPING"]
	var phases: Dictionary = rope.RopePhase

	# 1. Start building, then change your mind
	await _tap("rope_deploy")
	await _seconds(0.5)
	_expect(player.current_state == roping and rope.phase == int(phases["DEPLOYING"]),
		"R at the lip starts building an anchor (state %s, phase %s)" % [_state_name(player.current_state), rope.RopePhase.keys()[rope.phase]])
	await _seconds(2.0)
	await _tap("rope_deploy")
	var waited := 0.0
	while waited < 15.0 and rope.phase != int(phases["NONE"]):
		await _seconds(0.25)
		waited += 0.25
	_expect(rope.phase == int(phases["NONE"]) and player.current_state != roping,
		"R during the build strips the anchor (%.1f s, state %s)" % [waited, _state_name(player.current_state)])

	# 2. Build it for real
	player.global_position = spot
	await _seconds(0.5)
	await _tap("rope_deploy")
	var deploy_time := 0.0
	while deploy_time < DEPLOY_LIMIT and rope.phase == int(phases["DEPLOYING"]):
		await _seconds(0.25)
		deploy_time += 0.25
	_expect(rope.phase == int(phases["RAPPELLING"]),
		"anchor built, tested and threaded in %.0f s (phase %s)" % [deploy_time, rope.RopePhase.keys()[rope.phase]])
	_expect(deploy_time > 15.0, "setting up a rappel takes real time (%.0f s)" % deploy_time)
	if rope.phase != int(phases["RAPPELLING"]):
		_finish("")
		return

	# 3. Down the face
	var top_y: float = player.global_position.y
	var low_y := top_y
	var rappel_time := 0.0
	var max_speed := 0.0
	var window_y := top_y
	var window_time := 0.0
	var unclipped := false
	Input.action_press("move_forward")
	while rappel_time < RAPPEL_LIMIT and rope.phase == int(phases["RAPPELLING"]) and not _fatal:
		await physics_frame
		rappel_time += 1.0 / 60.0
		low_y = minf(low_y, player.global_position.y)
		window_time += 1.0 / 60.0
		if window_time >= 0.5:
			max_speed = maxf(max_speed, (window_y - player.global_position.y) / window_time)
			window_y = player.global_position.y
			window_time = 0.0
		# At the knots on a stance, unclip like a player would
		if rope.rappel_controller.at_rope_end and not unclipped:
			var here: float = terrain.get_slope_at(player.global_position)
			print("[smoke_rappel] at the rope's end on %.0f deg ground" % here)
			if here < 55.0:
				unclipped = true
				await _tap("rope_deploy")
	Input.action_release("move_forward")
	var dropped := top_y - low_y
	print("[smoke_rappel] rappelled %.1f m in %.1f s (peak %.2f m/s), phase %s, rope out %.1f m" % [
		dropped, rappel_time, max_speed, rope.RopePhase.keys()[rope.phase], rope.rappel_controller.distance_descended])
	_expect(not _fatal, "no fatal event on the rope")
	_expect(dropped > 6.0, "the rope lowers the climber down the cliff (%.1f m)" % dropped)
	_expect(max_speed < 1.5, "the brake hand keeps the pace near a metre a second without Space (%.2f m/s)" % max_speed)
	_expect(rope.phase == int(phases["PULLING"]) or rope.phase == int(phases["NONE"]),
		"the rappel ends on a stance at the bottom (phase %s%s)" % [rope.RopePhase.keys()[rope.phase], ", unclipped at the knots" if unclipped else ""])

	# 4. Pull the rope
	var pull := 0.0
	while pull < 30.0 and rope.phase != int(phases["NONE"]):
		await _seconds(0.25)
		pull += 0.25
	var on_feet := [int(_enums.PlayerMovementState["STANDING"]), int(_enums.PlayerMovementState["DOWNCLIMBING"])]
	_expect(int(player.current_state) in on_feet, "off the rope and on your feet (state %s)" % _state_name(player.current_state))
	var kept: bool = rope.inventory.has_usable_rope()
	print("[smoke_rappel] rope %s after the pull (%.1f s); rope work took %.0f s of game time in all" % [
		"recovered" if kept else "left behind", pull, rope.rope_time_total])
	_expect(_messages.size() >= 4, "the climber narrates the rope work (%d lines)" % _messages.size())

	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("[smoke_rappel] movement states: %s" % str(_states_seen))
	_finish("")


func _find_lip(player: Node3D, terrain: Object, rope: Object) -> Object:
	var detector: Object = rope.anchor_detector
	var cells: Array = terrain.find_cells(player.global_position, SEARCH_RADIUS,
		func(cell: Object) -> bool:
			return cell.slope_angle < 36.0 and cell.distance_to_cliff < 3.5 and cell.distance_to_cliff > 1.0)
	var best: Object = null
	var best_drop := 0.0
	for cell in cells:
		var down: Vector3 = cell.slope_direction
		if down.length_squared() < 0.01:
			continue
		# Steep right below, and easy ground again within a rope length down
		var steep := false
		for step in range(1, 4):
			if terrain.get_slope_at(cell.position + down * (step * 2.0)) >= 55.0:
				steep = true
				break
		if not steep:
			continue
		var drop := 0.0
		var landing := false
		for step in range(1, 16):
			var at: Vector3 = cell.position + down * (step * 2.0)
			drop = cell.position.y - terrain.get_height_at(at)
			if step > 3 and terrain.get_slope_at(at) < 36.0:
				landing = true
				break
		if not landing or drop < 8.0 or drop > 28.0:
			continue
		if detector.find_anchor(cell.position, true) == null:
			continue
		if drop > best_drop:
			best_drop = drop
			best = cell
	if best != null:
		print("[smoke_rappel] cliff below the lip drops about %.0f m" % best_drop)
	return best


func _boot_descent() -> bool:
	var packed: PackedScene = load("res://src/scenes/main.tscn") as PackedScene
	var main_scene: Node = packed.instantiate()
	root.add_child(main_scene)
	await _wait(3)

	var states: Dictionary = _enums.GameState
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	if is_instance_valid(mountain_db):
		mountain_db.select_mountain(mountain, true)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(1)
	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var conditions: Resource = conditions_script.create_moderate()
	conditions.mountain_id = mountain
	_state_manager.start_run(mountain, conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	await _wait(30)
	if _state_manager.current_state != int(states["DESCENT"]):
		_finish("could not start a descent on '%s'" % mountain)
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
		print("[smoke_rappel] ok: %s" % what)
	else:
		print("[smoke_rappel] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	if _failures.is_empty():
		print("[smoke_rappel] PASS")
		quit(0)
	else:
		print("[smoke_rappel] FAIL: %s" % "; ".join(_failures))
		quit(1)
