class_name ReplayStage
extends Node3D
## The mountain as the stage of a replay: the climber is moved through a
## recording like a puppet, the light and the weather are those of the hour
## being shown, and the stage's own camera looks on.
##
## ReplayPlayer keeps the clock and decides what may be shown; this node only
## shows it:
##   stage.begin(recording, run)        # takes the climber and the sky over
##   stage.show_frame(a, b, t)          # between two recorded frames
##   stage.set_camera_mode(ReplayStage.CameraMode.DRONE)
##   stage.end()                        # puts everything back as it was
##
## The climber is the game's own climber node, with its own controller asleep
## (so nothing is simulated: no gravity, no slips, no fatigue) and only its
## animation and the snow it throws up awake. Nothing here changes the run
## that is being shown.

enum CameraMode {
	CHASE,  # Behind the climber, as the descent was played
	DRONE,  # The film crew's drone, as it flew and looked on the day
	WIDE,   # From across the slope: the mountain, and a figure on it
}

const CAMERA_NAMES := {
	CameraMode.CHASE: "Behind the climber",
	CameraMode.DRONE: "The film crew's drone",
	CameraMode.WIDE: "From across the slope",
}

## The chase camera: metres behind and above the climber
const CHASE_BACK := 6.5
const CHASE_UP := 2.8
## The wide camera: metres across the slope and above the climber
const WIDE_ACROSS := 42.0
const WIDE_UP := 11.0
## How quickly each camera closes on where it wants to be (per second)
const CHASE_FOLLOW := 5.0
const WIDE_FOLLOW := 1.2
## No camera sits closer to the ground than this (metres)
const GROUND_CLEARANCE := 1.4
## Further than this from one shown moment to the next is a cut, not a move
## (the replay was wound, or the climber was moved): the camera goes there at
## once instead of gliding across the mountain
const CUT_DISTANCE := 25.0
const CHASE_FOV := 70.0
const WIDE_FOV := 42.0

var player: PlayerController = null
var camera: Camera3D = null
var mode: CameraMode = CameraMode.CHASE
var is_open: bool = false

## The pose being shown: where the climber is, and the drone's recorded view
var shown_position: Vector3 = Vector3.ZERO
var shown_yaw: float = 0.0
var shown_time: float = 0.0
var _drone_view: Transform3D = Transform3D.IDENTITY
var _drone_fov: float = 0.0

var _terrain: TerrainService = null
var _time: TimeService = null
var _weather: WeatherService = null
var _animation: PlayerAnimationController = null
var _effects: PlayerSurfaceEffects = null
var _saved: Dictionary = {}
var _start_hour: float = 12.0
var _weather_snapshots: Array[Dictionary] = []
var _weather_index: int = -1
var _snap_camera: bool = true


# =============================================================================
# BEGIN AND END
# =============================================================================

## Take the climber and the sky over for a recording. False when there is
## nothing to show it with (no climber, no mountain).
func begin(recording: RecordingService.RecordingData, run: RunContext) -> bool:
	if is_open:
		end()
	player = ServiceLocator.get_service("PlayerController") as PlayerController
	_terrain = ServiceLocator.get_service("TerrainService") as TerrainService
	_time = ServiceLocator.get_service("TimeService") as TimeService
	_weather = ServiceLocator.get_service("WeatherService") as WeatherService
	if not is_instance_valid(player) or _terrain == null or recording == null or recording.frames.is_empty():
		return false
	_animation = player.get_node_or_null("AnimationController") as PlayerAnimationController
	_effects = player.get_node_or_null("SurfaceEffects") as PlayerSurfaceEffects
	var drones := ServiceLocator.get_service("DroneService") as DroneService
	var drone: Node3D = drones.drone if drones != null else null

	_saved = {
		"player_process": player.process_mode,
		"player_visible": player.visible,
		"player_transform": player.global_transform,
		"player_state": player.current_state,
		"player_footwear": player.footwear,
		"player_velocity": player.velocity,
		"player_cell": player.current_cell,
		"animation_process": _animation.process_mode if _animation != null else Node.PROCESS_MODE_INHERIT,
		"effects_process": _effects.process_mode if _effects != null else Node.PROCESS_MODE_INHERIT,
		"camera": get_viewport().get_camera_3d(),
		"drone": drone,
		"drone_visible": drone.visible if is_instance_valid(drone) else false,
	}
	if _time != null:
		_saved["time"] = _time.to_save()
		_saved["time_paused"] = _time.is_paused
	if _weather != null:
		_saved["weather"] = _weather.to_save()
		_saved["weather_processing"] = _weather.is_processing()

	# The climber: a puppet. Its controller sleeps; its animation does not,
	# nor the spray of a slide (which only reads where the climber is, how
	# fast, and in what state: all three are the recording's)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = true
	if _animation != null:
		_animation.process_mode = Node.PROCESS_MODE_ALWAYS
	if _effects != null:
		_effects.process_mode = Node.PROCESS_MODE_ALWAYS
	# The drone itself stays out of its own film
	if is_instance_valid(drone):
		drone.visible = false
	# The sky is the recording's from here on
	if _time != null:
		_time.pause()
	if _weather != null:
		_weather.set_process(false)
	_start_hour = run.start_conditions.time_of_day if run != null and run.start_conditions != null else 12.0
	_weather_snapshots = recording.weather_snapshots
	_weather_index = -1

	camera = Camera3D.new()
	camera.name = "ReplayCamera"
	camera.far = 6000.0
	add_child(camera)
	camera.make_current()
	_snap_camera = true
	is_open = true
	set_process(true)
	return true


## Put the climber, the sky and the camera back as begin() found them
func end() -> void:
	if not is_open:
		return
	is_open = false
	set_process(false)
	if is_instance_valid(player):
		_set_state(_saved.get("player_state", GameEnums.PlayerMovementState.STANDING))
		player.footwear = _saved.get("player_footwear", player.footwear)
		player.velocity = _saved.get("player_velocity", Vector3.ZERO)
		player.current_cell = _saved.get("player_cell")
		player.global_transform = _saved.get("player_transform", player.global_transform)
		player.visible = _saved.get("player_visible", true)
		player.process_mode = _saved.get("player_process", Node.PROCESS_MODE_INHERIT)
	if is_instance_valid(_animation):
		_animation.process_mode = _saved.get("animation_process", Node.PROCESS_MODE_INHERIT)
	if is_instance_valid(_effects):
		_effects.process_mode = _saved.get("effects_process", Node.PROCESS_MODE_INHERIT)
		_effects.stop()
	var drone: Variant = _saved.get("drone")
	if is_instance_valid(drone):
		(drone as Node3D).visible = _saved.get("drone_visible", true)
	if _time != null and _saved.has("time"):
		_time.restore(_saved["time"])
		_time.is_paused = _saved.get("time_paused", false)
	if _weather != null and _saved.has("weather"):
		_weather.restore(_saved["weather"], _time.current_time if _time != null else 12.0)
		_weather.set_process(_saved.get("weather_processing", true))
	var previous: Variant = _saved.get("camera")
	if is_instance_valid(previous) and (previous as Camera3D).is_inside_tree():
		(previous as Camera3D).make_current()
	if is_instance_valid(camera):
		camera.queue_free()
	camera = null
	_saved = {}


# =============================================================================
# SHOWING A MOMENT
# =============================================================================

## Show the moment a share t (0-1) of the way from recorded frame a to frame b
func show_frame(a: RecordingService.RecordedFrame, b: RecordingService.RecordedFrame, t: float) -> void:
	if not is_open or not is_instance_valid(player):
		return
	# A long way between two frames is a jump (the climber was moved, not
	# moving): no gliding across the mountain
	if a.player_position.distance_to(b.player_position) > CUT_DISTANCE:
		t = 0.0 if t < 0.5 else 1.0
	var was_at := shown_position
	shown_position = a.player_position.lerp(b.player_position, t)
	if was_at.distance_to(shown_position) > CUT_DISTANCE:
		_snap_camera = true
	shown_yaw = lerp_angle(a.player_rotation, b.player_rotation, t)
	shown_time = lerpf(a.timestamp, b.timestamp, t)
	var nearer := a if t < 0.5 else b

	player.global_position = shown_position
	player.rotation = Vector3(0.0, shown_yaw, 0.0)
	player.velocity = a.player_velocity.lerp(b.player_velocity, t)
	player.smooth_velocity = player.velocity
	player.footwear = (nearer.footwear if nearer.footwear < GameEnums.Footwear.size() else 0) as GameEnums.Footwear
	player.current_cell = _terrain.get_cell_at(shown_position)
	_set_state(nearer.movement_state)

	# The drone's own take, when it was filming
	_drone_fov = nearer.camera_fov
	if a.camera_fov > 0.0 and b.camera_fov > 0.0:
		var from := Transform3D(Basis.from_euler(a.camera_rotation), a.camera_position)
		var to := Transform3D(Basis.from_euler(b.camera_rotation), b.camera_position)
		_drone_view = from.interpolate_with(to, t)
		_drone_fov = lerpf(a.camera_fov, b.camera_fov, t)

	_show_sky(shown_time)
	if _snap_camera:
		_place_camera(1.0)


## The climber's movement state, told to its animation the way the
## controller would have told it
func _set_state(state: GameEnums.PlayerMovementState) -> void:
	if not is_instance_valid(player) or player.current_state == state:
		return
	var old := player.current_state
	player.current_state = state
	if is_instance_valid(_animation):
		_animation._on_player_state_changed(old, state)


## The hour and the weather of a moment on the run's clock
func _show_sky(seconds: float) -> void:
	if _time != null:
		_time.current_time = fposmod(_start_hour + seconds * GameEnums.TIME_SCALE / 3600.0, 24.0)
	if _weather == null or _weather_snapshots.is_empty():
		return
	# The last snapshot at or before this moment (they are in order)
	var index := _weather_index
	if index < 0 or float(_weather_snapshots[index].get("timestamp", 0.0)) > seconds:
		index = 0
	while index + 1 < _weather_snapshots.size() and float(_weather_snapshots[index + 1].get("timestamp", 0.0)) <= seconds:
		index += 1
	if index == _weather_index:
		return
	_weather_index = index
	var conditions: Dictionary = _weather_snapshots[index].get("conditions", {})
	var weather_name := str(conditions.get("weather", ""))
	var wind_name := str(conditions.get("wind_strength", ""))
	if GameEnums.WeatherState.has(weather_name) and int(GameEnums.WeatherState[weather_name]) != int(_weather.current_weather):
		_weather.reset_for_run(GameEnums.WeatherState[weather_name])
	if GameEnums.WindStrength.has(wind_name):
		_weather._set_wind_strength(GameEnums.WindStrength[wind_name])
	_weather.wind_speed = float(conditions.get("wind_speed", _weather.wind_speed))


# =============================================================================
# CAMERAS
# =============================================================================

func set_camera_mode(new_mode: CameraMode) -> void:
	if new_mode == mode:
		return
	mode = new_mode
	_snap_camera = true
	_place_camera(1.0)


## Whether the drone was filming at the moment being shown
func has_drone_view() -> bool:
	return _drone_fov > 0.0


func _process(delta: float) -> void:
	if is_open:
		_place_camera(delta)


## Move the stage's camera toward where its mode wants it (at once after a
## change of mode or a jump in the recording)
func _place_camera(delta: float) -> void:
	if not is_instance_valid(camera):
		return
	var showing := mode
	if showing == CameraMode.DRONE and not has_drone_view():
		showing = CameraMode.WIDE
	var want := Transform3D.IDENTITY
	var fov := CHASE_FOV
	var follow := CHASE_FOLLOW
	match showing:
		CameraMode.DRONE:
			# The take as it was shot: no smoothing of ours on top of the drone's
			camera.global_transform = _drone_view
			camera.fov = _drone_fov
			_snap_camera = false
			return
		CameraMode.WIDE:
			want = _wide_view()
			fov = WIDE_FOV
			follow = WIDE_FOLLOW
		_:
			want = _chase_view()
	if _snap_camera:
		camera.global_transform = want
		camera.fov = fov
		_snap_camera = false
		return
	camera.global_transform = camera.global_transform.interpolate_with(want, 1.0 - exp(-follow * delta))
	camera.fov = lerpf(camera.fov, fov, 1.0 - exp(-4.0 * delta))


func _chase_view() -> Transform3D:
	var forward := Vector3(-sin(shown_yaw), 0.0, -cos(shown_yaw))
	var eye := _above_ground(shown_position - forward * CHASE_BACK + Vector3.UP * CHASE_UP)
	return _looking(eye, shown_position + Vector3.UP * 1.3)


func _wide_view() -> Transform3D:
	var fall := Vector3.ZERO
	var cell := _terrain.get_cell_at(shown_position) if _terrain != null else null
	if cell != null:
		fall = Vector3(cell.slope_direction.x, 0.0, cell.slope_direction.z)
	if fall.length_squared() < 0.01:
		fall = Vector3(-sin(shown_yaw), 0.0, -cos(shown_yaw))
	var across := fall.normalized().cross(Vector3.UP)
	var eye := _above_ground(shown_position + across * WIDE_ACROSS + Vector3.UP * WIDE_UP)
	return _looking(eye, shown_position + Vector3.UP * 1.0)


func _above_ground(eye: Vector3) -> Vector3:
	if _terrain != null:
		eye.y = maxf(eye.y, _terrain.get_height_at(eye) + GROUND_CLEARANCE)
	return eye


func _looking(eye: Vector3, target: Vector3) -> Transform3D:
	if eye.distance_squared_to(target) < 0.01:
		eye += Vector3(0.0, 1.0, 1.0)
	return Transform3D(Basis.IDENTITY, eye).looking_at(target, Vector3.UP)
