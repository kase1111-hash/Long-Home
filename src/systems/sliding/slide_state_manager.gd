class_name SlideStateManager
extends Node
## Manages the control spectrum during slides
## Provides smooth transitions and UI/feedback coordination
##
## Control Spectrum:
## - CONTROLLED: Player can influence trajectory
## - MARGINAL: Corrections risky, but possible
## - UNSTABLE: Barely hanging on, corrections may worsen
## - LOST: Physics in control, pray for luck

# =============================================================================
# SIGNALS
# =============================================================================

signal control_spectrum_updated(spectrum: ControlSpectrum)
signal control_warning_started(level: GameEnums.SlideControlLevel)
signal control_warning_ended()
signal panic_threshold_crossed(is_panic: bool)
signal commitment_required(seconds_remaining: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

## Smoothing factor for control transitions
var control_smoothing: float = 3.0

## Time before control loss warning triggers
var warning_delay: float = 0.5

## Time in unstable before panic escalation
var panic_threshold: float = 2.0

## Decision window when commitment matters
var commitment_window: float = 3.0

# =============================================================================
# STATE
# =============================================================================

## Reference to slide system
var slide_system: SlideSystem

## Current smooth control value
var smooth_control: float = 1.0

## Previous frame control level
var previous_level: GameEnums.SlideControlLevel = GameEnums.SlideControlLevel.CONTROLLED

## Time in current control level
var time_in_level: float = 0.0

## Time in warning state
var warning_time: float = 0.0

## Is warning active
var is_warning_active: bool = false

## Time in panic state
var panic_time: float = 0.0

## Is in panic
var is_panicking: bool = false

## Commitment decision timer
var commitment_timer: float = 0.0

## Needs commitment decision
var needs_commitment: bool = false

## Control history for trend analysis
var control_history: Array[float] = []

## History sample interval
var history_interval: float = 0.1

## History timer
var history_timer: float = 0.0


# =============================================================================
# CONTROL SPECTRUM DATA
# =============================================================================

class ControlSpectrum:
	## Raw control value (0-1)
	var raw: float = 1.0
	## Smoothed control value (0-1)
	var smooth: float = 1.0
	## Control level enum
	var level: GameEnums.SlideControlLevel = GameEnums.SlideControlLevel.CONTROLLED
	## Time in this level
	var time_in_level: float = 0.0
	## Trend direction (-1 = worsening, 0 = stable, 1 = improving)
	var trend: int = 0
	## Trend magnitude (0-1)
	var trend_magnitude: float = 0.0
	## Is deteriorating rapidly
	var is_critical: bool = false
	## Percentage through current level toward next worse
	var level_progress: float = 0.0
	## Estimated time until level change
	var time_to_change: float = 10.0
	## Is in warning state
	var warning_active: bool = false
	## Is in panic state
	var panic_active: bool = false

	func get_level_name() -> String:
		return GameEnums.SlideControlLevel.keys()[level]


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(system: SlideSystem) -> void:
	slide_system = system


func _ready() -> void:
	# Connect to slide system signals
	slide_system.slide_started.connect(_on_slide_started)
	slide_system.slide_ended.connect(_on_slide_ended)
	slide_system.slide_control_changed.connect(_on_control_changed)


# =============================================================================
# UPDATE
# =============================================================================

func update(delta: float) -> void:
	if not slide_system.is_sliding:
		return

	var state := slide_system.current_state

	# Smooth control transition
	smooth_control = lerpf(smooth_control, state.control, control_smoothing * delta)

	# Update history
	_update_control_history(delta)

	# Track time in level
	if state.control_level == previous_level:
		time_in_level += delta
	else:
		time_in_level = 0.0
		previous_level = state.control_level

	# Check warning conditions
	_update_warning_state(state, delta)

	# Check panic conditions
	_update_panic_state(state, delta)

	# Check commitment window
	_update_commitment_state(state, delta)

	# Build and emit spectrum
	var spectrum := _build_spectrum(state)
	control_spectrum_updated.emit(spectrum)


func _update_control_history(delta: float) -> void:
	history_timer += delta
	if history_timer >= history_interval:
		history_timer = 0.0
		control_history.append(smooth_control)

		# Limit history size
		while control_history.size() > 50:
			control_history.pop_front()


func _update_warning_state(state: SlideSystem.SlideState, delta: float) -> void:
	# Warning when control drops below marginal
	var should_warn := state.control_level >= GameEnums.SlideControlLevel.MARGINAL

	if should_warn:
		warning_time += delta
		if warning_time > warning_delay and not is_warning_active:
			is_warning_active = true
			control_warning_started.emit(state.control_level)
	else:
		if is_warning_active:
			is_warning_active = false
			control_warning_ended.emit()
		warning_time = 0.0


func _update_panic_state(state: SlideSystem.SlideState, delta: float) -> void:
	# Panic when unstable for too long
	if state.control_level >= GameEnums.SlideControlLevel.UNSTABLE:
		panic_time += delta
		if panic_time > panic_threshold and not is_panicking:
			is_panicking = true
			panic_threshold_crossed.emit(true)
	else:
		if is_panicking:
			is_panicking = false
			panic_threshold_crossed.emit(false)
		panic_time = 0.0


func _update_commitment_state(state: SlideSystem.SlideState, delta: float) -> void:
	# Commitment required when approaching decision points
	var approaching_exit := state.exit_zone_distance < 30.0 and state.exit_zone_distance > 5.0
	var deteriorating := _get_trend() < -0.3

	if approaching_exit or deteriorating:
		if not needs_commitment:
			needs_commitment = true
			commitment_timer = commitment_window

		commitment_timer -= delta
		commitment_required.emit(commitment_timer)

		if commitment_timer <= 0.0:
			needs_commitment = false
	else:
		needs_commitment = false


func _build_spectrum(state: SlideSystem.SlideState) -> ControlSpectrum:
	var spectrum := ControlSpectrum.new()

	spectrum.raw = state.control
	spectrum.smooth = smooth_control
	spectrum.level = state.control_level
	spectrum.time_in_level = time_in_level
	spectrum.trend = _get_trend_direction()
	spectrum.trend_magnitude = absf(_get_trend())
	spectrum.is_critical = is_panicking or state.control < 0.15
	spectrum.level_progress = _calculate_level_progress(state.control)
	spectrum.time_to_change = _estimate_time_to_change()
	spectrum.warning_active = is_warning_active
	spectrum.panic_active = is_panicking

	return spectrum


# =============================================================================
# TREND ANALYSIS
# =============================================================================

func _get_trend() -> float:
	if control_history.size() < 5:
		return 0.0

	# Compare recent to older samples
	var recent_avg := 0.0
	var older_avg := 0.0

	var split := control_history.size() / 2
	for i in range(split):
		older_avg += control_history[i]
	older_avg /= split

	for i in range(split, control_history.size()):
		recent_avg += control_history[i]
	recent_avg /= (control_history.size() - split)

	return recent_avg - older_avg


func _get_trend_direction() -> int:
	var trend := _get_trend()
	if trend > 0.05:
		return 1  # Improving
	elif trend < -0.05:
		return -1  # Worsening
	else:
		return 0  # Stable


func _calculate_level_progress(control: float) -> float:
	# Calculate progress through current level toward next worse
	# Thresholds match GameEnums.get_slide_control_level
	if control >= 0.8:
		# Controlled: 0.8-1.0
		return (1.0 - control) / 0.2
	elif control >= 0.5:
		# Marginal: 0.5-0.8
		return (0.8 - control) / 0.3
	elif control >= 0.2:
		# Unstable: 0.2-0.5
		return (0.5 - control) / 0.3
	else:
		# Lost: 0-0.2
		return 1.0


func _estimate_time_to_change() -> float:
	var trend := _get_trend()
	if absf(trend) < 0.01:
		return 10.0  # Stable, long time

	var current := smooth_control
	var level := GameEnums.get_slide_control_level(current)

	# Find next threshold (matches GameEnums thresholds)
	var threshold := 0.0
	match level:
		GameEnums.SlideControlLevel.CONTROLLED:
			threshold = 0.8 if trend < 0 else 1.0
		GameEnums.SlideControlLevel.MARGINAL:
			threshold = 0.5 if trend < 0 else 0.8
		GameEnums.SlideControlLevel.UNSTABLE:
			threshold = 0.2 if trend < 0 else 0.5
		GameEnums.SlideControlLevel.LOST:
			threshold = 0.0 if trend < 0 else 0.2

	var distance := absf(current - threshold)
	var rate := absf(trend) / history_interval

	if rate < 0.001:
		return 10.0

	return distance / rate


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_slide_started(_entry_speed: float, _slope_angle: float) -> void:
	smooth_control = 1.0
	previous_level = GameEnums.SlideControlLevel.CONTROLLED
	time_in_level = 0.0
	warning_time = 0.0
	is_warning_active = false
	panic_time = 0.0
	is_panicking = false
	commitment_timer = 0.0
	needs_commitment = false
	control_history.clear()


func _on_slide_ended(_outcome: GameEnums.SlideOutcome, _final_speed: float) -> void:
	if is_warning_active:
		is_warning_active = false
		control_warning_ended.emit()

	if is_panicking:
		is_panicking = false
		panic_threshold_crossed.emit(false)


func _on_control_changed(old_level: GameEnums.SlideControlLevel, new_level: GameEnums.SlideControlLevel) -> void:
	time_in_level = 0.0
	previous_level = new_level


# =============================================================================
# QUERIES
# =============================================================================

## Get current control as color (for UI feedback)
func get_control_color() -> Color:
	var level := slide_system.current_state.control_level
	match level:
		GameEnums.SlideControlLevel.CONTROLLED:
			return Color.GREEN
		GameEnums.SlideControlLevel.MARGINAL:
			return Color.YELLOW
		GameEnums.SlideControlLevel.UNSTABLE:
			return Color.ORANGE
		GameEnums.SlideControlLevel.LOST:
			return Color.RED
		_:
			return Color.WHITE


## Get urgency level for UI/audio (0-1)
func get_urgency() -> float:
	var base := 1.0 - smooth_control

	# Add for panic
	if is_panicking:
		base = minf(base + 0.3, 1.0)

	# Add for commitment pressure
	if needs_commitment and commitment_timer < 1.0:
		base = minf(base + 0.2, 1.0)

	return base


## Check if feedback should intensify
func should_intensify_feedback() -> bool:
	return is_warning_active or is_panicking or (needs_commitment and commitment_timer < 2.0)


## Get control level description for diegetic display
func get_control_description() -> String:
	match slide_system.current_state.control_level:
		GameEnums.SlideControlLevel.CONTROLLED:
			return "In control"
		GameEnums.SlideControlLevel.MARGINAL:
			return "Barely holding"
		GameEnums.SlideControlLevel.UNSTABLE:
			return "Losing it"
		GameEnums.SlideControlLevel.LOST:
			return "Gone"
		_:
			return ""
