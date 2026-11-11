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
##
## Times are on the run's own clock (RunContext.real_time_elapsed: seconds
## played, pauses not counted), the same clock as the run's path and timer.
## The recording of the run just finished stays in memory for the replay
## (ReplayPlayer, ReplayStage); nothing is written to disk at the end of a
## run. A run set aside takes its recording with it (to_save / pending_restore),
## so the replay of a run that was continued is whole.

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
	## What was on the climber's feet (GameEnums.Footwear)
	var footwear: int = 0
	## The film crew's drone camera: where it was, which way it looked
	## (global rotation, radians) and its field of view (0: no camera)
	var camera_position: Vector3
	var camera_rotation: Vector3
	var camera_fov: float = 0.0
	var is_keyframe: bool

	func to_dict() -> Dictionary:
		return {
			"t": timestamp,
			"pp": [player_position.x, player_position.y, player_position.z],
			"pv": [player_velocity.x, player_velocity.y, player_velocity.z],
			"pr": player_rotation,
			"ms": movement_state,
			"fw": footwear,
			"cp": [camera_position.x, camera_position.y, camera_position.z],
			"cr": [camera_rotation.x, camera_rotation.y, camera_rotation.z],
			"cf": camera_fov,
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
		frame.camera_fov = data.get("cf", 0.0)
		frame.footwear = data.get("fw", 0)
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
	## Seconds before the end of a fatal run with no fatal event recorded
	## that count as its fatal moments
	const UNSEEN_LOSS := 10.0

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

	## Seconds of play the recording covers
	func get_duration() -> float:
		return maxf(end_time - start_time, 0.0)

	## The first event of a type, or null
	func first_event(event_type: String) -> RecordedEvent:
		for event in events:
			if event.event_type == event_type:
				return event
		return null

	## When control was lost for good, on the run's clock: the start of the
	## fatal event. A run filed as a fatality with none recorded (a fall off
	## the edge of the world) lost it a little before its end. INF for a run
	## that came home, and for one its player gave up: nothing fatal is in it.
	## Replays and highlights keep clear of everything from here on.
	func loss_time() -> float:
		var fatal := first_event("fatal_event")
		if fatal != null:
			return fatal.timestamp
		if outcome != GameEnums.ResolutionType.FATALITY:
			return INF
		var ended := first_event("run_ended")
		if ended != null and str(ended.data.get("cause", "")) == RunContext.CAUSE_ABANDONED:
			return INF
		var last := frames[-1].timestamp if not frames.is_empty() else end_time
		return maxf(last - UNSEEN_LOSS, start_time)

	## The recording as plain data in packed arrays (a suspended run's save
	## file): a few dozen bytes a frame instead of an object each
	func to_save() -> Dictionary:
		var count := frames.size()
		var times := PackedFloat32Array()
		var positions := PackedVector3Array()
		var velocities := PackedVector3Array()
		var yaws := PackedFloat32Array()
		var states := PackedByteArray()
		var feet := PackedByteArray()
		var camera_positions := PackedVector3Array()
		var camera_rotations := PackedVector3Array()
		var camera_fovs := PackedFloat32Array()
		times.resize(count)
		positions.resize(count)
		velocities.resize(count)
		yaws.resize(count)
		states.resize(count)
		feet.resize(count)
		camera_positions.resize(count)
		camera_rotations.resize(count)
		camera_fovs.resize(count)
		for i in range(count):
			var frame := frames[i]
			times[i] = frame.timestamp
			positions[i] = frame.player_position
			velocities[i] = frame.player_velocity
			yaws[i] = frame.player_rotation
			states[i] = int(frame.movement_state)
			feet[i] = frame.footwear
			camera_positions[i] = frame.camera_position
			camera_rotations[i] = frame.camera_rotation
			camera_fovs[i] = frame.camera_fov
		var event_dicts: Array = []
		for event in events:
			event_dicts.append({"t": event.timestamp, "type": event.event_type, "data": RunContext._plain(event.data)})
		return {
			"run_id": run_id,
			"mountain_id": mountain_id,
			"start_time": start_time,
			"end_time": end_time,
			"times": times,
			"positions": positions,
			"velocities": velocities,
			"yaws": yaws,
			"states": states,
			"feet": feet,
			"camera_positions": camera_positions,
			"camera_rotations": camera_rotations,
			"camera_fovs": camera_fovs,
			"keyframes": PackedInt32Array(keyframes),
			"events": event_dicts,
			"weather": weather_snapshots.duplicate(true),
			"metadata": RunContext._plain(metadata),
		}

	## A recording from to_save() data (null when the data is not one)
	static func from_save(d: Dictionary) -> RecordingData:
		if not (d.get("times") is PackedFloat32Array) or not (d.get("positions") is PackedVector3Array):
			return null
		var times: PackedFloat32Array = d["times"]
		var positions: PackedVector3Array = d["positions"]
		var count := mini(times.size(), positions.size())
		var velocities: PackedVector3Array = d["velocities"] if d.get("velocities") is PackedVector3Array else PackedVector3Array()
		var yaws: PackedFloat32Array = d["yaws"] if d.get("yaws") is PackedFloat32Array else PackedFloat32Array()
		var states: PackedByteArray = d["states"] if d.get("states") is PackedByteArray else PackedByteArray()
		var feet: PackedByteArray = d["feet"] if d.get("feet") is PackedByteArray else PackedByteArray()
		var camera_positions: PackedVector3Array = d["camera_positions"] if d.get("camera_positions") is PackedVector3Array else PackedVector3Array()
		var camera_rotations: PackedVector3Array = d["camera_rotations"] if d.get("camera_rotations") is PackedVector3Array else PackedVector3Array()
		var camera_fovs: PackedFloat32Array = d["camera_fovs"] if d.get("camera_fovs") is PackedFloat32Array else PackedFloat32Array()
		var recording := RecordingData.new()
		recording.run_id = str(d.get("run_id", ""))
		recording.mountain_id = str(d.get("mountain_id", ""))
		recording.start_time = float(d.get("start_time", 0.0))
		recording.end_time = float(d.get("end_time", 0.0))
		for i in range(count):
			var frame := RecordedFrame.new()
			frame.timestamp = times[i]
			frame.player_position = positions[i]
			frame.player_velocity = velocities[i] if i < velocities.size() else Vector3.ZERO
			frame.player_rotation = yaws[i] if i < yaws.size() else 0.0
			var state := int(states[i]) if i < states.size() else 0
			frame.movement_state = (state if state < GameEnums.PlayerMovementState.size() else 0) as GameEnums.PlayerMovementState
			frame.footwear = int(feet[i]) if i < feet.size() else 0
			frame.camera_position = camera_positions[i] if i < camera_positions.size() else Vector3.ZERO
			frame.camera_rotation = camera_rotations[i] if i < camera_rotations.size() else Vector3.ZERO
			frame.camera_fov = camera_fovs[i] if i < camera_fovs.size() else 0.0
			recording.frames.append(frame)
		if d.get("keyframes") is PackedInt32Array:
			for index in d["keyframes"]:
				if index >= 0 and index < count:
					recording.keyframes.append(index)
					recording.frames[index].is_keyframe = true
		if d.get("events") is Array:
			for entry in d["events"]:
				if entry is Dictionary:
					recording.events.append(RecordedEvent.from_dict(entry))
		if d.get("weather") is Array:
			for snapshot in d["weather"]:
				if snapshot is Dictionary:
					recording.weather_snapshots.append(snapshot)
		if d.get("metadata") is Dictionary:
			recording.metadata = d["metadata"]
		return recording

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

## RecordingData.to_save() data to take up when the next run starts (Main
## sets it when a run that was set aside is picked up again)
var pending_restore: Dictionary = {}


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
	EventBus.run_suspended.connect(_on_run_suspended)

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
	# Only while the descent is on: the run's clock stands still in the map
	# and in menus, and so does the recording
	if GameStateManager.current_state != GameEnums.GameState.DESCENT:
		return
	# and only once the climber is on the mountain. The state changes a moment
	# before Main places them: until then they are nowhere (a first run) or
	# still where the last run left them.
	if not _climber_is_out():
		return

	# Check max duration
	if _now() - current_recording.start_time > max_duration:
		stop_recording()
		return

	frame_accumulator += delta
	keyframe_accumulator += delta
	if frame_accumulator < frame_interval:
		return
	# One frame a tick at most: after a long tick there is still only the one
	# moment to record
	frame_accumulator = fmod(frame_accumulator, frame_interval)
	var is_keyframe := keyframe_accumulator >= keyframe_interval
	if is_keyframe:
		keyframe_accumulator = 0.0
	_record_frame(is_keyframe)


## The climber is in the world, to be seen, and being simulated
func _climber_is_out() -> bool:
	return is_instance_valid(player) and player.is_inside_tree() and player.visible \
		and player.process_mode != Node.PROCESS_MODE_DISABLED


## The time on the run's clock (seconds played)
func _now() -> float:
	var run := GameStateManager.current_run
	return run.real_time_elapsed if run != null else 0.0


func _record_frame(is_keyframe: bool) -> void:
	var frame := RecordedFrame.new()
	frame.timestamp = _now()
	frame.is_keyframe = is_keyframe

	# Player state
	if is_instance_valid(player) and record_player_state:
		frame.player_position = player.global_position
		frame.player_velocity = player.smooth_velocity
		frame.player_rotation = player.rotation.y
		frame.movement_state = player.current_state
		frame.footwear = int(player.footwear)

	# Camera state: the film crew's drone, as it was looking
	if is_instance_valid(drone_camera) and drone_camera.is_inside_tree() and record_camera_state:
		frame.camera_position = drone_camera.global_position
		frame.camera_rotation = drone_camera.global_rotation
		frame.camera_fov = drone_camera.fov

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

	# A run picked up again goes on with the recording it was set aside with
	var earlier: RecordingData = RecordingData.from_save(pending_restore) if not pending_restore.is_empty() else null
	pending_restore = {}
	if earlier != null and run_context != null and earlier.run_id == run_context.run_id:
		current_recording = earlier
	else:
		current_recording = RecordingData.new()
		current_recording.start_time = run_context.real_time_elapsed if run_context else 0.0
	current_recording.end_time = current_recording.start_time

	if run_context:
		current_recording.run_id = run_context.run_id
		current_recording.mountain_id = run_context.mountain_id
		if run_context.start_conditions:
			current_recording.metadata["difficulty"] = run_context.start_conditions.get_difficulty_score()
		current_recording.metadata["run_id"] = run_context.run_id

	recording_started.emit()
	print("[RecordingService] Recording started")


func stop_recording() -> void:
	if not is_recording:
		return

	is_recording = false
	current_recording.end_time = maxf(_now(), current_recording.frames[-1].timestamp if not current_recording.frames.is_empty() else current_recording.start_time)

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
	event.timestamp = _now()
	event.event_type = event_type
	event.data = data

	current_recording.events.append(event)
	event_recorded.emit(event_type, data)


func _on_run_started(run_context: RunContext) -> void:
	start_recording(run_context)
	_record_event("run_started", {
		"mountain": run_context.mountain_id if run_context else "unknown"
	})


## A run set aside is not a finished recording: stop (Main has already taken
## it, with to_save(), for the save file)
func _on_run_suspended(_run_context: RunContext) -> void:
	stop_recording()


## The recording so far as plain data, for a suspended run's save file
func to_save() -> Dictionary:
	if current_recording == null:
		return {}
	current_recording.end_time = _now()
	return current_recording.to_save()


func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	if current_recording == null:
		return
	_record_event("run_ended", {
		"outcome": GameEnums.ResolutionType.keys()[outcome],
		"cause": run_context.end_cause if run_context != null else ""
	})
	current_recording.outcome = outcome
	stop_recording()
	# Kept in memory for the replay. (It used to be written out as JSON at the
	# end of every run, several megabytes that nothing ever read back.)


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
		"body_part": GameEnums.BodyPart.keys()[injury.location]
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
	if current_recording == null:
		return 0.0
	return (_now() if is_recording else current_recording.end_time) - current_recording.start_time


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
