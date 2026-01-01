class_name DroneController
extends Node
## Controls drone movement and positioning
## Provides foundation for Camera Director AI to command
##
## Design Philosophy:
## - Smooth, cinematic movement
## - Position planning with collision avoidance
## - Human-like imperfection in positioning
## - Responds to shot intent from director

# =============================================================================
# SIGNALS
# =============================================================================

signal target_reached(position: Vector3)
signal movement_blocked(obstacle: String)
signal position_planned(from: Vector3, to: Vector3)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Movement")
## Approach speed factor (0-1, lower = smoother)
@export var approach_smoothing: float = 0.7
## Minimum distance to consider target reached
@export var arrival_threshold: float = 1.0
## Orbit speed when circling subject
@export var orbit_speed: float = 0.3
## Vertical offset preference
@export var preferred_altitude_offset: float = 5.0

@export_group("Collision")
## Enable collision avoidance
@export var collision_avoidance: bool = true
## Collision check distance
@export var collision_distance: float = 5.0
## Avoidance strength
@export var avoidance_strength: float = 2.0

@export_group("Behavior")
## Enable human-like imperfection
@export var imperfection_enabled: bool = true
## Position drift amount
@export var position_drift: float = 0.5
## Reaction delay range (seconds)
@export var reaction_delay_range: Vector2 = Vector2(0.1, 0.4)

# =============================================================================
# STATE
# =============================================================================

## Reference to parent drone
var drone: DroneEntity

## Current target position
var target_position: Vector3 = Vector3.ZERO

## Is actively moving to target
var has_target: bool = false

## Current speed factor (0-1)
var speed_factor: float = 1.0

## Current orbit angle (for orbiting shots)
var orbit_angle: float = 0.0

## Is orbiting
var is_orbiting: bool = false

## Orbit radius
var orbit_radius: float = 10.0

## Orbit center (usually subject position)
var orbit_center: Vector3 = Vector3.ZERO

## Position drift offset
var drift_offset: Vector3 = Vector3.ZERO

## Drift time accumulator
var drift_time: float = 0.0

## Pending movement (for reaction delay)
var pending_move: Dictionary = {}

## Collision raycast
var collision_ray: RayCast3D


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_setup_collision()


func _setup_collision() -> void:
	collision_ray = RayCast3D.new()
	collision_ray.collision_mask = 1  # Terrain
	collision_ray.enabled = true
	add_child(collision_ray)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if drone == null:
		return

	_process_pending_moves()
	_update_drift(delta)

	if is_orbiting:
		_update_orbit(delta)


func _update_drift(delta: float) -> void:
	if not imperfection_enabled:
		drift_offset = Vector3.ZERO
		return

	drift_time += delta

	# Slow, organic drift
	drift_offset = Vector3(
		sin(drift_time * 0.3) * position_drift,
		sin(drift_time * 0.2) * position_drift * 0.5,
		cos(drift_time * 0.25) * position_drift
	)


func _update_orbit(delta: float) -> void:
	if drone.subject == null:
		is_orbiting = false
		return

	orbit_angle += orbit_speed * delta
	orbit_center = drone.subject.global_position

	# Calculate orbit position
	var orbit_pos := orbit_center + Vector3(
		cos(orbit_angle) * orbit_radius,
		preferred_altitude_offset,
		sin(orbit_angle) * orbit_radius
	)

	target_position = orbit_pos
	has_target = true


func _process_pending_moves() -> void:
	if pending_move.is_empty():
		return

	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time >= pending_move.get("execute_time", 0):
		target_position = pending_move.get("position", Vector3.ZERO)
		speed_factor = pending_move.get("speed_factor", 1.0)
		has_target = true
		pending_move.clear()


# =============================================================================
# MOVEMENT INPUT
# =============================================================================

## Get movement input for drone physics
func get_movement_input() -> Vector3:
	if not has_target:
		return drift_offset * 0.1  # Just drift when no target

	var current_pos := drone.global_position
	var direction := (target_position - current_pos)
	var distance := direction.length()

	# Check if arrived
	if distance < arrival_threshold:
		has_target = false
		target_reached.emit(target_position)
		return drift_offset * 0.1

	# Normalize and apply approach smoothing
	direction = direction.normalized()

	# Slow down as we approach
	var approach_factor := clampf(distance / 10.0, 0.2, 1.0)

	# Apply speed factor
	var final_speed := approach_factor * speed_factor * approach_smoothing

	# Collision avoidance
	if collision_avoidance:
		direction = _apply_collision_avoidance(current_pos, direction)

	# Add drift for organic movement
	var result := direction * final_speed + drift_offset * 0.1

	return result


func _apply_collision_avoidance(from: Vector3, direction: Vector3) -> Vector3:
	collision_ray.global_position = from
	collision_ray.target_position = direction * collision_distance

	collision_ray.force_raycast_update()

	if collision_ray.is_colliding():
		var collision_normal := collision_ray.get_collision_normal()
		var avoidance := collision_normal * avoidance_strength

		# Blend avoidance with original direction
		direction = (direction + avoidance).normalized()
		movement_blocked.emit("terrain")

	return direction


# =============================================================================
# POSITION COMMANDS
# =============================================================================

## Move to a specific position
func set_target_position(position: Vector3, speed: float = 1.0) -> void:
	if imperfection_enabled:
		# Add reaction delay
		var delay := randf_range(reaction_delay_range.x, reaction_delay_range.y)
		pending_move = {
			"position": position,
			"speed_factor": speed,
			"execute_time": Time.get_ticks_msec() / 1000.0 + delay
		}
	else:
		target_position = position
		speed_factor = speed
		has_target = true

	position_planned.emit(drone.global_position if drone else Vector3.ZERO, position)


## Move to offset from subject
func move_to_subject_offset(offset: Vector3, speed: float = 1.0) -> void:
	if drone == null or drone.subject == null:
		return

	var target := drone.subject.global_position + offset
	set_target_position(target, speed)


## Start orbiting the subject
func start_orbit(radius: float = 10.0, speed: float = 0.3) -> void:
	orbit_radius = radius
	orbit_speed = speed
	is_orbiting = true

	# Start from current angle
	if drone and drone.subject:
		var to_drone := drone.global_position - drone.subject.global_position
		orbit_angle = atan2(to_drone.z, to_drone.x)


## Stop orbiting
func stop_orbit() -> void:
	is_orbiting = false


## Hold current position
func hold_position() -> void:
	has_target = false
	is_orbiting = false


## Track subject with offset
func track_subject(offset: Vector3) -> void:
	if drone == null or drone.subject == null:
		return

	# Continuously update target to follow subject
	target_position = drone.subject.global_position + offset
	has_target = true


# =============================================================================
# SHOT POSITIONING
# =============================================================================

## Position for a context shot (wide, establishing)
func position_for_context() -> void:
	move_to_subject_offset(Vector3(0, 15, 25), 0.5)


## Position for a tension shot (medium, close)
func position_for_tension() -> void:
	move_to_subject_offset(Vector3(3, 3, 8), 0.7)


## Position for a commitment shot (close, forward)
func position_for_commitment() -> void:
	move_to_subject_offset(Vector3(1, 2, 5), 0.8)


## Position for a consequence shot (neutral observation)
func position_for_consequence() -> void:
	move_to_subject_offset(Vector3(0, 5, 12), 0.4)


## Position for a release shot (pull back, breathe)
func position_for_release() -> void:
	move_to_subject_offset(Vector3(0, 12, 30), 0.3)


## Position based on shot intent
func position_for_intent(intent: GameEnums.ShotIntent) -> void:
	match intent:
		GameEnums.ShotIntent.CONTEXT:
			position_for_context()
		GameEnums.ShotIntent.TENSION:
			position_for_tension()
		GameEnums.ShotIntent.COMMITMENT:
			position_for_commitment()
		GameEnums.ShotIntent.CONSEQUENCE:
			position_for_consequence()
		GameEnums.ShotIntent.RELEASE:
			position_for_release()


# =============================================================================
# ADVANCED MOVEMENTS
# =============================================================================

## Dolly in (move closer while maintaining framing)
func dolly_in(distance: float, duration: float) -> void:
	if drone == null or drone.subject == null:
		return

	var direction := (drone.global_position - drone.subject.global_position).normalized()
	var target := drone.global_position - direction * distance

	set_target_position(target, distance / duration / drone.max_speed)


## Dolly out (move away while maintaining framing)
func dolly_out(distance: float, duration: float) -> void:
	if drone == null or drone.subject == null:
		return

	var direction := (drone.global_position - drone.subject.global_position).normalized()
	var target := drone.global_position + direction * distance

	set_target_position(target, distance / duration / drone.max_speed)


## Crane up (vertical rise)
func crane_up(height: float, duration: float) -> void:
	var target := drone.global_position + Vector3(0, height, 0)
	set_target_position(target, height / duration / drone.climb_rate)


## Crane down
func crane_down(height: float, duration: float) -> void:
	var target := drone.global_position - Vector3(0, height, 0)
	set_target_position(target, height / duration / drone.climb_rate)


## Arc move (curved path around subject)
func arc_move(start_angle: float, end_angle: float, duration: float) -> void:
	orbit_angle = start_angle
	orbit_speed = (end_angle - start_angle) / duration
	is_orbiting = true

	# Stop after duration
	get_tree().create_timer(duration).timeout.connect(func(): is_orbiting = false)


# =============================================================================
# FATAL EVENT SUPPORT
# =============================================================================

## Hold current position (stop all movement)
func hold_position() -> void:
	has_target = false
	is_orbiting = false
	orbit_subject = false
	if drone:
		target_position = drone.global_position


## Pull back from current position
func pull_back(distance: float, duration: float) -> void:
	if drone == null:
		return

	# Calculate pullback direction (away from subject or backward)
	var pullback_dir := -drone.global_transform.basis.z
	if drone.subject:
		pullback_dir = (drone.global_position - drone.subject.global_position).normalized()

	var target := drone.global_position + pullback_dir * distance
	set_target_position(target, distance / duration)


# =============================================================================
# QUERIES
# =============================================================================

func is_moving() -> bool:
	return has_target


func is_at_target() -> bool:
	if not has_target or drone == null:
		return true

	return drone.global_position.distance_to(target_position) < arrival_threshold


func get_target_position() -> Vector3:
	return target_position


func get_summary() -> Dictionary:
	return {
		"has_target": has_target,
		"target_position": target_position,
		"is_orbiting": is_orbiting,
		"orbit_angle": orbit_angle,
		"speed_factor": speed_factor
	}
