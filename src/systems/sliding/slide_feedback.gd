class_name SlideFeedback
extends Node
## Audio and visual feedback hooks for sliding system
## Coordinates with EventBus and Camera Director

# =============================================================================
# SIGNALS
# =============================================================================

signal camera_effect_requested(effect: CameraEffect)
signal audio_event_requested(event: AudioEvent)
signal haptic_requested(intensity: float, duration: float)
signal visual_effect_requested(effect: VisualEffect)

# =============================================================================
# CONFIGURATION
# =============================================================================

## Base camera shake during slide
var base_camera_shake: float = 0.1

## Speed multiplier for camera shake
var speed_shake_scale: float = 0.02

## Control loss shake multiplier
var control_loss_shake_scale: float = 0.3

## FOV change with speed
var fov_speed_scale: float = 0.5

## Max FOV bonus at terminal speed
var max_fov_bonus: float = 15.0

## Wind audio pitch scaling with speed
var wind_pitch_scale: float = 0.05

## Heartbeat threshold (control level)
var heartbeat_threshold: float = 0.5

# =============================================================================
# STATE
# =============================================================================

## Reference to slide system
var slide_system: SlideSystem

## Reference to state manager
var state_manager: SlideStateManager

## Current shake intensity
var current_shake: float = 0.0

## Is heartbeat playing
var heartbeat_active: bool = false

## Wind audio intensity
var wind_intensity: float = 0.0

## Edge sound intensity
var edge_sound_intensity: float = 0.0

## Tunnel vision intensity
var tunnel_vision: float = 0.0


# =============================================================================
# EFFECT DATA CLASSES
# =============================================================================

class CameraEffect:
	var type: String = ""  # "shake", "fov", "tilt", "blur"
	var intensity: float = 0.0
	var duration: float = 0.0
	var data: Dictionary = {}


class AudioEvent:
	var type: String = ""  # "wind", "edge", "heartbeat", "impact", "warning"
	var intensity: float = 0.0
	var pitch: float = 1.0
	var position: Vector3 = Vector3.ZERO
	var data: Dictionary = {}


class VisualEffect:
	var type: String = ""  # "motion_blur", "tunnel_vision", "grain", "flash"
	var intensity: float = 0.0
	var duration: float = 0.0
	var data: Dictionary = {}


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(system: SlideSystem, manager: SlideStateManager) -> void:
	slide_system = system
	state_manager = manager


func _ready() -> void:
	# Connect to slide system
	slide_system.slide_started.connect(_on_slide_started)
	slide_system.slide_ended.connect(_on_slide_ended)
	slide_system.slide_updated.connect(_on_slide_updated)
	slide_system.terminal_velocity_warning.connect(_on_terminal_warning)
	slide_system.point_of_no_return.connect(_on_point_of_no_return)
	slide_system.slide_control_changed.connect(_on_control_changed)

	# Connect to state manager
	state_manager.control_warning_started.connect(_on_control_warning_started)
	state_manager.control_warning_ended.connect(_on_control_warning_ended)
	state_manager.panic_threshold_crossed.connect(_on_panic_changed)

	# Connect to exit detector
	slide_system.exit_detector.exit_zone_entered.connect(_on_exit_zone_entered)
	slide_system.exit_detector.exit_zone_missed.connect(_on_exit_zone_missed)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not slide_system.is_sliding:
		_fade_effects(delta)
		return

	_update_continuous_effects(delta)
	_emit_continuous_audio()


func _update_continuous_effects(delta: float) -> void:
	var state := slide_system.current_state

	# Camera shake - base + speed + control loss
	var target_shake := base_camera_shake
	target_shake += state.speed * speed_shake_scale
	target_shake += (1.0 - state.control) * control_loss_shake_scale
	current_shake = lerpf(current_shake, target_shake, 5.0 * delta)

	# Emit shake
	var shake_effect := CameraEffect.new()
	shake_effect.type = "shake"
	shake_effect.intensity = current_shake
	camera_effect_requested.emit(shake_effect)

	# FOV - widens with speed
	var fov_bonus := (state.speed / slide_system.terminal_speed) * max_fov_bonus
	var fov_effect := CameraEffect.new()
	fov_effect.type = "fov"
	fov_effect.intensity = fov_bonus
	camera_effect_requested.emit(fov_effect)

	# Camera tilt - follows lean and slope
	var tilt := slide_system.controller.get_lean() * 5.0  # Degrees
	tilt += sin(slide_time_wobble()) * 2.0 * (1.0 - state.control)  # Instability wobble
	var tilt_effect := CameraEffect.new()
	tilt_effect.type = "tilt"
	tilt_effect.intensity = tilt
	camera_effect_requested.emit(tilt_effect)

	# Wind audio
	wind_intensity = lerpf(wind_intensity, state.speed / slide_system.terminal_speed, 3.0 * delta)

	# Edge sound (scratching/carving)
	var edge := slide_system.controller.get_edge_level()
	edge_sound_intensity = lerpf(edge_sound_intensity, edge, 4.0 * delta)

	# Tunnel vision at high speed/low control
	var target_tunnel := 0.0
	if state.speed > slide_system.critical_speed:
		target_tunnel = 0.3
	if state.control < 0.3:
		target_tunnel = maxf(target_tunnel, 0.4)
	tunnel_vision = lerpf(tunnel_vision, target_tunnel, 2.0 * delta)

	if tunnel_vision > 0.01:
		var tunnel_effect := VisualEffect.new()
		tunnel_effect.type = "tunnel_vision"
		tunnel_effect.intensity = tunnel_vision
		visual_effect_requested.emit(tunnel_effect)

	# Motion blur
	var blur_intensity := state.speed / slide_system.terminal_speed * 0.5
	var blur_effect := VisualEffect.new()
	blur_effect.type = "motion_blur"
	blur_effect.intensity = blur_intensity
	visual_effect_requested.emit(blur_effect)

	# Heartbeat at low control
	if state.control < heartbeat_threshold and not heartbeat_active:
		heartbeat_active = true
		_start_heartbeat()
	elif state.control >= heartbeat_threshold and heartbeat_active:
		heartbeat_active = false
		_stop_heartbeat()


func slide_time_wobble() -> float:
	return slide_system.slide_time * 3.0 + sin(slide_system.slide_time * 7.0) * 0.5


func _emit_continuous_audio() -> void:
	# Wind
	if wind_intensity > 0.01:
		var wind := AudioEvent.new()
		wind.type = "wind"
		wind.intensity = wind_intensity
		wind.pitch = 1.0 + wind_intensity * wind_pitch_scale
		audio_event_requested.emit(wind)

	# Edge scraping
	if edge_sound_intensity > 0.01:
		var edge := AudioEvent.new()
		edge.type = "edge"
		edge.intensity = edge_sound_intensity
		edge.data["surface"] = slide_system.current_state.surface_type
		audio_event_requested.emit(edge)


func _fade_effects(delta: float) -> void:
	current_shake = lerpf(current_shake, 0.0, 5.0 * delta)
	wind_intensity = lerpf(wind_intensity, 0.0, 3.0 * delta)
	edge_sound_intensity = lerpf(edge_sound_intensity, 0.0, 4.0 * delta)
	tunnel_vision = lerpf(tunnel_vision, 0.0, 2.0 * delta)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	# Impact sound on slide start
	var impact := AudioEvent.new()
	impact.type = "impact"
	impact.intensity = clampf(entry_speed / 10.0, 0.2, 1.0)
	impact.data["slope"] = slope_angle
	audio_event_requested.emit(impact)

	# Camera jolt
	var jolt := CameraEffect.new()
	jolt.type = "shake"
	jolt.intensity = 0.5
	jolt.duration = 0.2
	camera_effect_requested.emit(jolt)

	# Signal to event bus
	EventBus.emit_camera_signal(GameEnums.CameraSignal.DESCENT_START, 0.0)


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	# Stop heartbeat
	if heartbeat_active:
		heartbeat_active = false
		_stop_heartbeat()

	# End audio
	var wind_stop := AudioEvent.new()
	wind_stop.type = "wind"
	wind_stop.intensity = 0.0
	audio_event_requested.emit(wind_stop)

	# Outcome-specific effects
	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			_emit_clean_stop_effects()

		GameEnums.SlideOutcome.TUMBLE_STOP:
			_emit_tumble_effects(final_speed)

		GameEnums.SlideOutcome.TERRAIN_CATCH:
			_emit_terrain_catch_effects()

		GameEnums.SlideOutcome.TERMINAL_RUNOUT:
			_emit_terminal_effects(final_speed)

	# Reset visual effects
	var reset_tunnel := VisualEffect.new()
	reset_tunnel.type = "tunnel_vision"
	reset_tunnel.intensity = 0.0
	reset_tunnel.duration = 0.5
	visual_effect_requested.emit(reset_tunnel)


func _on_slide_updated(state: SlideSystem.SlideState) -> void:
	# Notify camera of state for director AI
	EventBus.emit_camera_signal(
		GameEnums.CameraSignal.SPEED_CHANGE,
		state.speed / slide_system.terminal_speed
	)

	# Cliff proximity warning
	if state.cliff_distance < 20.0:
		EventBus.cliff_proximity_changed.emit(state.cliff_distance)


func _on_terminal_warning() -> void:
	# Alarm sound
	var alarm := AudioEvent.new()
	alarm.type = "warning"
	alarm.intensity = 1.0
	alarm.data["warning_type"] = "terminal"
	audio_event_requested.emit(alarm)

	# Screen flash
	var flash := VisualEffect.new()
	flash.type = "flash"
	flash.intensity = 0.3
	flash.duration = 0.1
	flash.data["color"] = Color.RED
	visual_effect_requested.emit(flash)

	# Intense shake
	var shake := CameraEffect.new()
	shake.type = "shake"
	shake.intensity = 0.8
	shake.duration = 0.3
	camera_effect_requested.emit(shake)

	# Haptic
	haptic_requested.emit(0.8, 0.3)


func _on_point_of_no_return() -> void:
	# Ominous sound
	var ominous := AudioEvent.new()
	ominous.type = "warning"
	ominous.intensity = 0.7
	ominous.data["warning_type"] = "point_of_no_return"
	audio_event_requested.emit(ominous)

	# Brief time slow (signal only)
	EventBus.emit_camera_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 1.0)


func _on_control_changed(old_level: GameEnums.SlideControlLevel, new_level: GameEnums.SlideControlLevel) -> void:
	# Control deterioration sound
	if new_level > old_level:  # Higher = worse
		var deteriorate := AudioEvent.new()
		deteriorate.type = "warning"
		deteriorate.intensity = 0.4 + float(new_level) * 0.2
		deteriorate.data["warning_type"] = "control_loss"
		audio_event_requested.emit(deteriorate)

		# Haptic pulse
		haptic_requested.emit(0.3 + float(new_level) * 0.2, 0.15)


func _on_control_warning_started(level: GameEnums.SlideControlLevel) -> void:
	# Sustained warning tone
	var warning := AudioEvent.new()
	warning.type = "warning"
	warning.intensity = 0.5
	warning.data["warning_type"] = "sustained"
	warning.data["level"] = level
	audio_event_requested.emit(warning)


func _on_control_warning_ended() -> void:
	# Stop warning tone
	var warning := AudioEvent.new()
	warning.type = "warning"
	warning.intensity = 0.0
	audio_event_requested.emit(warning)


func _on_panic_changed(is_panic: bool) -> void:
	if is_panic:
		# Increase heartbeat rate
		var heartbeat := AudioEvent.new()
		heartbeat.type = "heartbeat"
		heartbeat.intensity = 1.0
		heartbeat.data["rate"] = "fast"
		audio_event_requested.emit(heartbeat)

		# Heavy grain
		var grain := VisualEffect.new()
		grain.type = "grain"
		grain.intensity = 0.4
		visual_effect_requested.emit(grain)
	else:
		# Normal heartbeat
		var heartbeat := AudioEvent.new()
		heartbeat.type = "heartbeat"
		heartbeat.intensity = 0.5
		heartbeat.data["rate"] = "normal"
		audio_event_requested.emit(heartbeat)

		# Remove grain
		var grain := VisualEffect.new()
		grain.type = "grain"
		grain.intensity = 0.0
		grain.duration = 0.5
		visual_effect_requested.emit(grain)


func _on_exit_zone_entered(zone: ExitZoneDetector.ExitZone) -> void:
	# Relief/opportunity sound
	var relief := AudioEvent.new()
	relief.type = "opportunity"
	relief.intensity = zone.quality
	audio_event_requested.emit(relief)


func _on_exit_zone_missed(zone: ExitZoneDetector.ExitZone) -> void:
	# Regret/dread sound
	var dread := AudioEvent.new()
	dread.type = "warning"
	dread.intensity = 0.6
	dread.data["warning_type"] = "missed_exit"
	audio_event_requested.emit(dread)


# =============================================================================
# SPECIFIC EFFECT EMISSIONS
# =============================================================================

func _emit_clean_stop_effects() -> void:
	# Relief sound
	var relief := AudioEvent.new()
	relief.type = "stop"
	relief.intensity = 0.5
	relief.data["clean"] = true
	audio_event_requested.emit(relief)


func _emit_tumble_effects(speed: float) -> void:
	# Impact sounds
	var impact := AudioEvent.new()
	impact.type = "impact"
	impact.intensity = clampf(speed / 15.0, 0.3, 1.0)
	impact.data["tumble"] = true
	audio_event_requested.emit(impact)

	# Intense shake
	var shake := CameraEffect.new()
	shake.type = "shake"
	shake.intensity = 0.7
	shake.duration = 0.5
	camera_effect_requested.emit(shake)

	# Flash
	var flash := VisualEffect.new()
	flash.type = "flash"
	flash.intensity = 0.5
	flash.duration = 0.15
	visual_effect_requested.emit(flash)

	# Haptic
	haptic_requested.emit(0.6, 0.4)


func _emit_terrain_catch_effects() -> void:
	# Scraping/catching sound
	var catch := AudioEvent.new()
	catch.type = "impact"
	catch.intensity = 0.6
	catch.data["terrain_catch"] = true
	audio_event_requested.emit(catch)

	# Moderate shake
	var shake := CameraEffect.new()
	shake.type = "shake"
	shake.intensity = 0.4
	shake.duration = 0.3
	camera_effect_requested.emit(shake)


func _emit_terminal_effects(speed: float) -> void:
	# Catastrophic impact
	var impact := AudioEvent.new()
	impact.type = "impact"
	impact.intensity = 1.0
	impact.data["terminal"] = true
	audio_event_requested.emit(impact)

	# Maximum shake
	var shake := CameraEffect.new()
	shake.type = "shake"
	shake.intensity = 1.0
	shake.duration = 1.0
	camera_effect_requested.emit(shake)

	# White flash
	var flash := VisualEffect.new()
	flash.type = "flash"
	flash.intensity = 1.0
	flash.duration = 0.3
	flash.data["color"] = Color.WHITE
	visual_effect_requested.emit(flash)

	# Maximum haptic
	haptic_requested.emit(1.0, 0.5)

	# Signal fatal moment
	EventBus.emit_camera_signal(GameEnums.CameraSignal.FATAL_MOMENT, 1.0)


func _start_heartbeat() -> void:
	var heartbeat := AudioEvent.new()
	heartbeat.type = "heartbeat"
	heartbeat.intensity = 0.5
	heartbeat.data["start"] = true
	audio_event_requested.emit(heartbeat)


func _stop_heartbeat() -> void:
	var heartbeat := AudioEvent.new()
	heartbeat.type = "heartbeat"
	heartbeat.intensity = 0.0
	heartbeat.data["stop"] = true
	audio_event_requested.emit(heartbeat)


# =============================================================================
# QUERIES
# =============================================================================

## Get current feedback intensity for external systems
func get_feedback_intensity() -> float:
	return maxf(current_shake, maxf(wind_intensity, tunnel_vision))


## Check if in high-feedback state
func is_intense() -> bool:
	return get_feedback_intensity() > 0.5 or heartbeat_active
