extends SceneTree
## Screenshot tour: boots the game into a descent and saves a few PNGs so the
## sky, lighting, fog, terrain and climber model can be inspected offline.
##
## Run from the project root (needs a display; xvfb works, headless does not):
##
##   mkdir -p /tmp/shots && xvfb-run -a -s "-screen 0 1280x720x24" \
##     godot --path . --rendering-driver opengl3 --audio-driver Dummy \
##     -s res://tests/screenshot_tour.gd -- --out=/tmp/shots
##
## Flow:
##   1. Instantiate res://src/scenes/main.tscn under the root.
##   2. Wait for GameStateManager to reach DESCENT (the debug quick start does
##      this on its own; if it has not after ~3 s, drive the flow ourselves:
##      MOUNTAIN_SELECT -> LOADOUT_CONFIG -> PLANNING -> start_run -> DESCENT).
##   3. Settle ~90 frames, save descent_01.png.
##   4. Rotate the camera pivot yaw by 90 degrees, save descent_02.png.
##   5. Hold move_forward for ~120 frames, save descent_03.png.
##   6. Quit.
##
## Arguments (after "--"):
##   --out=<dir>        directory for the PNGs (default: /tmp)
##   --hide-ui          hide the UI CanvasLayer so only the 3D world is captured
##   --weather=<NAME>   force a GameEnums.WeatherState (e.g. STORM, WHITEOUT)
##   --time=<hour>      force the TimeService clock (e.g. 18.5 for dusk)
##   --wind=<NAME>      force a GameEnums.WindStrength (e.g. STRONG, GALE)
##   --temperature=<C>  shift TemperatureSystem.base_temperature so the air at
##                      the climber reaches this value (e.g. 4 for rain)
##   --slide            after the walk, teleport onto the nearest slideable
##                      slope, press Space and save slide_01/02.png mid-slide
##   --gear             after the walk, stage the mountaineering kit and save
##                      gear_skiing, gear_carve, gear_downclimb, gear_rappel
##                      and gear_glissade PNGs (skis, crampons, axe, rope)
##   --settle=<frames>  frames to wait before the first shot (default 90;
##                      fog and weather ease in over a few seconds, so use
##                      ~400 when forcing a storm or whiteout)
##
## Prints the absolute path of every image it saves.
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator, EventBus or any class_name from the project at compile
## time (doing so compiles those scripts too early and breaks them). Every
## project object is therefore reached dynamically via /root/<autoload> nodes
## and load(), after the deferred _run() starts.

const SETTLE_FRAMES := 90
const TURN_FRAMES := 40
const WALK_FRAMES := 120
const DESCENT_WAIT_FRAMES := 180

var out_dir: String = "/tmp"
var hide_ui: bool = false
var force_weather: String = ""
var force_time: float = -1.0
var force_wind: String = ""
var force_temperature: float = -999.0
var do_slide: bool = false
var do_gear: bool = false
var settle_frames: int = SETTLE_FRAMES

## Autoload nodes (resolved at run time, see note above)
var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null

## GameEnums.GameState values looked up at run time
var _state_main_menu: int = 1
var _state_mountain_select: int = 2
var _state_loadout: int = 3
var _state_planning: int = 4
var _state_descent: int = 6


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := str(arg)
		if text.begins_with("--out="):
			out_dir = text.trim_prefix("--out=")
		elif text == "--hide-ui":
			hide_ui = true
		elif text.begins_with("--weather="):
			force_weather = text.trim_prefix("--weather=").to_upper()
		elif text.begins_with("--time="):
			force_time = float(text.trim_prefix("--time="))
		elif text.begins_with("--wind="):
			force_wind = text.trim_prefix("--wind=").to_upper()
		elif text.begins_with("--temperature="):
			force_temperature = float(text.trim_prefix("--temperature="))
		elif text == "--slide":
			do_slide = true
		elif text == "--gear":
			do_gear = true
		elif text.begins_with("--settle="):
			settle_frames = maxi(int(text.trim_prefix("--settle=")), 1)
	call_deferred("_run")


func _run() -> void:
	print("[ScreenshotTour] Output directory: %s" % out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)

	if not _resolve_autoloads():
		quit(1)
		return

	var packed: PackedScene = load("res://src/scenes/main.tscn") as PackedScene
	if packed == null:
		push_error("[ScreenshotTour] Could not load main.tscn")
		quit(1)
		return

	var main_scene: Node = packed.instantiate()
	root.add_child(main_scene)

	# 2. Wait for the descent (the debug quick start usually gets us there)
	var waited := 0
	while _current_state() != _state_descent and waited < DESCENT_WAIT_FRAMES:
		await process_frame
		waited += 1

	if _current_state() != _state_descent:
		print("[ScreenshotTour] Quick start did not reach DESCENT; driving the flow")
		await _drive_to_descent()

	if _current_state() != _state_descent:
		push_error("[ScreenshotTour] Could not reach DESCENT (state %d)" % _current_state())
		quit(1)
		return

	await _apply_overrides(main_scene)

	# 3. Let terrain, lighting and the camera settle
	await _wait_frames(settle_frames)
	_print_scene_summary()
	_save_shot("descent_01.png")

	# 4. Swing the camera a quarter turn
	var pivot: Node = _get_camera_pivot()
	if pivot != null:
		var yaw: float = pivot.yaw
		pivot.yaw = yaw + PI * 0.5
	else:
		push_warning("[ScreenshotTour] No PlayerCamera found; skipping rotation")
	await _wait_frames(TURN_FRAMES)
	_save_shot("descent_02.png")

	# 5. Walk forward for a couple of seconds
	Input.action_press("move_forward")
	await _wait_frames(WALK_FRAMES)
	Input.action_release("move_forward")
	await process_frame
	_save_shot("descent_03.png")

	# 6. Optionally start a slide and capture the spray
	if do_slide:
		await _slide_shots()

	# 7. Optionally stage skis, a downclimb, a rappel and a glissade
	if do_gear:
		await _gear_shots()

	print("[ScreenshotTour] Done")
	quit(0)


# =============================================================================
# HELPERS
# =============================================================================

func _resolve_autoloads() -> bool:
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	if _state_manager == null or _enums == null or _locator == null:
		push_error("[ScreenshotTour] Autoloads missing; run with --path <project root>")
		return false

	var states: Dictionary = _enums.GameState
	_state_main_menu = states.get("MAIN_MENU", _state_main_menu)
	_state_mountain_select = states.get("MOUNTAIN_SELECT", _state_mountain_select)
	_state_loadout = states.get("LOADOUT_CONFIG", _state_loadout)
	_state_planning = states.get("PLANNING", _state_planning)
	_state_descent = states.get("DESCENT", _state_descent)
	return true


func _current_state() -> int:
	var state: int = _state_manager.current_state
	return state


func _wait_frames(count: int) -> void:
	for i in range(count):
		await process_frame


## Mirror main.gd's debug quick start when it has not run by itself
func _drive_to_descent() -> void:
	if _current_state() == _state_main_menu:
		_state_manager.transition_to(_state_mountain_select)
		await process_frame
	if _current_state() == _state_mountain_select:
		_state_manager.transition_to(_state_loadout)
		await process_frame
	if _current_state() == _state_loadout:
		_state_manager.transition_to(_state_planning)
		await process_frame

	if _current_state() == _state_planning:
		var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
		var conditions: Resource = conditions_script.create_moderate()
		var run: Object = _state_manager.start_run("knife_edge", conditions)
		if run == null:
			push_error("[ScreenshotTour] start_run failed")
			return
		_state_manager.transition_to(_state_descent)
		await process_frame


## Wait (up to [param max_frames]) for a service to register; null on timeout
func _wait_for_service(service_name: String, max_frames: int = 180) -> Object:
	var frames := 0
	while frames < max_frames:
		var obj: Object = _locator.get_service(service_name)
		if is_instance_valid(obj):
			return obj
		await process_frame
		frames += 1
	return null


## Apply the optional --hide-ui / --weather / --time overrides.
## main.gd creates the environment services a frame or two after DESCENT is
## entered, so the weather/time overrides wait for them to register.
func _apply_overrides(main_scene: Node) -> void:
	if hide_ui:
		var ui: CanvasLayer = main_scene.get_node_or_null("UI") as CanvasLayer
		if ui != null:
			ui.visible = false
			print("[ScreenshotTour] UI hidden")

	if force_weather != "":
		var weather_obj: Object = await _wait_for_service("WeatherService")
		var weather_states: Dictionary = _enums.WeatherState
		if is_instance_valid(weather_obj) and weather_states.has(force_weather):
			var weather_value: int = weather_states[force_weather]
			weather_obj.current_weather = weather_value
			print("[ScreenshotTour] Weather forced to %s" % force_weather)
		else:
			push_warning("[ScreenshotTour] Unknown weather '%s' or no WeatherService" % force_weather)

	if force_time >= 0.0:
		var time_obj: Object = await _wait_for_service("TimeService")
		if is_instance_valid(time_obj):
			time_obj.current_time = fmod(force_time, 24.0)
			print("[ScreenshotTour] Time forced to %.2f" % force_time)
		else:
			push_warning("[ScreenshotTour] No TimeService; --time ignored")

	if force_wind != "":
		var wind_obj: Object = await _wait_for_service("WeatherService")
		var wind_states: Dictionary = _enums.WindStrength
		if is_instance_valid(wind_obj) and wind_states.has(force_wind):
			var wind_value: int = wind_states[force_wind]
			wind_obj.current_wind_strength = wind_value
			print("[ScreenshotTour] Wind forced to %s" % force_wind)
		else:
			push_warning("[ScreenshotTour] Unknown wind '%s' or no WeatherService" % force_wind)

	if force_temperature > -900.0:
		var temp_obj: Object = await _wait_for_service("TemperatureSystem")
		if is_instance_valid(temp_obj):
			# Let one update run so the shift is measured against live conditions
			await process_frame
			await process_frame
			var current: float = temp_obj.get_air_temperature()
			var base: float = temp_obj.base_temperature
			temp_obj.base_temperature = base + (force_temperature - current)
			print("[ScreenshotTour] Air temperature forced to %.1f C (base %.1f -> %.1f)" % [
				force_temperature, base, temp_obj.base_temperature])
		else:
			push_warning("[ScreenshotTour] No TemperatureSystem; --temperature ignored")


## Teleport onto the steepest slideable cell near the summit (as
## tests/smoke_slide.gd does), press Space and save two shots mid-slide
func _slide_shots() -> void:
	var player := _get_player()
	var terrain: Object = _locator.get_service("TerrainService")
	if player == null or not is_instance_valid(terrain):
		push_warning("[ScreenshotTour] No player or terrain; --slide skipped")
		return

	# Only slopes whose run-out stays well inside the heightfield: a slide
	# that leaves the 640 m world falls into the valley haze instead
	var bounds_min: Vector3 = terrain.terrain_bounds_min
	var bounds_max: Vector3 = terrain.terrain_bounds_max
	var margin := 140.0
	var inside := func(point: Vector3) -> bool:
		return point.x > bounds_min.x + margin and point.x < bounds_max.x - margin \
			and point.z > bounds_min.z + margin and point.z < bounds_max.z - margin
	var cells: Array = terrain.find_cells(player.global_position, 160.0,
		func(cell: Object) -> bool:
			if not cell.is_slideable or cell.distance_to_cliff <= 40.0:
				return false
			var run_out: Vector3 = cell.position + cell.slope_direction * 120.0
			return inside.call(cell.position) and inside.call(run_out)
	)
	if cells.is_empty():
		push_warning("[ScreenshotTour] No slideable cell near the summit; --slide skipped")
		return
	var best: Object = cells[0]
	for cell in cells:
		if cell.slope_angle > best.slope_angle:
			best = cell
	var spot: Vector3 = best.position
	spot.y = terrain.get_height_at(spot) + 0.5
	player.global_position = spot
	var downhill: Vector3 = best.slope_direction
	if downhill.length_squared() > 0.01:
		player.look_at(player.global_position + downhill, Vector3.UP)
	print("[ScreenshotTour] Slide spot %s: slope %.1f deg, surface %s" % [
		spot, best.slope_angle, _enums.SurfaceType.keys()[best.surface_type]])

	# Settle on the slope, snap the camera behind the climber, then go
	await _wait_frames(30)
	var pivot: Node = _get_camera_pivot()
	if pivot != null and pivot.has_method("snap_behind_player"):
		pivot.snap_behind_player()
	await _wait_frames(10)
	Input.action_press("slide_initiate")
	await physics_frame
	await physics_frame
	Input.action_release("slide_initiate")

	await _wait_frames(90)
	print("[ScreenshotTour] Slide: speed %.1f m/s at %s" % [player.velocity.length(), player.global_position])
	_save_shot("slide_01.png")
	await _wait_frames(150)
	print("[ScreenshotTour] Slide: speed %.1f m/s at %s" % [player.velocity.length(), player.global_position])
	_save_shot("slide_02.png")


## Stage the descent kit and the techniques in turn, one PNG each
func _gear_shots() -> void:
	var player := _get_player()
	var terrain: Object = _locator.get_service("TerrainService")
	var rope: Object = _locator.get_service("RopeService")
	var pivot: Node = _get_camera_pivot()
	if player == null or not is_instance_valid(terrain) or pivot == null:
		push_warning("[ScreenshotTour] No player, terrain or camera; --gear skipped")
		return
	var snow := [int(_enums.SurfaceType["SNOW_FIRM"]), int(_enums.SurfaceType["SNOW_SOFT"]), int(_enums.SurfaceType["SNOW_PACKED"])]
	var event_bus: Node = root.get_node_or_null("/root/EventBus")
	if event_bus != null:
		event_bus.diegetic_message.connect(func(text: String, _duration: float) -> void:
			print("[ScreenshotTour] Climber: \"%s\"" % text))

	# Skis: carried on the pack, then on the feet and running
	var gear_script: GDScript = load("res://src/core/data/gear_state.gd") as GDScript
	player.gear_state.add_item(gear_script.GearItem.new(int(_enums.GearType["SKIS"]), 1.0, 3.2))
	var slope_cell: Object = _find_cell(player, terrain, func(cell: Object) -> bool:
		return cell.slope_angle >= 24.0 and cell.slope_angle <= 30.0 and int(cell.surface_type) in snow and cell.distance_to_cliff > 80.0)
	if slope_cell != null:
		_place(player, terrain, slope_cell.position)
		await _ticks(30)
		player.set_footwear(int(_enums.Footwear["SKIS"]))
		await _ticks(5)
		# A diagonal line, not the fall line: straight down is 30 m/s in seconds
		player.ski.heading = slope_cell.slope_direction.rotated(Vector3.UP, 0.7)
		await _ticks(90)
		_aim_camera(pivot, player.velocity, -12.0)
		await _ticks(20)
		_save_shot("gear_skiing.png")
		Input.action_press("move_right")
		await _ticks(30)
		_aim_camera(pivot, player.velocity.rotated(Vector3.UP, 1.2), -10.0)
		await _ticks(15)
		Input.action_release("move_right")
		_save_shot("gear_carve.png")
		Input.action_press("move_back")
		await _ticks(240)
		Input.action_release("move_back")
		player.set_footwear(int(_enums.Footwear["CRAMPONS"]))
		await _ticks(10)

	# Downclimbing a steep face: crampons on, axe in, facing the slope
	var face_cell: Object = _find_cell(player, terrain, func(cell: Object) -> bool:
		return cell.slope_angle >= 39.0 and cell.slope_angle <= 44.0 and int(cell.surface_type) in snow and cell.distance_to_cliff > 12.0)
	if face_cell != null:
		_place(player, terrain, face_cell.position)
		await _ticks(40)
		_aim_camera(pivot, face_cell.slope_direction.cross(Vector3.UP), -5.0)
		Input.action_press("move_back")
		await _ticks(60)
		Input.action_release("move_back")
		_save_shot("gear_downclimb.png")

	# A sitting glissade on firm snow
	if slope_cell != null:
		_place(player, terrain, slope_cell.position)
		player.look_at(player.global_position + slope_cell.slope_direction, Vector3.UP)
		await _ticks(30)
		await _tap_action("slide_initiate")
		await _ticks(70)
		_aim_camera(pivot, player.velocity.rotated(Vector3.UP, 0.8), -8.0)
		await _ticks(15)
		_save_shot("gear_glissade.png")
		await _tap_action("slide_initiate")  # Self-arrest
		await _ticks(240)

	# A rappel down a cliff band, seen from out in the air
	if is_instance_valid(rope):
		var lip: Object = _find_cell(player, terrain, func(cell: Object) -> bool:
			return cell.slope_angle < 36.0 and cell.distance_to_cliff < 3.5 and cell.distance_to_cliff > 1.0 \
				and rope.anchor_detector.find_anchor(cell.position, true) != null \
				and terrain.get_slope_at(cell.position + cell.slope_direction * 4.0) >= 55.0)
		if lip != null:
			_place(player, terrain, lip.position)
			var down: Vector3 = lip.slope_direction
			_aim_camera(pivot, down, -10.0)
			await _ticks(20)
			rope.request_rappel(player)
			Engine.time_scale = 8.0
			var waited := 0
			while rope.phase == int(rope.RopePhase["DEPLOYING"]) and waited < 6000:
				await physics_frame
				waited += 1
			Engine.time_scale = 1.0
			Input.action_press("move_forward")
			await _ticks(360)
			Input.action_release("move_forward")
			_aim_camera(pivot, -down, 8.0)
			await _ticks(25)
			print("[ScreenshotTour] Rappel: rope phase %s, %.1f m of rope out" % [
				rope.RopePhase.keys()[rope.phase], rope.rappel_controller.distance_descended])
			_save_shot("gear_rappel.png")
			await _tap_action("rope_deploy")
			await _ticks(30)

## Wait a number of physics ticks (rendered frames can each run several)
func _ticks(count: int) -> void:
	for i in range(count):
		await physics_frame


func _find_cell(player: Node3D, terrain: Object, condition: Callable) -> Object:
	var cells: Array = terrain.find_cells(player.global_position, 320.0, condition)
	if cells.is_empty():
		return null
	return cells[0]


func _place(player: Node3D, terrain: Object, at: Vector3) -> void:
	var spot := at
	spot.y = terrain.get_height_at(spot) + 0.3
	player.global_position = spot
	player.velocity = Vector3.ZERO


## Point the camera along a horizontal direction at a pitch (degrees)
func _aim_camera(pivot: Node, direction: Vector3, pitch_degrees: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return
	flat = flat.normalized()
	pivot.yaw = atan2(-flat.x, -flat.z)
	pivot.pitch = deg_to_rad(pitch_degrees)


func _tap_action(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await physics_frame
	Input.action_release(action)


func _get_player() -> Node3D:
	var player_obj: Object = _locator.get_service("PlayerController")
	if not is_instance_valid(player_obj) or not (player_obj is Node3D):
		return null
	return player_obj as Node3D


func _get_camera_pivot() -> Node:
	var player := _get_player()
	if player == null:
		return null
	var pivot: Node = player.get_node_or_null("CameraPivot")
	return pivot


func _save_shot(file_name: String) -> void:
	var image: Image = root.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		push_error("[ScreenshotTour] Viewport image is empty (headless?)")
		return
	var path := out_dir.path_join(file_name)
	var err := image.save_png(path)
	if err != OK:
		push_error("[ScreenshotTour] Failed to save %s (error %d)" % [path, err])
		return
	print("[ScreenshotTour] Saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])


## A few facts that help interpret the images
func _print_scene_summary() -> void:
	var camera := root.get_viewport().get_camera_3d()
	if camera != null:
		print("[ScreenshotTour] Camera at %s looking %s" % [
			camera.global_position, -camera.global_transform.basis.z])

	var player := _get_player()
	if player != null:
		print("[ScreenshotTour] Player at %s" % player.global_position)

	var env_obj: Object = _locator.get_service("EnvironmentService")
	if is_instance_valid(env_obj):
		var visuals: Object = env_obj.get("visuals")
		if is_instance_valid(visuals) and visuals.has_method("get_debug_info"):
			print("[ScreenshotTour] Visuals: %s" % str(visuals.get_debug_info()))

	var mesh_count := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		mesh_count += 1
	print("[ScreenshotTour] MeshInstance3D count: %d" % mesh_count)
