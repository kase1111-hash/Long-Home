class_name RiskFeedback
extends Node
## Provides diegetic feedback for risk levels
## Maps risk to audio, visual, and haptic cues
##
## Design Philosophy:
## - No HUD risk meters
## - Risk is felt through environmental changes
## - Players learn to read subtle cues
## - Feedback intensity scales with risk

# =============================================================================
# SIGNALS
# =============================================================================

signal breathing_intensity_changed(intensity: float)
signal heartbeat_started(rate: float)
signal heartbeat_stopped()
signal camera_shake_requested(intensity: float)
signal peripheral_blur_requested(intensity: float)
signal audio_dampen_requested(amount: float)
signal micro_slip_triggered(severity: float)
signal haptic_pulse_requested(intensity: float, duration: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Thresholds")
## Risk level for breathing changes
@export var breathing_threshold: float = 0.3
## Risk level for heartbeat
@export var heartbeat_threshold: float = 0.5
## Risk level for camera instability
@export var camera_shake_threshold: float = 0.6
## Risk level for peripheral blur
@export var blur_threshold: float = 0.8
## Risk level for audio dampening
@export var audio_dampen_threshold: float = 0.7

@export_group("Micro-Slips")
## Minimum risk for micro-slips
@export var micro_slip_threshold: float = 0.4
## Base micro-slip interval (seconds)
@export var micro_slip_interval: float = 5.0
## Minimum interval at high risk
@export var micro_slip_min_interval: float = 1.0

@export_group("Feedback Intensity")
## Maximum breathing intensity
@export var max_breathing: float = 1.0
## Maximum camera shake
@export var max_camera_shake: float = 0.5
## Maximum blur intensity
@export var max_blur: float = 0.6

# =============================================================================
# STATE
# =============================================================================

## Current risk level
var current_risk: float = 0.0

## Current breathing intensity
var breathing_intensity: float = 0.0

## Is heartbeat active
var heartbeat_active: bool = false

## Current heartbeat rate
var heartbeat_rate: float = 60.0

## Camera shake intensity
var camera_shake: float = 0.0

## Peripheral blur intensity
var blur_intensity: float = 0.0

## Audio dampen amount
var audio_dampen: float = 0.0

## Micro-slip timer
var micro_slip_timer: float = 0.0

## Next micro-slip time
var next_micro_slip: float = 5.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("RiskFeedback", self)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_breathing(delta)
	_update_heartbeat(delta)
	_update_camera_shake(delta)
	_update_blur(delta)
	_update_audio_dampen(delta)
	_check_micro_slip(delta)


func _update_breathing(delta: float) -> void:
	var target := 0.0

	if current_risk > breathing_threshold:
		var intensity := (current_risk - breathing_threshold) / (1.0 - breathing_threshold)
		target = intensity * max_breathing

	breathing_intensity = lerpf(breathing_intensity, target, delta * 3.0)
	breathing_intensity_changed.emit(breathing_intensity)


func _update_heartbeat(delta: float) -> void:
	var should_beat := current_risk > heartbeat_threshold

	if should_beat != heartbeat_active:
		heartbeat_active = should_beat
		if heartbeat_active:
			heartbeat_rate = _calculate_heartbeat_rate()
			heartbeat_started.emit(heartbeat_rate)
		else:
			heartbeat_stopped.emit()

	# Update rate if active
	if heartbeat_active:
		var new_rate := _calculate_heartbeat_rate()
		if absf(new_rate - heartbeat_rate) > 10:
			heartbeat_rate = new_rate
			heartbeat_started.emit(heartbeat_rate)


func _calculate_heartbeat_rate() -> float:
	# 70 bpm at threshold, up to 180 at max risk
	var intensity := (current_risk - heartbeat_threshold) / (1.0 - heartbeat_threshold)
	return 70.0 + intensity * 110.0


func _update_camera_shake(delta: float) -> void:
	var target := 0.0

	if current_risk > camera_shake_threshold:
		var intensity := (current_risk - camera_shake_threshold) / (1.0 - camera_shake_threshold)
		target = intensity * max_camera_shake

	camera_shake = lerpf(camera_shake, target, delta * 2.0)
	camera_shake_requested.emit(camera_shake)


func _update_blur(delta: float) -> void:
	var target := 0.0

	if current_risk > blur_threshold:
		var intensity := (current_risk - blur_threshold) / (1.0 - blur_threshold)
		target = intensity * max_blur

	blur_intensity = lerpf(blur_intensity, target, delta * 2.0)
	peripheral_blur_requested.emit(blur_intensity)


func _update_audio_dampen(delta: float) -> void:
	var target := 0.0

	if current_risk > audio_dampen_threshold:
		var intensity := (current_risk - audio_dampen_threshold) / (1.0 - audio_dampen_threshold)
		# Dampen environmental audio as internal focus increases
		target = intensity * 0.5

	audio_dampen = lerpf(audio_dampen, target, delta * 3.0)
	audio_dampen_requested.emit(audio_dampen)


func _check_micro_slip(delta: float) -> void:
	if current_risk < micro_slip_threshold:
		micro_slip_timer = 0.0
		return

	micro_slip_timer += delta

	# Calculate interval based on risk
	var risk_factor := (current_risk - micro_slip_threshold) / (1.0 - micro_slip_threshold)
	next_micro_slip = lerpf(micro_slip_interval, micro_slip_min_interval, risk_factor)

	if micro_slip_timer >= next_micro_slip:
		micro_slip_timer = 0.0
		var severity := risk_factor * 0.5 + randf() * 0.3
		micro_slip_triggered.emit(severity)
		haptic_pulse_requested.emit(severity * 0.5, 0.1)


# =============================================================================
# INPUT
# =============================================================================

## Set current risk level
func set_risk_level(risk: float) -> void:
	current_risk = clampf(risk, 0.0, 1.0)


## Apply sudden risk spike (for near misses, etc.)
func apply_risk_spike(intensity: float, duration: float) -> void:
	# Temporarily boost all effects
	camera_shake_requested.emit(intensity)
	haptic_pulse_requested.emit(intensity, duration)

	if intensity > 0.5:
		micro_slip_triggered.emit(intensity)


## Trigger near miss feedback
func trigger_near_miss() -> void:
	apply_risk_spike(0.7, 0.3)

	# Brief heartbeat spike
	if not heartbeat_active:
		heartbeat_started.emit(120.0)
		await get_tree().create_timer(0.5).timeout
		if not heartbeat_active:
			heartbeat_stopped.emit()


## Trigger fall feedback
func trigger_fall_feedback(severity: int) -> void:
	var intensity := 0.3 + severity * 0.15
	camera_shake_requested.emit(intensity)
	haptic_pulse_requested.emit(intensity, 0.5)


# =============================================================================
# QUERIES
# =============================================================================

## Get current feedback state
func get_feedback_state() -> Dictionary:
	return {
		"risk": current_risk,
		"breathing": breathing_intensity,
		"heartbeat_active": heartbeat_active,
		"heartbeat_rate": heartbeat_rate if heartbeat_active else 0,
		"camera_shake": camera_shake,
		"blur": blur_intensity,
		"audio_dampen": audio_dampen
	}


## Get overall feedback intensity (for external systems)
func get_overall_intensity() -> float:
	return maxf(breathing_intensity, maxf(camera_shake, blur_intensity))


## Check if any feedback is active
func is_feedback_active() -> bool:
	return breathing_intensity > 0.1 or heartbeat_active or camera_shake > 0.05
