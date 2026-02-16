class_name PlayerCamera
extends Node3D
## Third-person camera for player with terrain awareness and stability effects
## Provides diegetic feedback through camera behavior

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Distance")
@export var default_distance: float = 5.0
@export var min_distance: float = 2.0
@export var max_distance: float = 10.0
@export var distance_lerp_speed: float = 3.0

@export_group("Rotation")
@export var mouse_sensitivity: float = 0.003
@export var min_pitch: float = -80.0
@export var max_pitch: float = 80.0
@export var rotation_lerp_speed: float = 10.0

@export_group("Offset")
@export var shoulder_offset: Vector3 = Vector3(0.5, 1.5, 0)
@export var look_ahead_distance: float = 2.0
@export var look_ahead_lerp: float = 2.0

@export_group("Effects")
@export var sway_enabled: bool = true
@export var sway_amount: float = 0.02
@export var sway_speed: float = 2.0
@export var shake_decay: float = 5.0

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Current camera (actual)
@onready var camera: Camera3D = $Camera3D

## Current yaw (horizontal rotation)
var yaw: float = 0.0

## Current pitch (vertical rotation, in radians)
var pitch: float = deg_to_rad(-20.0)

## Current distance from player
var current_distance: float = 5.0

## Target distance
var target_distance: float = 5.0

## Look ahead offset (based on velocity)
var look_ahead_offset: Vector3 = Vector3.ZERO

## Current sway offset
var sway_offset: Vector3 = Vector3.ZERO

## Sway time accumulator
var sway_time: float = 0.0

## Current shake intensity
var shake_intensity: float = 0.0

## Shake offset
var shake_offset: Vector3 = Vector3.ZERO

## Is camera collision enabled
var collision_enabled: bool = true

## Collision raycast
var collision_ray: RayCast3D


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	# Setup collision ray
	collision_ray = RayCast3D.new()
	collision_ray.enabled = true
	collision_ray.collision_mask = 1  # Terrain layer
	add_child(collision_ray)

	# Capture mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Get player reference
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)


func _on_player_ready(service: Object) -> void:
	player = service as PlayerController

	# Connect to player signals
	player.stability_changed.connect(_on_stability_changed)
	player.micro_slip_occurred.connect(_on_micro_slip)

	print("[PlayerCamera] Connected to PlayerController")


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			yaw -= event.relative.x * mouse_sensitivity
			pitch -= event.relative.y * mouse_sensitivity
			pitch = clampf(pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))

	# Toggle mouse capture
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if player == null:
		return

	# Update sway
	_update_sway(delta)

	# Update shake
	_update_shake(delta)

	# Update look ahead
	_update_look_ahead(delta)

	# Update distance
	_update_distance(delta)

	# Calculate camera position
	_update_camera_position(delta)


func _update_sway(delta: float) -> void:
	if not sway_enabled:
		sway_offset = Vector3.ZERO
		return

	sway_time += delta * sway_speed

	# Get sway amount from player body state
	var sway_factor := 0.0
	if player.body_state:
		sway_factor = player.body_state.get_camera_sway()

	# Additional sway from stability
	sway_factor += (1.0 - player.stability) * 0.5

	# Calculate sway
	var sway_x := sin(sway_time * 1.3) * sway_amount * sway_factor
	var sway_y := sin(sway_time * 1.7) * sway_amount * sway_factor * 0.5

	sway_offset = Vector3(sway_x, sway_y, 0)


func _update_shake(delta: float) -> void:
	if shake_intensity > 0.01:
		# Random shake offset
		shake_offset = Vector3(
			randf_range(-1, 1) * shake_intensity,
			randf_range(-1, 1) * shake_intensity * 0.5,
			randf_range(-1, 1) * shake_intensity * 0.3
		)

		# Decay shake
		shake_intensity *= exp(-shake_decay * delta)
	else:
		shake_intensity = 0.0
		shake_offset = Vector3.ZERO


func _update_look_ahead(delta: float) -> void:
	if player == null:
		return

	# Look ahead in movement direction
	var velocity_horizontal := Vector3(player.velocity.x, 0, player.velocity.z)
	var speed := velocity_horizontal.length()

	if speed > 0.5:
		var target_offset := velocity_horizontal.normalized() * minf(speed, look_ahead_distance)
		look_ahead_offset = look_ahead_offset.lerp(target_offset, look_ahead_lerp * delta)
	else:
		look_ahead_offset = look_ahead_offset.lerp(Vector3.ZERO, look_ahead_lerp * delta)


func _update_distance(delta: float) -> void:
	# Adjust distance based on state
	match player.current_state:
		GameEnums.PlayerMovementState.SLIDING:
			target_distance = default_distance * 1.3  # Pull back during slide
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			target_distance = default_distance * 0.8  # Closer during downclimb
		_:
			target_distance = default_distance

	current_distance = lerpf(current_distance, target_distance, distance_lerp_speed * delta)


func _update_camera_position(delta: float) -> void:
	if player == null:
		return

	# Target point (player position + offset)
	var target_point := player.global_position + shoulder_offset + look_ahead_offset

	# Calculate camera position from rotation and distance
	var rotation_basis := Basis.from_euler(Vector3(pitch, yaw, 0))
	var camera_offset := rotation_basis * Vector3(0, 0, current_distance)

	var ideal_position := target_point + camera_offset

	# Collision check
	if collision_enabled:
		ideal_position = _check_collision(target_point, ideal_position)

	# Apply sway and shake
	ideal_position += sway_offset + shake_offset

	# Smooth camera movement
	global_position = global_position.lerp(ideal_position, rotation_lerp_speed * delta)

	# Look at target
	if camera:
		camera.look_at(target_point, Vector3.UP)


func _check_collision(target: Vector3, ideal_pos: Vector3) -> Vector3:
	collision_ray.global_position = target
	collision_ray.target_position = ideal_pos - target

	collision_ray.force_raycast_update()

	if collision_ray.is_colliding():
		var collision_point := collision_ray.get_collision_point()
		var collision_normal := collision_ray.get_collision_normal()

		# Pull camera in front of collision
		return collision_point + collision_normal * 0.3

	return ideal_pos


# =============================================================================
# EFFECTS
# =============================================================================

## Add camera shake
func add_shake(intensity: float) -> void:
	shake_intensity = maxf(shake_intensity, intensity)


## Trigger micro-slip camera effect
func _on_micro_slip(severity: float) -> void:
	add_shake(severity * 0.3)


## Adjust camera for stability changes
func _on_stability_changed(stability: float, _posture: GameEnums.PostureState) -> void:
	if stability < 0.3:
		add_shake(0.1)


# =============================================================================
# SLIDING CAMERA BEHAVIOR
# =============================================================================

## Get slide camera adjustments
func get_slide_camera_offset() -> Vector3:
	if player == null or player.current_state != GameEnums.PlayerMovementState.SLIDING:
		return Vector3.ZERO

	# Lower camera during slide
	var speed := player.smooth_velocity.length()
	var lower_amount := minf(speed / 20.0, 0.5)

	return Vector3(0, -lower_amount, 0)


# =============================================================================
# DEBUG
# =============================================================================

func get_debug_info() -> Dictionary:
	return {
		"yaw": rad_to_deg(yaw),
		"pitch": rad_to_deg(pitch),
		"distance": current_distance,
		"shake": shake_intensity,
		"sway": sway_offset.length()
	}
