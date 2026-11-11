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

## Keeping station on the subject: the offset held from them, in the frame of
## the slope they are on (x across it to their right when facing downhill,
## y up, z back up the fall line). A shot is a station kept, not a spot flown
## to once: the climber keeps moving.
var is_following: bool = false
var follow_offset: Vector3 = Vector3.ZERO
var follow_speed: float = 1.0

## Horizontal unit vector pointing back up the fall line from the subject
## (behind them on flat ground). Turns slowly, so the drone does not swing
## round every time the climber crosses a ripple in the slope.
var _back: Vector3 = Vector3.ZERO

## Below this slope there is no fall line worth following
const FLAT_SLOPE := 8.0
## How fast the station swings round to a new fall line (per second)
const BACK_TURN_RATE := 0.6
## Metres a station is kept above the ground under it
const STATION_CLEARANCE := 4.0
## A station with something between it and the subject (a tree, a roll in the
## slope) is raised by these amounts in turn until it can see them
const SIGHT_LIFTS: Array[float] = [0.0, 6.0, 12.0, 20.0]
## Where on the subject the drone needs to see (metres above their feet)
const SIGHT_HEIGHT := 1.0
## In a fatal sequence the drone stays at least this far to the side for each
## metre it is above the climber (about 40 degrees off the vertical)
const OVERHEAD_RATIO := 0.85
## Seconds between looks at whether the station being kept can still see them
const SIGHT_CHECK_INTERVAL := 0.3

## How far the station being kept is raised to see the subject, and when that
## is next looked at
var _follow_lift: float = 0.0
var _sight_check_in: float = 0.0

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
	elif is_following:
		_update_follow(delta)


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

	# Check if arrived (on station while following: stay with it, quietly)
	if distance < arrival_threshold:
		if not is_following:
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

## Move to a specific position (a single move: it takes over from any station
## being kept)
func set_target_position(position: Vector3, speed: float = 1.0) -> void:
	is_following = false
	position = _permitted(position)
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


## A place the drone may be sent: clear of the ground, and during a fatal
## sequence never over the climber. ("The drone must never hover directly
## overhead": SPECTATOR rules for fatal events.)
func _permitted(position: Vector3) -> Vector3:
	if drone == null:
		return position
	if drone.terrain_service != null:
		position.y = maxf(position.y, drone.terrain_service.get_height_at(position) + STATION_CLEARANCE)
	if drone.let_subject_go and is_instance_valid(drone.subject):
		var from_subject: Vector3 = position - drone.subject.global_position
		var height := maxf(from_subject.y, 0.0)
		var aside := Vector2(from_subject.x, from_subject.z)
		var needed := height * OVERHEAD_RATIO
		if aside.length() < needed:
			var away := aside.normalized() if aside.length() > 0.5 else Vector2(_back.x, _back.z)
			if away.length() < 0.5:
				away = Vector2(0.0, 1.0)
			aside = away.normalized() * needed
			position.x = drone.subject.global_position.x + aside.x
			position.z = drone.subject.global_position.z + aside.y
	return position


## Move to offset from subject
func move_to_subject_offset(offset: Vector3, speed: float = 1.0) -> void:
	if drone == null or drone.subject == null:
		return

	var target := drone.subject.global_position + offset
	set_target_position(target, speed)


## Keep station on the subject at an offset in the slope's frame (x across,
## y up, z back up the fall line) until told otherwise
func follow_subject(offset: Vector3, speed: float = 1.0) -> void:
	if drone == null or not is_instance_valid(drone.subject):
		return
	follow_offset = offset
	follow_speed = speed
	is_following = true
	is_orbiting = false
	pending_move.clear()
	_update_follow(0.0)


## Where an offset from the subject is in the world, kept clear of the ground
func station_for(offset: Vector3) -> Vector3:
	if drone == null or not is_instance_valid(drone.subject):
		return target_position
	if _back == Vector3.ZERO:
		_update_back(0.0)
	var station := _station_at_offset(offset)
	return station + Vector3.UP * _lift_to_see_from(station)


## The offset itself, in the world, kept clear of the ground under it
func _station_at_offset(offset: Vector3) -> Vector3:
	var across := Vector3.UP.cross(_back)
	var station: Vector3 = drone.subject.global_position + across * offset.x + Vector3.UP * offset.y + _back * offset.z
	if drone.terrain_service != null:
		station.y = maxf(station.y, drone.terrain_service.get_height_at(station) + STATION_CLEARANCE)
	return station


## How far a station has to be raised to see the subject: a camera behind a
## tree films the tree
func _lift_to_see_from(station: Vector3) -> float:
	for lift in SIGHT_LIFTS:
		if _can_see_subject_from(station + Vector3.UP * lift):
			return lift
	return SIGHT_LIFTS[-1]


## True when neither ground, rock nor a tree lies between a point and the subject
func _can_see_subject_from(point: Vector3) -> bool:
	var eye := drone.subject.global_position + Vector3.UP * SIGHT_HEIGHT
	if drone.is_inside_tree():
		var space := drone.get_world_3d().direct_space_state
		if space != null:
			var query := PhysicsRayQueryParameters3D.create(point, eye)
			var excluded: Array[RID] = [drone.get_rid()]
			if drone.subject is CollisionObject3D:
				excluded.append((drone.subject as CollisionObject3D).get_rid())
			query.exclude = excluded
			if not space.intersect_ray(query).is_empty():
				return false
	return _sight_clear_of_trees(point, eye)


## A tree's collider is its trunk; what hides the climber is its foliage, a
## cone from the ground to the tree's height
func _sight_clear_of_trees(from: Vector3, to: Vector3) -> bool:
	var scatter: TerrainScatter = drone.terrain_service.scatter if drone.terrain_service != null else null
	if scatter == null:
		return true
	var steps := clampi(int(from.distance_to(to) / 3.0), 2, 12)
	for i in range(steps):
		var point := from.lerp(to, float(i) / float(steps))
		# The climber may be standing under a tree: that is not the drone's doing
		if point.distance_to(to) < 3.0:
			break
		for obj in scatter.get_objects_near(point, 4.0):
			if not obj.is_tree() or obj.size <= 0.0:
				continue
			var above := point.y - obj.position.y
			if above < 0.0 or above > obj.size:
				continue
			var foliage := maxf(obj.footprint, 1.0) * (1.0 - above / obj.size) + 0.75
			if Vector2(point.x - obj.position.x, point.z - obj.position.z).length() < foliage:
				return false
	return true


func _update_follow(delta: float) -> void:
	if not is_instance_valid(drone.subject):
		is_following = false
		return
	_update_back(delta)
	var station := _station_at_offset(follow_offset)
	# Looking for a clear view costs rays and tree lookups: not every tick
	_sight_check_in -= delta
	if _sight_check_in <= 0.0 or delta <= 0.0:
		_sight_check_in = SIGHT_CHECK_INTERVAL
		_follow_lift = _lift_to_see_from(station)
	target_position = station + Vector3.UP * _follow_lift
	has_target = true
	# Fast enough to stay with a subject that is moving
	var subject_speed := 0.0
	if drone.subject is CharacterBody3D:
		subject_speed = (drone.subject as CharacterBody3D).velocity.length()
	speed_factor = clampf(maxf(follow_speed, (subject_speed + 2.0) / maxf(drone.max_speed * approach_smoothing, 0.1)), 0.0, 1.4)


## Turn "back" toward the uphill side of the slope the subject is on
func _update_back(delta: float) -> void:
	var subject := drone.subject
	var wanted := _back
	var cell: TerrainCell = drone.terrain_service.get_cell_at(subject.global_position) if drone.terrain_service != null else null
	if cell != null and cell.slope_angle >= FLAT_SLOPE:
		var down := Vector3(cell.slope_direction.x, 0.0, cell.slope_direction.z)
		if down.length_squared() > 0.0001:
			wanted = -down.normalized()
	if wanted == Vector3.ZERO:
		# Flat ground and no fall line seen yet: behind where they face
		var behind := subject.global_transform.basis.z
		behind.y = 0.0
		wanted = behind.normalized() if behind.length_squared() > 0.0001 else Vector3.BACK
	if _back == Vector3.ZERO or delta <= 0.0:
		_back = wanted if _back == Vector3.ZERO else _back
		return
	# Opposite directions have no shortest way round: pick one
	if _back.dot(wanted) < -0.98:
		wanted = (wanted + Vector3.UP.cross(_back) * 0.2).normalized()
	_back = _back.slerp(wanted, clampf(delta * BACK_TURN_RATE, 0.0, 1.0))
	_back.y = 0.0
	_back = _back.normalized() if _back.length_squared() > 0.0001 else wanted


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
	follow_subject(Vector3(0, 15, 25), 0.5)


## Position for a tension shot (medium, close)
func position_for_tension() -> void:
	follow_subject(Vector3(3, 3, 8), 0.7)


## Position for a commitment shot (close, forward)
func position_for_commitment() -> void:
	follow_subject(Vector3(1, 2, 5), 0.8)


## Position for a consequence shot (neutral observation)
func position_for_consequence() -> void:
	follow_subject(Vector3(0, 5, 12), 0.4)


## Position for a release shot (pull back, breathe)
func position_for_release() -> void:
	follow_subject(Vector3(0, 12, 30), 0.3)


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
	is_following = false
	pending_move.clear()
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
		"is_following": is_following,
		"follow_offset": follow_offset,
		"orbit_angle": orbit_angle,
		"speed_factor": speed_factor
	}
