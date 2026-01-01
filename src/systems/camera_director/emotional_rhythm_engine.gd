class_name EmotionalRhythmEngine
extends Node
## Tracks emotional pacing and prevents camera fatigue
## Ensures the film has rhythm - tension, release, tension, release
##
## Design Philosophy:
## - High intensity can't be sustained forever
## - The audience needs time to breathe
## - Quiet moments make loud moments louder
## - Rhythm creates meaning

# =============================================================================
# SIGNALS
# =============================================================================

signal intensity_level_changed(level: IntensityLevel)
signal rhythm_beat(beat_type: String)
signal release_needed()
signal buildup_complete()

# =============================================================================
# ENUMS
# =============================================================================

enum IntensityLevel {
	QUIET,      # 0.0 - 0.2: Establishing, breathing room
	LOW,        # 0.2 - 0.4: Normal activity
	MEDIUM,     # 0.4 - 0.6: Heightened attention
	HIGH,       # 0.6 - 0.8: Critical moments
	PEAK        # 0.8 - 1.0: Fatal/climactic moments
}

enum RhythmPhase {
	BUILDUP,    # Tension increasing
	PLATEAU,    # Sustained intensity
	RELEASE,    # Tension decreasing
	REST        # Low intensity period
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Intensity")
## Intensity smoothing factor (lower = smoother)
@export var intensity_smoothing: float = 0.3
## Maximum time at peak intensity before forced release
@export var max_peak_duration: float = 10.0
## Maximum time at high intensity before needed release
@export var max_high_duration: float = 30.0
## Minimum rest duration after peak
@export var min_rest_after_peak: float = 5.0

@export_group("Rhythm")
## Target average intensity over time
@export var target_average_intensity: float = 0.4
## Intensity variance target (how much it should fluctuate)
@export var target_variance: float = 0.25
## Time window for rhythm analysis (seconds)
@export var rhythm_window: float = 60.0

@export_group("Beats")
## Time between rhythm evaluations
@export var beat_interval: float = 2.0

# =============================================================================
# STATE
# =============================================================================

## Current smoothed intensity
var current_intensity: float = 0.0

## Raw intensity from signal detector
var raw_intensity: float = 0.0

## Current intensity level
var intensity_level: IntensityLevel = IntensityLevel.QUIET

## Current rhythm phase
var rhythm_phase: RhythmPhase = RhythmPhase.REST

## Time in current intensity level
var time_in_level: float = 0.0

## Time in current rhythm phase
var time_in_phase: float = 0.0

## Time since last peak
var time_since_peak: float = 0.0

## Intensity history for rhythm analysis
var intensity_history: Array[float] = []

## Timestamp history
var timestamp_history: Array[float] = []

## Is release currently needed
var release_needed_flag: bool = false

## Is in forced rest period
var in_forced_rest: bool = false

## Beat timer
var beat_timer: float = 0.0

## Signal detector reference
var signal_detector: SignalDetector


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("EmotionalRhythmEngine", self)
	ServiceLocator.get_service_async("SignalDetector", func(s): signal_detector = s)
	print("[EmotionalRhythmEngine] Initialized")


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_intensity(delta)
	_update_level(delta)
	_update_rhythm_phase(delta)
	_update_beats(delta)
	_record_history()
	_check_constraints()


func _update_intensity(delta: float) -> void:
	# Get raw intensity from signal detector
	if signal_detector:
		raw_intensity = signal_detector.get_total_intensity()
	else:
		raw_intensity = 0.0

	# Apply forced rest if needed
	if in_forced_rest:
		raw_intensity *= 0.3

	# Smooth intensity
	current_intensity = lerpf(current_intensity, raw_intensity, intensity_smoothing * delta * 5.0)
	current_intensity = clampf(current_intensity, 0.0, 1.0)


func _update_level(delta: float) -> void:
	var new_level := _intensity_to_level(current_intensity)

	if new_level != intensity_level:
		var old_level := intensity_level
		intensity_level = new_level
		time_in_level = 0.0
		intensity_level_changed.emit(new_level)

		# Track peaks
		if new_level == IntensityLevel.PEAK:
			time_since_peak = 0.0
		elif old_level == IntensityLevel.PEAK:
			# Just exited peak
			in_forced_rest = true
	else:
		time_in_level += delta

	# Track time since peak
	if intensity_level != IntensityLevel.PEAK:
		time_since_peak += delta

	# Release forced rest after minimum duration
	if in_forced_rest and time_since_peak > min_rest_after_peak:
		in_forced_rest = false


func _update_rhythm_phase(delta: float) -> void:
	var new_phase := _determine_rhythm_phase()

	if new_phase != rhythm_phase:
		rhythm_phase = new_phase
		time_in_phase = 0.0
	else:
		time_in_phase += delta


func _update_beats(delta: float) -> void:
	beat_timer += delta

	if beat_timer >= beat_interval:
		beat_timer = 0.0
		_emit_rhythm_beat()


func _record_history() -> void:
	var current_time := Time.get_ticks_msec() / 1000.0

	intensity_history.append(current_intensity)
	timestamp_history.append(current_time)

	# Prune old history
	while timestamp_history.size() > 0 and timestamp_history[0] < current_time - rhythm_window:
		timestamp_history.pop_front()
		intensity_history.pop_front()


func _check_constraints() -> void:
	# Check if we've been at high intensity too long
	if intensity_level == IntensityLevel.HIGH and time_in_level > max_high_duration:
		release_needed_flag = true
		release_needed.emit()

	# Check if we've been at peak too long
	if intensity_level == IntensityLevel.PEAK and time_in_level > max_peak_duration:
		release_needed_flag = true
		in_forced_rest = true
		release_needed.emit()

	# Clear release flag when intensity drops
	if intensity_level in [IntensityLevel.QUIET, IntensityLevel.LOW]:
		release_needed_flag = false


# =============================================================================
# RHYTHM ANALYSIS
# =============================================================================

func _intensity_to_level(intensity: float) -> IntensityLevel:
	if intensity >= 0.8:
		return IntensityLevel.PEAK
	elif intensity >= 0.6:
		return IntensityLevel.HIGH
	elif intensity >= 0.4:
		return IntensityLevel.MEDIUM
	elif intensity >= 0.2:
		return IntensityLevel.LOW
	else:
		return IntensityLevel.QUIET


func _determine_rhythm_phase() -> RhythmPhase:
	if intensity_history.size() < 5:
		return RhythmPhase.REST

	# Get recent trend
	var recent_avg := _get_recent_average(5.0)
	var older_avg := _get_older_average(5.0, 15.0)

	var trend := recent_avg - older_avg

	if trend > 0.1:
		return RhythmPhase.BUILDUP
	elif trend < -0.1:
		return RhythmPhase.RELEASE
	elif current_intensity > 0.5:
		return RhythmPhase.PLATEAU
	else:
		return RhythmPhase.REST


func _get_recent_average(seconds: float) -> float:
	var current_time := Time.get_ticks_msec() / 1000.0
	var total := 0.0
	var count := 0

	for i in range(intensity_history.size() - 1, -1, -1):
		if current_time - timestamp_history[i] <= seconds:
			total += intensity_history[i]
			count += 1
		else:
			break

	return total / maxf(count, 1)


func _get_older_average(start_seconds: float, end_seconds: float) -> float:
	var current_time := Time.get_ticks_msec() / 1000.0
	var total := 0.0
	var count := 0

	for i in range(intensity_history.size()):
		var age := current_time - timestamp_history[i]
		if age >= start_seconds and age <= end_seconds:
			total += intensity_history[i]
			count += 1

	return total / maxf(count, 1)


func _emit_rhythm_beat() -> void:
	var beat_type := "neutral"

	match rhythm_phase:
		RhythmPhase.BUILDUP:
			beat_type = "tension_rising"
		RhythmPhase.PLATEAU:
			beat_type = "sustained"
		RhythmPhase.RELEASE:
			beat_type = "tension_falling"
		RhythmPhase.REST:
			beat_type = "rest"

	rhythm_beat.emit(beat_type)


# =============================================================================
# PACING RECOMMENDATIONS
# =============================================================================

## Get recommended shot duration based on current rhythm
func get_recommended_shot_duration() -> float:
	match intensity_level:
		IntensityLevel.PEAK:
			return 1.5  # Quick cuts during peak
		IntensityLevel.HIGH:
			return 3.0  # Faster pacing
		IntensityLevel.MEDIUM:
			return 5.0  # Normal pacing
		IntensityLevel.LOW:
			return 8.0  # Slower, contemplative
		IntensityLevel.QUIET:
			return 12.0  # Long, establishing shots
		_:
			return 5.0


## Get recommended camera movement speed
func get_recommended_camera_speed() -> float:
	match intensity_level:
		IntensityLevel.PEAK:
			return 1.2  # Slightly faster
		IntensityLevel.HIGH:
			return 1.0  # Normal
		IntensityLevel.MEDIUM:
			return 0.8
		IntensityLevel.LOW:
			return 0.5
		IntensityLevel.QUIET:
			return 0.3  # Very slow
		_:
			return 0.7


## Check if a cut (shot change) is recommended now
func is_cut_recommended() -> bool:
	# Cuts are good on rhythm transitions
	if time_in_phase < 0.5:
		return true

	# Cuts needed when intensity changes significantly
	if absf(raw_intensity - current_intensity) > 0.3:
		return true

	return false


## Check if current intensity allows for a dramatic moment
func can_support_dramatic_moment() -> bool:
	# Need some buildup before drama
	if time_since_peak < min_rest_after_peak:
		return false

	# Can't do drama if already at high intensity
	if intensity_level == IntensityLevel.PEAK:
		return false

	# Check we haven't been in sustained high intensity
	if intensity_level == IntensityLevel.HIGH and time_in_level > max_high_duration * 0.5:
		return false

	return true


## Get pacing adjustment factor
func get_pacing_factor() -> float:
	# Returns multiplier for shot timing/camera speed
	# > 1 = speed up, < 1 = slow down

	var avg := _get_recent_average(30.0)

	if avg > target_average_intensity + 0.1:
		# Too intense, need to slow down
		return 0.7
	elif avg < target_average_intensity - 0.1:
		# Too slow, can speed up
		return 1.3
	else:
		return 1.0


# =============================================================================
# QUERIES
# =============================================================================

func get_intensity() -> float:
	return current_intensity


func get_intensity_level() -> IntensityLevel:
	return intensity_level


func get_rhythm_phase() -> RhythmPhase:
	return rhythm_phase


func is_release_needed() -> bool:
	return release_needed_flag


func get_time_in_level() -> float:
	return time_in_level


func get_time_since_peak() -> float:
	return time_since_peak


func get_rhythm_variance() -> float:
	if intensity_history.size() < 10:
		return 0.0

	var avg := 0.0
	for val in intensity_history:
		avg += val
	avg /= intensity_history.size()

	var variance := 0.0
	for val in intensity_history:
		variance += pow(val - avg, 2)
	variance /= intensity_history.size()

	return sqrt(variance)


func get_summary() -> Dictionary:
	return {
		"intensity": current_intensity,
		"level": IntensityLevel.keys()[intensity_level],
		"phase": RhythmPhase.keys()[rhythm_phase],
		"time_in_level": time_in_level,
		"time_since_peak": time_since_peak,
		"release_needed": release_needed_flag,
		"recommended_shot_duration": get_recommended_shot_duration(),
		"pacing_factor": get_pacing_factor(),
		"variance": get_rhythm_variance()
	}
