class_name ReplayPlayer
extends Node
## Plays the recording of a run back on the mountain.
##
## This is the clock and the rules of a replay; ReplayStage shows what the
## clock says (the climber, the sky, the camera) and ReplayScreen is the
## controls. Times are on the run's own clock (seconds played).
##   player.open(recording, stage)
##   player.play()                 # pause(), toggle()
##   player.seek(seconds)          # anywhere the rules allow
##   player.set_speed(2.0)         # SPEEDS
##   player.play_range(from, to)   # a highlight
##   player.close()
##
## A run that ended in a fatal event (RecordingData.loss_time: every run filed
## as a fatality, except one its player gave up) is replayed under SPEC-SHEET
## 11 and 17:
##   - normal speed only, and one fixed camera (the film crew's drone, which
##     on the day already kept to the rules for filming a fall);
##   - the fatal moments are shown once, as one continuous take: once the
##     replay has entered them it cannot be paused, sped up, wound back or
##     re-framed, and it can never be entered by winding forward;
##   - after that the replay stops where control was lost. The rest of the
##     day is on the map replay ("replay defaults to path, not fall").

# =============================================================================
# SIGNALS
# =============================================================================

signal playback_started()
signal playback_paused()
signal playback_completed()
signal timestamp_changed(timestamp: float)
## The speed, or what the rules allow, changed (the screen redraws its controls)
signal controls_changed()
## A replay stopped where control was lost, because what follows has been
## shown once already
signal fatal_boundary_reached()

# =============================================================================
# CONSTANTS
# =============================================================================

enum PlaybackState {
	STOPPED,
	PLAYING,
	PAUSED
}

## The speeds a replay can run at
const SPEEDS: Array[float] = [0.5, 1.0, 2.0, 4.0, 8.0]

## Key of the mark, on a recording, that its fatal moments have been shown
const FATAL_REPLAYED_KEY := "fatal_replayed"

# =============================================================================
# STATE
# =============================================================================

var recording: RecordingService.RecordingData = null
var stage: ReplayStage = null
var state: PlaybackState = PlaybackState.STOPPED

## Where the replay is, on the run's clock (seconds)
var current_timestamp: float = 0.0
var playback_speed: float = 1.0

## The run ended in a fatal event, which began at fatal_start on the run's clock
var is_fatal_run: bool = false
var fatal_start: float = INF
## The replay is inside the fatal moments (the one continuous take)
var in_fatal_section: bool = false

## Playing a stretch (a highlight): pause when the clock gets here
var _stop_at: float = INF
var _frame_index: int = 0


func _ready() -> void:
	ServiceLocator.register_service("ReplayPlayer", self)
	print("[ReplayPlayer] Initialized")


# =============================================================================
# OPEN AND CLOSE
# =============================================================================

## Get a recording ready to play on a stage; shows its first moment. False
## when there is nothing to play.
func open(data: RecordingService.RecordingData, on_stage: ReplayStage) -> bool:
	if data == null or data.frames.size() < 2 or on_stage == null:
		return false
	recording = data
	stage = on_stage
	state = PlaybackState.PAUSED
	playback_speed = 1.0
	in_fatal_section = false
	_stop_at = INF
	_frame_index = 0

	# A fatal run: where control was lost
	var lost := recording.loss_time()
	is_fatal_run = is_finite(lost)
	fatal_start = clampf(lost, get_start(), get_end()) if is_fatal_run else INF
	if is_fatal_run:
		stage.set_camera_mode(ReplayStage.CameraMode.DRONE)

	current_timestamp = get_start()
	_show()
	controls_changed.emit()
	timestamp_changed.emit(current_timestamp)
	return true


## Leave the replay. Fatal moments that were being shown count as shown.
func close() -> void:
	if in_fatal_section and recording != null:
		recording.metadata[FATAL_REPLAYED_KEY] = true
	state = PlaybackState.STOPPED
	in_fatal_section = false
	recording = null
	stage = null


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if state != PlaybackState.PLAYING or recording == null:
		return
	var speed := 1.0 if (is_fatal_run or in_fatal_section) else playback_speed
	var next := current_timestamp + delta * speed

	# A fatal run: the moment control was lost
	if is_fatal_run and not in_fatal_section and next >= fatal_start:
		if has_fatal_been_replayed():
			# Shown once already: the replay ends here, the rest is on the map
			current_timestamp = fatal_start
			_show()
			timestamp_changed.emit(current_timestamp)
			_pause()
			fatal_boundary_reached.emit()
			return
		in_fatal_section = true
		_stop_at = INF
		controls_changed.emit()

	if next >= _stop_at and not in_fatal_section:
		current_timestamp = _stop_at
		_stop_at = INF
		_show()
		timestamp_changed.emit(current_timestamp)
		_pause()
		return

	if next >= get_end():
		current_timestamp = get_end()
		_show()
		timestamp_changed.emit(current_timestamp)
		_complete()
		return

	current_timestamp = next
	_show()
	timestamp_changed.emit(current_timestamp)


## Put the moment the clock says on the stage
func _show() -> void:
	if recording == null or stage == null:
		return
	var frames := recording.frames
	# The frame at or before the clock (the clock usually moves on a little)
	if _frame_index >= frames.size() or frames[_frame_index].timestamp > current_timestamp:
		_frame_index = _find_frame(current_timestamp)
	while _frame_index + 1 < frames.size() and frames[_frame_index + 1].timestamp <= current_timestamp:
		_frame_index += 1
	var a := frames[_frame_index]
	var b := frames[mini(_frame_index + 1, frames.size() - 1)]
	var t := clampf((current_timestamp - a.timestamp) / maxf(b.timestamp - a.timestamp, 0.001), 0.0, 1.0)
	stage.show_frame(a, b, t)


## Index of the last frame at or before a time (binary search)
func _find_frame(timestamp: float) -> int:
	var frames := recording.frames
	var low := 0
	var high := frames.size() - 1
	while low < high:
		var mid := (low + high + 1) / 2
		if frames[mid].timestamp <= timestamp:
			low = mid
		else:
			high = mid - 1
	return low


# =============================================================================
# CONTROLS
# =============================================================================

func play() -> void:
	if recording == null or state == PlaybackState.PLAYING:
		return
	# From the end (or from where a fatal run's replay stops): start again
	if current_timestamp >= get_visible_end() - 0.01:
		seek(get_start())
	state = PlaybackState.PLAYING
	playback_started.emit()


## Pause (not inside the fatal moments: they are one continuous take)
func pause() -> void:
	if state == PlaybackState.PLAYING and not in_fatal_section:
		_pause()


func toggle() -> void:
	if state == PlaybackState.PLAYING:
		pause()
	else:
		play()


func _pause() -> void:
	state = PlaybackState.PAUSED
	playback_paused.emit()


func _complete() -> void:
	if in_fatal_section:
		recording.metadata[FATAL_REPLAYED_KEY] = true
		in_fatal_section = false
		controls_changed.emit()
	state = PlaybackState.PAUSED
	playback_completed.emit()


## Move the replay to a moment. Never into a fatal run's fatal moments, and
## not at all while they are being shown.
func seek(timestamp: float) -> void:
	if recording == null or in_fatal_section:
		return
	current_timestamp = clampf(timestamp, get_start(), get_seek_end())
	_stop_at = INF
	_frame_index = _find_frame(current_timestamp)
	_show()
	timestamp_changed.emit(current_timestamp)


## Play a stretch of the run and stop at its end (a highlight)
func play_range(from: float, to: float) -> void:
	if recording == null or in_fatal_section:
		return
	seek(from)
	_stop_at = clampf(to, current_timestamp, get_seek_end())
	state = PlaybackState.PLAYING
	playback_started.emit()


func set_speed(speed: float) -> void:
	if not can_change_speed():
		return
	playback_speed = clampf(speed, SPEEDS[0], SPEEDS[SPEEDS.size() - 1])
	controls_changed.emit()


## The next speed up (round to the slowest after the fastest)
func cycle_speed() -> void:
	var index := SPEEDS.find(playback_speed)
	set_speed(SPEEDS[(index + 1) % SPEEDS.size()])


func set_camera_mode(mode: ReplayStage.CameraMode) -> void:
	if stage != null and can_change_camera():
		stage.set_camera_mode(mode)
		controls_changed.emit()


func cycle_camera() -> void:
	if stage != null:
		set_camera_mode(((int(stage.mode) + 1) % ReplayStage.CameraMode.size()) as ReplayStage.CameraMode)


# =============================================================================
# WHAT THE RULES ALLOW
# =============================================================================

## A fatal run is replayed at normal speed
func can_change_speed() -> bool:
	return recording != null and not is_fatal_run


## and from one fixed camera
func can_change_camera() -> bool:
	return recording != null and not is_fatal_run


## The replay can be wound to and fro (not inside the fatal moments)
func can_seek() -> bool:
	return recording != null and not in_fatal_section


func can_pause() -> bool:
	return recording != null and not in_fatal_section


func has_fatal_been_replayed() -> bool:
	return recording != null and bool(recording.metadata.get(FATAL_REPLAYED_KEY, false))


# =============================================================================
# QUERIES
# =============================================================================

func is_playing() -> bool:
	return state == PlaybackState.PLAYING


func get_start() -> float:
	return recording.frames[0].timestamp if recording != null and not recording.frames.is_empty() else 0.0


func get_end() -> float:
	return recording.frames[-1].timestamp if recording != null and not recording.frames.is_empty() else 0.0


func get_duration() -> float:
	return maxf(get_end() - get_start(), 0.0)


## The last moment the replay can be wound to: the end of the run, or, in a
## fatal run, the moment control was lost
func get_seek_end() -> float:
	return minf(get_end(), fatal_start) if is_fatal_run else get_end()


## The last moment this replay will show: the end of the run, or, once a
## fatal run's fatal moments have been shown, the moment control was lost
func get_visible_end() -> float:
	if is_fatal_run and has_fatal_been_replayed() and not in_fatal_section:
		return minf(get_end(), fatal_start)
	return get_end()


func get_summary() -> Dictionary:
	return {
		"state": PlaybackState.keys()[state],
		"timestamp": current_timestamp,
		"duration": get_duration(),
		"speed": playback_speed,
		"fatal_run": is_fatal_run,
		"in_fatal_section": in_fatal_section,
	}
