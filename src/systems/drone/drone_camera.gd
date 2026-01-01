class_name DroneCamera
extends Camera3D
## Cinematic camera attached to drone
## Provides documentary-style footage with imperfections
##
## Design Philosophy:
## - Camera has character - it's not a perfect tracking shot
## - Signal degradation affects visual quality
## - Wind causes shake, cold affects exposure
## - Different shot intents change camera behavior

# =============================================================================
# SIGNALS
# =============================================================================

signal shot_framed(subject_in_frame: bool)
signal focus_changed(focus_distance: float)
signal exposure_changed(exposure: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Lens")
## Default field of view
@export var default_fov: float = 60.0
## Wide shot FOV
@export var wide_fov: float = 85.0
## Tight/close shot FOV
@export var tight_fov: float = 35.0
## FOV transition speed
@export var fov_lerp_speed: float = 2.0

@export_group("Movement")
## Smoothing for camera rotation
@export var rotation_smoothing: float = 3.0
## Smoothing for position
@export var position_smoothing: float = 5.0
## Look-ahead when tracking movement
@export var look_ahead_factor: float = 0.5

@export_group("Shake")
## Base shake from drone motors
@export var base_shake: float = 0.005
## Wind shake multiplier
@export var wind_shake_multiplier: float = 0.02
## Movement shake multiplier
@export var movement_shake_multiplier: float = 0.01

@export_group("Signal Effects")
## Enable signal degradation effects
@export var signal_effects_enabled: bool = true
## Noise intensity at zero signal
@export var max_noise_intensity: float = 0.3
## Dropout probability at low signal
@export var dropout_chance: float = 0.1

# =============================================================================
# STATE
# =============================================================================

## Current target to track
var target: Node3D

## Current shot intent
var shot_intent: GameEnums.ShotIntent = GameEnums.ShotIntent.CONTEXT

## Target FOV based on intent
var target_fov: float = 60.0

## Current shake offset
var shake_offset: Vector3 = Vector3.ZERO

## Shake time accumulator
var shake_time: float = 0.0

## Is subject currently in frame
var subject_in_frame: bool = true

## Current signal strength (affects quality)
var signal_strength: float = 1.0

## Is experiencing signal dropout
var in_dropout: bool = false

## Dropout timer
var dropout_timer: float = 0.0

## Current wind strength
var wind_strength: float = 0.0

## Parent drone entity
var drone: DroneEntity

## Target rotation (for smoothing)
var target_rotation: Quaternion = Quaternion.IDENTITY

## Look-ahead position offset
var look_ahead_offset: Vector3 = Vector3.ZERO

## Last subject velocity (for prediction)
var last_subject_velocity: Vector3 = Vector3.ZERO


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	fov = default_fov
	target_fov = default_fov

	# Get parent drone
	var parent := get_parent()
	if parent is DroneEntity:
		drone = parent


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_shake(delta)
	_update_tracking(delta)
	_update_fov(delta)
	_update_signal_effects(delta)


func _update_shake(delta: float) -> void:
	shake_time += delta

	# Base motor vibration
	var shake_intensity := base_shake

	# Wind adds shake
	shake_intensity += wind_strength * wind_shake_multiplier

	# Movement adds shake
	if drone:
		var speed := drone.velocity.length()
		shake_intensity += speed * movement_shake_multiplier * 0.01

	# Calculate shake offset
	shake_offset = Vector3(
		sin(shake_time * 23.0) * shake_intensity,
		sin(shake_time * 17.0) * shake_intensity * 0.7,
		sin(shake_time * 31.0) * shake_intensity * 0.3
	)

	# Apply as rotation offset (subtle)
	rotation.x += shake_offset.x
	rotation.y += shake_offset.y


func _update_tracking(delta: float) -> void:
	if target == null:
		return

	# Predict subject position
	var target_pos := target.global_position

	# Add look-ahead based on velocity
	if target is CharacterBody3D:
		var body := target as CharacterBody3D
		look_ahead_offset = look_ahead_offset.lerp(
			body.velocity * look_ahead_factor,
			2.0 * delta
		)
		target_pos += look_ahead_offset

	# Calculate target rotation
	var direction := (target_pos - global_position).normalized()
	if direction.length() > 0.01:
		target_rotation = Quaternion(global_transform.basis.looking_at(direction, Vector3.UP))

	# Smooth rotation
	var current_quat := Quaternion(global_transform.basis)
	var new_quat := current_quat.slerp(target_rotation, rotation_smoothing * delta)
	global_transform.basis = Basis(new_quat)

	# Check if subject is in frame
	_check_framing()


func _check_framing() -> void:
	if target == null:
		subject_in_frame = false
		return

	# Project subject position to screen
	var screen_pos := unproject_position(target.global_position)
	var viewport_size := get_viewport().get_visible_rect().size

	# Check if in center area (with margin)
	var margin := 0.2
	var in_x := screen_pos.x > viewport_size.x * margin and screen_pos.x < viewport_size.x * (1.0 - margin)
	var in_y := screen_pos.y > viewport_size.y * margin and screen_pos.y < viewport_size.y * (1.0 - margin)

	var was_in_frame := subject_in_frame
	subject_in_frame = in_x and in_y

	if was_in_frame != subject_in_frame:
		shot_framed.emit(subject_in_frame)


func _update_fov(delta: float) -> void:
	fov = lerpf(fov, target_fov, fov_lerp_speed * delta)


func _update_signal_effects(delta: float) -> void:
	if not signal_effects_enabled:
		return

	# Handle signal dropouts
	if in_dropout:
		dropout_timer -= delta
		if dropout_timer <= 0:
			in_dropout = false
	else:
		# Check for new dropout
		if signal_strength < 0.5:
			var dropout_prob := dropout_chance * (1.0 - signal_strength) * delta
			if randf() < dropout_prob:
				in_dropout = true
				dropout_timer = randf_range(0.1, 0.5)


# =============================================================================
# SHOT INTENT
# =============================================================================

## Set current shot intent (from Camera Director)
func set_shot_intent(intent: GameEnums.ShotIntent) -> void:
	var old_intent := shot_intent
	shot_intent = intent

	# Adjust camera parameters based on intent
	match intent:
		GameEnums.ShotIntent.CONTEXT:
			# Wide shot, show environment
			target_fov = wide_fov
			rotation_smoothing = 2.0  # Slower, more stable

		GameEnums.ShotIntent.TENSION:
			# Medium shot, stay close
			target_fov = default_fov
			rotation_smoothing = 3.0

		GameEnums.ShotIntent.COMMITMENT:
			# Close, forward-tracking
			target_fov = tight_fov
			rotation_smoothing = 4.0  # Tighter tracking

		GameEnums.ShotIntent.CONSEQUENCE:
			# Hold shot, let it play out
			target_fov = default_fov
			rotation_smoothing = 1.5  # Slower response

		GameEnums.ShotIntent.RELEASE:
			# Pull back, breathe
			target_fov = wide_fov
			rotation_smoothing = 1.0  # Very slow

	EventBus.shot_intent_changed.emit(old_intent, intent)


## Get framing offset for current intent
func get_intent_offset() -> Vector3:
	match shot_intent:
		GameEnums.ShotIntent.CONTEXT:
			return Vector3(0, 5, 15)  # High and far
		GameEnums.ShotIntent.TENSION:
			return Vector3(2, 2, 8)  # Medium distance, slight offset
		GameEnums.ShotIntent.COMMITMENT:
			return Vector3(1, 1, 4)  # Close, forward
		GameEnums.ShotIntent.CONSEQUENCE:
			return Vector3(0, 3, 10)  # Neutral, medium
		GameEnums.ShotIntent.RELEASE:
			return Vector3(0, 8, 20)  # High and very far
		_:
			return Vector3(0, 3, 10)


# =============================================================================
# CONTROL
# =============================================================================

## Set the target to track
func set_target(new_target: Node3D) -> void:
	target = new_target


## Look at a specific position
func look_at_position(pos: Vector3) -> void:
	var direction := (pos - global_position).normalized()
	if direction.length() > 0.01:
		look_at(pos, Vector3.UP)


## Set signal strength (affects visual quality)
func set_signal_strength(strength: float) -> void:
	signal_strength = clampf(strength, 0.0, 1.0)


## Set wind strength (affects shake)
func set_wind_strength(strength: float) -> void:
	wind_strength = clampf(strength, 0.0, 1.0)


# =============================================================================
# CINEMATIC HELPERS
# =============================================================================

## Anticipate subject movement (look where they're going)
func anticipate_movement(velocity: Vector3, anticipation_time: float = 0.5) -> void:
	if target == null:
		return

	var anticipated_pos := target.global_position + velocity * anticipation_time
	look_at_position(anticipated_pos)


## Frame subject with rule of thirds
func frame_thirds(offset_direction: Vector3 = Vector3.RIGHT) -> void:
	if target == null:
		return

	# Offset camera to put subject at thirds intersection
	var thirds_offset := offset_direction.normalized() * 2.0
	look_ahead_offset = thirds_offset


## Execute a slow reveal (gradual FOV change)
func slow_reveal(target_fov_value: float, duration: float) -> void:
	var tween := create_tween()
	tween.tween_property(self, "target_fov", target_fov_value, duration)


## Execute a quick zoom
func quick_zoom(zoom_fov: float, duration: float = 0.3) -> void:
	var original_fov := target_fov
	var tween := create_tween()
	tween.tween_property(self, "fov", zoom_fov, duration * 0.3)
	tween.tween_property(self, "fov", original_fov, duration * 0.7)


# =============================================================================
# IMPERFECTION (Human-like Camera Work)
# =============================================================================

## Miss a shot (intentionally lag behind subject)
func miss_shot(duration: float = 0.5) -> void:
	# Temporarily slow rotation smoothing
	var original_smooth := rotation_smoothing
	rotation_smoothing = 0.5

	await get_tree().create_timer(duration).timeout
	rotation_smoothing = original_smooth


## Arrive late to a moment
func arrive_late(target_pos: Vector3, delay: float = 0.3) -> void:
	await get_tree().create_timer(delay).timeout
	look_at_position(target_pos)


## Hesitate (brief pause in tracking)
func hesitate(duration: float = 0.2) -> void:
	var original_smooth := rotation_smoothing
	rotation_smoothing = 0.1

	await get_tree().create_timer(duration).timeout
	rotation_smoothing = original_smooth


# =============================================================================
# QUERIES
# =============================================================================

func is_subject_framed() -> bool:
	return subject_in_frame


func is_in_dropout() -> bool:
	return in_dropout


func get_current_intent() -> GameEnums.ShotIntent:
	return shot_intent


func get_summary() -> Dictionary:
	return {
		"fov": fov,
		"target_fov": target_fov,
		"intent": GameEnums.ShotIntent.keys()[shot_intent],
		"subject_in_frame": subject_in_frame,
		"signal_strength": signal_strength,
		"in_dropout": in_dropout,
		"shake": shake_offset.length()
	}
