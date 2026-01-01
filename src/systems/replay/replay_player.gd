class_name ReplayPlayer
extends Node
## Plays back recorded gameplay
## Supports topo view, key moment highlighting, and ethical constraints
##
## Design Philosophy:
## - Show path on topo view
## - Highlight where decisions compounded
## - No blame, just clarity
## - Fatal moments: normal speed only, no camera switching

# =============================================================================
# SIGNALS
# =============================================================================

signal playback_started()
signal playback_paused()
signal playback_resumed()
signal playback_stopped()
signal playback_completed()
signal timestamp_changed(timestamp: float)
signal event_reached(event: RecordingService.RecordedEvent)
signal key_moment_reached(moment: Dictionary)

# =============================================================================
# ENUMS
# =============================================================================

enum PlaybackMode {
	TOPO_VIEW,      # Top-down path visualization
	FOLLOW_CAMERA,  # Follow the recorded camera
	FREE_CAMERA     # Free-look while playing
}

enum PlaybackState {
	STOPPED,
	PLAYING,
	PAUSED
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Playback")
## Playback speed (1.0 = normal)
@export var playback_speed: float = 1.0
## Enable speed controls (disabled for fatal replays)
@export var allow_speed_control: bool = true
## Enable camera switching (disabled for fatal replays)
@export var allow_camera_switch: bool = true

@export_group("Topo View")
## Path line color
@export var path_color: Color = Color(0.2, 0.6, 1.0, 0.8)
## Key moment marker color
@export var moment_color: Color = Color(1.0, 0.8, 0.2, 1.0)
## Path line width
@export var path_width: float = 2.0

@export_group("Ethical Constraints")
## Stop before fatal moment position
@export var respect_fatal_boundaries: bool = true
## Auto-skip to path after fatal
@export var skip_to_path_after_fatal: bool = true

# =============================================================================
# STATE
# =============================================================================

## Current recording
var recording: RecordingService.RecordingData

## Playback state
var state: PlaybackState = PlaybackState.STOPPED

## Current playback mode
var mode: PlaybackMode = PlaybackMode.TOPO_VIEW

## Current timestamp
var current_timestamp: float = 0.0

## Current frame index
var current_frame_index: int = 0

## Current event index
var current_event_index: int = 0

## Key moments for highlighting
var key_moments: Array[Dictionary] = []

## Is in fatal section
var in_fatal_section: bool = false

## Fatal section start time
var fatal_section_start: float = -1.0

## Path points for topo view
var path_points: PackedVector3Array = PackedVector3Array()

## Has this recording been played (for one-time fatal rule)
var fatal_replayed: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("ReplayPlayer", self)
	print("[ReplayPlayer] Initialized")


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if state != PlaybackState.PLAYING:
		return

	if recording == null:
		return

	# Apply playback speed (but never for fatal sections)
	var effective_speed := playback_speed
	if in_fatal_section:
		effective_speed = 1.0  # Always normal speed for fatal

	current_timestamp += delta * effective_speed

	# Check if playback complete
	if current_timestamp >= recording.end_time - recording.start_time:
		_complete_playback()
		return

	# Update frame position
	_update_frame()

	# Check events
	_check_events()

	# Check key moments
	_check_key_moments()

	timestamp_changed.emit(current_timestamp)


func _update_frame() -> void:
	# Find current frame
	while current_frame_index < recording.frames.size() - 1:
		var next_frame := recording.frames[current_frame_index + 1]
		if next_frame.timestamp > current_timestamp:
			break
		current_frame_index += 1

	# Interpolate between frames
	if current_frame_index < recording.frames.size() - 1:
		var frame_a := recording.frames[current_frame_index]
		var frame_b := recording.frames[current_frame_index + 1]
		var t := (current_timestamp - frame_a.timestamp) / maxf(0.001, frame_b.timestamp - frame_a.timestamp)
		t = clampf(t, 0.0, 1.0)

		_apply_interpolated_frame(frame_a, frame_b, t)
	elif current_frame_index < recording.frames.size():
		_apply_frame(recording.frames[current_frame_index])


func _apply_frame(frame: RecordingService.RecordedFrame) -> void:
	# Apply frame to ghost player or visualization
	# This would connect to a ghost player node
	pass


func _apply_interpolated_frame(
	frame_a: RecordingService.RecordedFrame,
	frame_b: RecordingService.RecordedFrame,
	t: float
) -> void:
	# Interpolate position
	var position := frame_a.player_position.lerp(frame_b.player_position, t)
	var rotation := lerpf(frame_a.player_rotation, frame_b.player_rotation, t)

	# Apply to visualization
	# This would update ghost player position
	pass


func _check_events() -> void:
	while current_event_index < recording.events.size():
		var event := recording.events[current_event_index]
		if event.timestamp > current_timestamp:
			break

		event_reached.emit(event)
		_handle_event(event)
		current_event_index += 1


func _handle_event(event: RecordingService.RecordedEvent) -> void:
	match event.event_type:
		"fatal_event":
			_enter_fatal_section(event.timestamp)
		"run_ended":
			if in_fatal_section and skip_to_path_after_fatal:
				# Could skip to next interesting moment
				pass


func _check_key_moments() -> void:
	for moment in key_moments:
		var moment_time: float = moment.get("timestamp", 0.0)
		if absf(current_timestamp - moment_time) < 0.1:
			key_moment_reached.emit(moment)


# =============================================================================
# PLAYBACK CONTROL
# =============================================================================

func load_recording(data: RecordingService.RecordingData) -> void:
	recording = data
	state = PlaybackState.STOPPED
	current_timestamp = 0.0
	current_frame_index = 0
	current_event_index = 0
	in_fatal_section = false
	fatal_replayed = false

	# Extract key moments
	key_moments = _extract_key_moments()

	# Build path for topo view
	_build_path()


func play() -> void:
	if recording == null:
		return

	if state == PlaybackState.STOPPED:
		current_timestamp = 0.0
		current_frame_index = 0
		current_event_index = 0

	state = PlaybackState.PLAYING
	playback_started.emit()


func pause() -> void:
	if state == PlaybackState.PLAYING:
		state = PlaybackState.PAUSED
		playback_paused.emit()


func resume() -> void:
	if state == PlaybackState.PAUSED:
		state = PlaybackState.PLAYING
		playback_resumed.emit()


func stop() -> void:
	state = PlaybackState.STOPPED
	current_timestamp = 0.0
	playback_stopped.emit()


func seek(timestamp: float) -> void:
	if recording == null:
		return

	# Prevent seeking into fatal section if already replayed
	if in_fatal_section and fatal_replayed:
		return

	current_timestamp = clampf(timestamp, 0.0, recording.end_time - recording.start_time)

	# Find frame index
	current_frame_index = _find_frame_at_timestamp(current_timestamp)

	# Find event index
	current_event_index = _find_event_at_timestamp(current_timestamp)

	timestamp_changed.emit(current_timestamp)


func set_speed(speed: float) -> void:
	if not allow_speed_control:
		return

	if in_fatal_section:
		return  # Always normal speed for fatal

	playback_speed = clampf(speed, 0.25, 2.0)


func set_mode(new_mode: PlaybackMode) -> void:
	if not allow_camera_switch and in_fatal_section:
		return

	mode = new_mode


func _complete_playback() -> void:
	state = PlaybackState.STOPPED
	playback_completed.emit()


# =============================================================================
# FATAL SECTION HANDLING
# =============================================================================

func _enter_fatal_section(timestamp: float) -> void:
	if fatal_replayed and respect_fatal_boundaries:
		# Skip fatal section
		_skip_past_fatal()
		return

	in_fatal_section = true
	fatal_section_start = timestamp

	# Enforce ethical constraints
	playback_speed = 1.0  # Normal speed only
	allow_camera_switch = false


func _exit_fatal_section() -> void:
	in_fatal_section = false
	fatal_replayed = true
	allow_camera_switch = true


func _skip_past_fatal() -> void:
	# Find end of fatal section and skip to path
	for event in recording.events:
		if event.event_type == "run_ended" and event.timestamp > fatal_section_start:
			current_timestamp = event.timestamp
			break


# =============================================================================
# PATH BUILDING (Topo View)
# =============================================================================

func _build_path() -> void:
	path_points.clear()

	if recording == null:
		return

	# Sample path at intervals
	var sample_interval := 0.5  # Every half second
	var last_sample_time := -sample_interval

	for frame in recording.frames:
		if frame.timestamp - last_sample_time >= sample_interval:
			path_points.append(frame.player_position)
			last_sample_time = frame.timestamp


func get_path_points() -> PackedVector3Array:
	return path_points


func get_path_2d() -> PackedVector2Array:
	var points_2d := PackedVector2Array()
	for point in path_points:
		points_2d.append(Vector2(point.x, point.z))
	return points_2d


# =============================================================================
# KEY MOMENT EXTRACTION
# =============================================================================

func _extract_key_moments() -> Array[Dictionary]:
	var moments: Array[Dictionary] = []

	if recording == null:
		return moments

	for event in recording.events:
		var importance := _get_event_importance(event)
		if importance >= 0.5:
			moments.append({
				"timestamp": event.timestamp,
				"type": event.event_type,
				"importance": importance,
				"data": event.data,
				"position": _get_position_at_timestamp(event.timestamp)
			})

	# Sort by timestamp
	moments.sort_custom(func(a, b): return a["timestamp"] < b["timestamp"])

	return moments


func _get_event_importance(event: RecordingService.RecordedEvent) -> float:
	match event.event_type:
		"slide_started":
			return 0.6
		"slide_ended":
			var outcome: String = event.data.get("outcome", "")
			if outcome == "TERMINAL_RUNOUT":
				return 1.0
			elif outcome == "TUMBLE_STOP":
				return 0.8
			return 0.5
		"rope_deployed":
			return 0.7
		"injury":
			return 0.6 + event.data.get("severity", 0) * 0.4
		"fatigue_threshold":
			if event.data.get("threshold") == "critical":
				return 0.8
			return 0.5
		"fatal_event":
			return 1.0  # But excluded from highlights
		"decision":
			return 0.5
		_:
			return 0.0


func _get_position_at_timestamp(timestamp: float) -> Vector3:
	var index := _find_frame_at_timestamp(timestamp)
	if index >= 0 and index < recording.frames.size():
		return recording.frames[index].player_position
	return Vector3.ZERO


# =============================================================================
# HIGHLIGHT GENERATION
# =============================================================================

## Get moments suitable for auto-highlights (excludes fatal)
func get_highlight_moments() -> Array[Dictionary]:
	var highlights: Array[Dictionary] = []

	for moment in key_moments:
		# Exclude fatal moments
		if moment.get("type") == "fatal_event":
			continue

		# Only high importance
		if moment.get("importance", 0) >= 0.7:
			highlights.append(moment)

	return highlights


## Get ethical title for a moment
func get_moment_title(moment: Dictionary) -> String:
	var event_type: String = moment.get("type", "")

	match event_type:
		"slide_started":
			return "Slope Descent"
		"slide_ended":
			var outcome: String = moment.get("data", {}).get("outcome", "")
			match outcome:
				"CLEAN_STOP":
					return "Controlled Stop"
				"TUMBLE_STOP":
					return "Recovery"
				_:
					return "Descent Moment"
		"rope_deployed":
			return "Technical Section"
		"injury":
			return "Challenging Terrain"
		"fatigue_threshold":
			return "Endurance Test"
		"decision":
			return "Key Decision"
		_:
			return "Mountain Moment"


# =============================================================================
# UTILITY
# =============================================================================

func _find_frame_at_timestamp(timestamp: float) -> int:
	if recording == null:
		return 0

	# Binary search would be more efficient for large recordings
	for i in range(recording.frames.size()):
		if recording.frames[i].timestamp > timestamp:
			return maxi(0, i - 1)

	return maxi(0, recording.frames.size() - 1)


func _find_event_at_timestamp(timestamp: float) -> int:
	if recording == null:
		return 0

	for i in range(recording.events.size()):
		if recording.events[i].timestamp > timestamp:
			return i

	return recording.events.size()


# =============================================================================
# QUERIES
# =============================================================================

func is_playing() -> bool:
	return state == PlaybackState.PLAYING


func is_paused() -> bool:
	return state == PlaybackState.PAUSED


func get_duration() -> float:
	if recording == null:
		return 0.0
	return recording.end_time - recording.start_time


func get_progress() -> float:
	var duration := get_duration()
	if duration <= 0:
		return 0.0
	return current_timestamp / duration


func get_summary() -> Dictionary:
	return {
		"state": PlaybackState.keys()[state],
		"mode": PlaybackMode.keys()[mode],
		"timestamp": current_timestamp,
		"duration": get_duration(),
		"progress": get_progress(),
		"speed": playback_speed,
		"in_fatal_section": in_fatal_section,
		"key_moments": key_moments.size()
	}
