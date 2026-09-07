class_name PlayerCamera
extends Node3D
## Third-person chase camera with terrain collision and stability effects.
## Provides diegetic feedback through camera behaviour (sway, shake, distance).
##
## The pivot is top_level: its transform is global, so the parent body's
## motion is never applied twice. The Camera3D child keeps an identity local
## transform, so this node's global position IS the camera position and its
## orientation IS the view direction.
##
## Mouse mode is owned by main.gd (captured during DESCENT, visible elsewhere).
## This node only reads the mode to decide whether mouse motion should look.

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
## Negative pitch looks down on the climber; positive puts the camera low
@export var min_pitch: float = -75.0
@export var max_pitch: float = 25.0
## Position smoothing rate (1/s). Higher = tighter follow, less lag
@export var position_lerp_speed: float = 14.0

@export_group("Offset")
## x = over-the-shoulder offset along camera right, y = height above feet
@export var shoulder_offset: Vector3 = Vector3(0.45, 1.45, 0)
@export var look_ahead_distance: float = 2.0
@export var look_ahead_lerp: float = 2.0

@export_group("Effects")
@export var sway_enabled: bool = true
@export var sway_amount: float = 0.02
@export var sway_speed: float = 2.0
@export var shake_decay: float = 5.0

## Minimum distance kept from any surface the collision ray hits
const COLLISION_MARGIN := 0.3

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Current camera (actual)
@onready var camera: Camera3D = $Camera3D

## Current yaw (horizontal orbit, radians). Initialised from the player facing
var yaw: float = 0.0

## Current pitch (vertical orbit, radians)
var pitch: float = deg_to_rad(-18.0)

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

## Collision raycast (terrain layer only)
var collision_ray: RayCast3D

## False until the camera has snapped behind the player once
var _initialised: bool = false


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	# Enforce the global-space contract even if the scene forgets it
	top_level = true
	if camera != null:
		camera.transform = Transform3D.IDENTITY

	# Setup collision ray. It is top_level too, so its target_position can be
	# given in world axes regardless of how this pivot is rotated
	collision_ray = RayCast3D.new()
	collision_ray.name = "CollisionRay"
	collision_ray.top_level = true
	collision_ray.enabled = false  # Updated manually with force_raycast_update()
	collision_ray.collision_mask = 1  # Terrain layer
	collision_ray.hit_from_inside = false
	add_child(collision_ray)

	# The pivot lives inside the player scene, so the parent is the controller.
	# Prefer it over the service registry (which may still hold a previous run's
	# freed player until the new one registers)
	player = get_parent() as PlayerController
	if player != null:
		_connect_player()
	else:
		ServiceLocator.get_service_async("PlayerController", _on_player_ready)


func _on_player_ready(service: Object) -> void:
	if not is_instance_valid(service):
		return
	player = service as PlayerController
	if player != null:
		_connect_player()


func _connect_player() -> void:
	if not player.stability_changed.is_connected(_on_stability_changed):
		player.stability_changed.connect(_on_stability_changed)
	if not player.micro_slip_occurred.is_connected(_on_micro_slip):
		player.micro_slip_occurred.connect(_on_micro_slip)
	print("[PlayerCamera] Connected to PlayerController")


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			var motion := event as InputEventMouseMotion
			yaw -= motion.relative.x * mouse_sensitivity
			pitch -= motion.relative.y * mouse_sensitivity
			pitch = clampf(pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
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
	# Look ahead in movement direction
	var velocity_horizontal := Vector3(player.velocity.x, 0, player.velocity.z)
	var speed := velocity_horizontal.length()

	var t := 1.0 - exp(-look_ahead_lerp * delta)
	if speed > 0.5:
		var target_offset := velocity_horizontal.normalized() * minf(speed, look_ahead_distance)
		look_ahead_offset = look_ahead_offset.lerp(target_offset, t)
	else:
		look_ahead_offset = look_ahead_offset.lerp(Vector3.ZERO, t)


func _update_distance(delta: float) -> void:
	# Adjust distance based on state
	match player.current_state:
		GameEnums.PlayerMovementState.SLIDING:
			target_distance = default_distance * 1.3  # Pull back during slide
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			target_distance = default_distance * 0.8  # Closer during downclimb
		_:
			target_distance = default_distance

	target_distance = clampf(target_distance, min_distance, max_distance)
	current_distance = lerpf(current_distance, target_distance, 1.0 - exp(-distance_lerp_speed * delta))


func _update_camera_position(delta: float) -> void:
	# First update: sit behind the climber, looking the way they face
	if not _initialised:
		yaw = player.global_rotation.y
		current_distance = default_distance
		target_distance = default_distance

	# Target point: above the feet, offset over the shoulder along camera right
	var yaw_basis := Basis(Vector3.UP, yaw)
	var target_point := player.global_position \
		+ Vector3(0, shoulder_offset.y, 0) \
		+ yaw_basis.x * shoulder_offset.x \
		+ look_ahead_offset \
		+ get_slide_camera_offset()

	# Orbit position from pitch/yaw and distance
	var orbit_basis := Basis.from_euler(Vector3(pitch, yaw, 0))
	var ideal_position := target_point + orbit_basis * Vector3(0, 0, current_distance)

	# Collision check against terrain
	if collision_enabled:
		ideal_position = _check_collision(target_point, ideal_position)

	# Apply sway and shake
	ideal_position += sway_offset + shake_offset

	# Smooth camera movement (frame-rate independent; snaps on first update)
	if _initialised:
		var t := 1.0 - exp(-position_lerp_speed * delta)
		global_position = global_position.lerp(ideal_position, t)
	else:
		global_position = ideal_position
		_initialised = true

	# Aim this pivot (and therefore the identity-transform camera) at the target.
	# When the climber drops straight down (a fall, or the spawn settling onto
	# the ground) the camera can end up directly above them; look_at rejects
	# an up vector parallel to the view, so fall back to a horizontal up
	var to_target := target_point - global_position
	if to_target.length_squared() > 0.0001:
		var up := Vector3.UP
		if absf(to_target.normalized().dot(Vector3.UP)) > 0.995:
			up = yaw_basis.z
		look_at(target_point, up)


func _check_collision(target: Vector3, ideal_pos: Vector3) -> Vector3:
	if collision_ray == null or not collision_ray.is_inside_tree():
		return ideal_pos

	collision_ray.global_transform = Transform3D(Basis.IDENTITY, target)
	collision_ray.target_position = ideal_pos - target
	collision_ray.force_raycast_update()

	if collision_ray.is_colliding():
		var collision_point := collision_ray.get_collision_point()
		var back_toward_target := (target - collision_point).normalized()
		# Keep a margin in front of the surface, always on the target's side
		return collision_point + back_toward_target * COLLISION_MARGIN

	return ideal_pos


# =============================================================================
# CONTROL
# =============================================================================

## Re-seat the camera behind the climber right away (e.g. after a respawn or
## teleport) so the next rendered frame is already correct
func snap_behind_player() -> void:
	_initialised = false
	if is_inside_tree() and player != null and is_instance_valid(player) and player.is_inside_tree():
		_update_camera_position(0.0)


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
