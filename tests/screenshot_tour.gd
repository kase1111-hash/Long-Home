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
