class_name RecordingService
extends Node
## Records gameplay for replay and analysis
## Captures player state, events, decisions, and camera data
##
## Design Philosophy:
## - Record everything needed to understand the descent
## - Event-based recording for discrete changes
## - Keyframe-based for continuous state
## - Efficient storage with delta compression

# =============================================================================
# SIGNALS
# =============================================================================

signal recording_started()
signal recording_stopped()
signal keyframe_recorded(timestamp: float)
signal event_recorded(event_type: String, data: Dictionary)
signal recording_saved(path: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Recording Rate")
## Frames per second for continuous recording
@export var recording_fps: float = 30.0
## Keyframe interval for full state capture
@export var keyframe_interval: float = 1.0
## Maximum recording duration (seconds)
@export var max_duration: float = 3600.0  # 1 hour

@export_group("Data Options")
## Record player position/velocity
@export var record_player_state: bool = true
## Record camera position/rotation
@export var record_camera_state: bool = true
## Record weather conditions
@export var record_weather: bool = true
## Record input commands
@export var record_inputs: bool = false  # Privacy consideration

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class RecordedFrame:
	var timestamp: float
	var player_position: Vector3
	var player_velocity: Vector3
	var player_rotation: float
	var movement_state: GameEnums.PlayerMovementState
	var camera_position: Vector3
	var camera_rotation: Vector3
	var is_keyframe: bool

	func to_dict() -> Dictionary:
		return {
			"t": timestamp,
			"pp": [player_position.x, player_position.y, player_position.z],
			"pv": [player_velocity.x, player_velocity.y, player_velocity.z],
			"pr": player_rotation,
			"ms": movement_state,
			"cp": [camera_position.x, camera_position.y, camera_position.z],
			"cr": [camera_rotation.x, camera_rotation.y, camera_rotation.z],
			"kf": is_keyframe
		}

	static func from_dict(data: Dictionary) -> RecordedFrame:
		var frame := RecordedFrame.new()
		frame.timestamp = data.get("t", 0.0)
		var pp: Array = data.get("pp", [0, 0, 0])
		frame.player_position = Vector3(pp[0], pp[1], pp[2])
		var pv: Array = data.get("pv", [0, 0, 0])
		frame.player_velocity = Vector3(pv[0], pv[1], pv[2])
		frame.player_rotation = data.get("pr", 0.0)
		frame.movement_state = data.get("ms", 0)
		var cp: Array = data.get("cp", [0, 0, 0])
		frame.camera_position = Vector3(cp[0], cp[1], cp[2])
		var cr: Array = data.get("cr", [0, 0, 0])
		frame.camera_rotation = Vector3(cr[0], cr[1], cr[2])
		frame.is_keyframe = data.get("kf", false)
		return frame


class RecordedEvent:
	var timestamp: float
	var event_type: String
	var data: Dictionary

	func to_dict() -> Dictionary:
		return {
			"t": timestamp,
			"type": event_type,
			"data": data
		}

	static func from_dict(d: Dictionary) -> RecordedEvent:
		var event := RecordedEvent.new()
		event.timestamp = d.get("t", 0.0)
		event.event_type = d.get("type", "")
		event.data = d.get("data", {})
		return event


class RecordingData:
	var run_id: String
	var mountain_id: String
	var start_time: float
	var end_time: float
	var outcome: GameEnums.ResolutionType
	var frames: Array[RecordedFrame] = []
	var events: Array[RecordedEvent] = []
	var keyframes: Array[int] = []  # Indices into frames array
	var weather_snapshots: Array[Dictionary] = []
	var metadata: Dictionary = {}

	func to_dict() -> Dictionary:
		var frame_dicts: Array[Dictionary] = []
		for frame in frames:
			frame_dicts.append(frame.to_dict())

		var event_dicts: Array[Dictionary] = []
		for event in events:
			event_dicts.append(event.to_dict())

		return {
			"run_id": run_id,
			"mountain_id": mountain_id,
			"start_time": start_time,
			"end_time": end_time,
			"outcome": outcome,
			"frames": frame_dicts,
			"events": event_dicts,
			"keyframes": keyframes,
			"weather": weather_snapshots,
			"metadata": metadata
		}

	static func from_dict(d: Dictionary) -> RecordingData:
		var recording := RecordingData.new()
		recording.run_id = d.get("run_id", "")
		recording.mountain_id = d.get("mountain_id", "")
		recording.start_time = d.get("start_time", 0.0)
		recording.end_time = d.get("end_time", 0.0)
		recording.outcome = d.get("outcome", 0)

		for frame_dict in d.get("frames", []):
			recording.frames.append(RecordedFrame.from_dict(frame_dict))

		for event_dict in d.get("events", []):
			recording.events.append(RecordedEvent.from_dict(event_dict))

		recording.keyframes.assign(d.get("keyframes", []))
		recording.weather_snapshots.assign(d.get("weather", []))
		recording.metadata = d.get("metadata", {})
		return recording

# =============================================================================
# STATE
# =============================================================================

## Is recording active
var is_recording: bool = false

## Current recording data
var current_recording: RecordingData

## Recording start time
var recording_start_time: float = 0.0

## Time since last frame
var frame_accumulator: float = 0.0

## Time since last keyframe
var keyframe_accumulator: float = 0.0

## Frame interval
var frame_interval: float = 1.0 / 30.0

## Player reference
var player: PlayerController

## Camera reference
var drone_camera: DroneCamera

## Weather service reference
var weather_service: WeatherService


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("RecordingService", self)

	ServiceLocator.get_service_async("PlayerController", func(p): player = p)
	ServiceLocator.get_service_async("DroneCamera", func(c): drone_camera = c)
	ServiceLocator.get_service_async("WeatherService", func(w): weather_service = w)

	frame_interval = 1.0 / recording_fps

	_connect_events()
	print("[RecordingService] Initialized")


func _connect_events() -> void:
	EventBus.run_started.connect(_on_run_started)
	EventBus.run_ended.connect(_on_run_ended)

	# Events to record
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.rope_deployment_started.connect(_on_rope_deployed)
	EventBus.injury_occurred.connect(_on_injury)
	EventBus.fatigue_threshold_crossed.connect(_on_fatigue_threshold)
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.fatal_event_started.connect(_on_fatal_event)
	EventBus.decision_recorded.connect(_on_decision_recorded)
	EventBus.incident_recorded.connect(_on_incident_recorded)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_recording:
		return

	# Check max duration
	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time - recording_start_time > max_duration:
		stop_recording()
		return

	frame_accumulator += delta
	keyframe_accumulator += delta

	# Record frames at target rate
	while frame_accumulator >= frame_interval:
		frame_accumulator -= frame_interval
		_record_frame(keyframe_accumulator >= keyframe_interval)

		if keyframe_accumulator >= keyframe_interval:
			keyframe_accumulator = 0.0


func _record_frame(is_keyframe: bool) -> void:
	var frame := RecordedFrame.new()
	frame.timestamp = Time.get_ticks_msec() / 1000.0 - recording_start_time
	frame.is_keyframe = is_keyframe

	# Player state
	if player and record_player_state:
		frame.player_position = player.global_position
		frame.player_velocity = player.smooth_velocity
		frame.player_rotation = player.rotation.y
		frame.movement_state = player.movement_state

	# Camera state
	if drone_camera and record_camera_state:
		frame.camera_position = drone_camera.global_position
		frame.camera_rotation = drone_camera.rotation_degrees

	current_recording.frames.append(frame)

	if is_keyframe:
		current_recording.keyframes.append(current_recording.frames.size() - 1)
		keyframe_recorded.emit(frame.timestamp)

		# Also record weather on keyframes
		if weather_service and record_weather:
			current_recording.weather_snapshots.append({
				"timestamp": frame.timestamp,
				"conditions": weather_service.get_conditions_summary()
			})


# =============================================================================
# RECORDING CONTROL
# =============================================================================

func start_recording(run_context: RunContext = null) -> void:
	if is_recording:
		return

	is_recording = true
	recording_start_time = Time.get_ticks_msec() / 1000.0
	frame_accumulator = 0.0
	keyframe_accumulator = 0.0

	current_recording = RecordingData.new()
	current_recording.run_id = str(randi())
	current_recording.start_time = recording_start_time

	if run_context:
		current_recording.mountain_id = run_context.mountain_id
		current_recording.metadata["difficulty"] = run_context.difficulty
		current_recording.metadata["weather_seed"] = run_context.weather_seed

	recording_started.emit()
	print("[RecordingService] Recording started")


func stop_recording() -> void:
	if not is_recording:
		return

	is_recording = false
	current_recording.end_time = Time.get_ticks_msec() / 1000.0

	recording_stopped.emit()
	print("[RecordingService] Recording stopped - %d frames, %d events" % [
		current_recording.frames.size(),
		current_recording.events.size()
	])


func save_recording(path: String = "") -> String:
	if current_recording == null:
		return ""

	if path.is_empty():
		var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
		path = "user://replays/%s_%s.replay" % [
			current_recording.mountain_id,
			timestamp
		]

	# Ensure directory exists
	var dir := DirAccess.open("user://")
	if dir:
		dir.make_dir_recursive("replays")

	# Save as JSON
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(current_recording.to_dict()))
		file.close()
		recording_saved.emit(path)
		print("[RecordingService] Saved to %s" % path)
		return path

	return ""


func load_recording(path: String) -> RecordingData:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()

	if error != OK:
		return null

	return RecordingData.from_dict(json.data)


# =============================================================================
# EVENT RECORDING
# =============================================================================

func _record_event(event_type: String, data: Dictionary = {}) -> void:
	if not is_recording:
		return

	var event := RecordedEvent.new()
	event.timestamp = Time.get_ticks_msec() / 1000.0 - recording_start_time
	event.event_type = event_type
	event.data = data

	current_recording.events.append(event)
	event_recorded.emit(event_type, data)


func _on_run_started(run_context: RunContext) -> void:
	start_recording(run_context)
	_record_event("run_started", {
		"mountain": run_context.mountain_id if run_context else "unknown"
	})


func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	_record_event("run_ended", {
		"outcome": GameEnums.ResolutionType.keys()[outcome]
	})
	current_recording.outcome = outcome
	stop_recording()
	save_recording()


func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	_record_event("slide_started", {
		"speed": entry_speed,
		"slope": slope_angle,
		"position": _get_player_position()
	})


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	_record_event("slide_ended", {
		"outcome": GameEnums.SlideOutcome.keys()[outcome],
		"speed": final_speed,
		"position": _get_player_position()
	})


func _on_rope_deployed(anchor_quality: GameEnums.AnchorQuality) -> void:
	_record_event("rope_deployed", {
		"quality": GameEnums.AnchorQuality.keys()[anchor_quality],
		"position": _get_player_position()
	})


func _on_injury(injury: Injury) -> void:
	_record_event("injury", {
		"type": GameEnums.InjuryType.keys()[injury.type],
		"severity": injury.severity,
		"body_part": GameEnums.BodyPart.keys()[injury.body_part]
	})


func _on_fatigue_threshold(fatigue: float, threshold_name: String) -> void:
	_record_event("fatigue_threshold", {
		"fatigue": fatigue,
		"threshold": threshold_name
	})


func _on_weather_changed(old_weather: GameEnums.WeatherState, new_weather: GameEnums.WeatherState) -> void:
	_record_event("weather_changed", {
		"from": GameEnums.WeatherState.keys()[old_weather],
		"to": GameEnums.WeatherState.keys()[new_weather]
	})


func _on_fatal_event(phase: GameEnums.FatalPhase) -> void:
	_record_event("fatal_event", {
		"phase": GameEnums.FatalPhase.keys()[phase],
		"position": _get_player_position()
	})


func _on_decision_recorded(decision_type: String, context: Dictionary) -> void:
	_record_event("decision", {
		"type": decision_type,
		"context": context
	})


func _on_incident_recorded(incident_type: String, context: Dictionary) -> void:
	_record_event("incident", {
		"type": incident_type,
		"context": context
	})


func _get_player_position() -> Array:
	if player:
		return [player.global_position.x, player.global_position.y, player.global_position.z]
	return [0, 0, 0]


# =============================================================================
# KEY MOMENT DETECTION
# =============================================================================

## Get key moments for highlight generation
func get_key_moments() -> Array[Dictionary]:
	if current_recording == null:
		return []

	var moments: Array[Dictionary] = []

	for event in current_recording.events:
		var importance := 0.0

		match event.event_type:
			"slide_started":
				importance = 0.7
			"slide_ended":
				if event.data.get("outcome") == "TERMINAL_RUNOUT":
					importance = 1.0
				elif event.data.get("outcome") == "TUMBLE_STOP":
					importance = 0.8
				else:
					importance = 0.5
			"rope_deployed":
				importance = 0.6
			"injury":
				importance = 0.7 + event.data.get("severity", 0) * 0.3
			"fatal_event":
				importance = 1.0
			"decision":
				importance = 0.5

		if importance >= 0.5:
			moments.append({
				"timestamp": event.timestamp,
				"type": event.event_type,
				"importance": importance,
				"data": event.data
			})

	# Sort by importance
	moments.sort_custom(func(a, b): return a["importance"] > b["importance"])

	return moments


# =============================================================================
# QUERIES
# =============================================================================

func get_current_recording() -> RecordingData:
	return current_recording


func get_recording_duration() -> float:
	if not is_recording:
		return 0.0
	return Time.get_ticks_msec() / 1000.0 - recording_start_time


func get_frame_count() -> int:
	if current_recording == null:
		return 0
	return current_recording.frames.size()


func get_summary() -> Dictionary:
	return {
		"is_recording": is_recording,
		"duration": get_recording_duration(),
		"frame_count": get_frame_count(),
		"event_count": current_recording.events.size() if current_recording else 0
	}
