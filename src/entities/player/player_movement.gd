class_name PlayerMovement
extends Node
## Handles player movement physics and terrain interaction
## Works with PlayerController to move the player based on state
##
## Walking pace follows Tobler's hiking function (TractionModel.tobler_factor):
## a steep descent is slower than the flat and a steep climb much slower.
## Downclimbing clings to the face: the climber moves in deliberate placements
## along the surface (reach, weight, step) and gravity does not pull them off;
## whether the footing holds is PostureSystem's business.
##
## The climber model faces -Z (goggles forward, pack behind), so a yaw that
## faces direction d is atan2(-d.x, -d.z).

# =============================================================================
# CONFIGURATION
# =============================================================================

## Acceleration when walking
var walk_acceleration: float = 15.0

## Deceleration when stopping
var walk_deceleration: float = 20.0

## Turn speed in radians per second
var turn_speed: float = 5.0

## Slope angle that starts affecting movement
var slope_effect_start: float = 3.0

## Maximum slope for walking (beyond this requires downclimb)
var max_walk_slope: float = PlayerController.DOWNCLIMB_ENTER_SLOPE

## Surface distance of one downclimbing move (a placement and a step)
var downclimb_move_length: float = 0.45

## Fatigue per metre of height lost or gained while downclimbing
var downclimb_fatigue_per_metre: float = 0.003

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Current target velocity
var target_velocity: Vector3 = Vector3.ZERO

## Movement direction in world space
var move_direction: Vector3 = Vector3.ZERO

## Is player moving uphill
var is_uphill: bool = false

## Current slope factor affecting movement
var slope_factor: float = 1.0

## Accumulated distance for fatigue
var distance_accumulator: float = 0.0

## Distance before fatigue tick
var fatigue_distance: float = 10.0

## Phase of the downclimbing placement cycle (radians)
var climb_phase: float = 0.0

## Height at the last downclimbing fatigue tick
var _climb_reference_height: float = NAN


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(controller: PlayerController) -> void:
	player = controller


## Forget per-run movement state
func reset() -> void:
	target_velocity = Vector3.ZERO
	move_direction = Vector3.ZERO
	distance_accumulator = 0.0
	slope_factor = 1.0
	climb_phase = 0.0
	_climb_reference_height = NAN


# =============================================================================
# UPDATE
# =============================================================================

func update(delta: float) -> void:
	match player.current_state:
		GameEnums.PlayerMovementState.STANDING:
			_update_standing(delta)
		GameEnums.PlayerMovementState.WALKING:
			_update_walking(delta)
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			_update_downclimbing(delta)
		GameEnums.PlayerMovementState.TRAVERSING:
			_update_traversing(delta)
		GameEnums.PlayerMovementState.SLIDING:
			var slides := player.get_slide_system()
			if slides != null:
				slides.physics_step(delta)
		GameEnums.PlayerMovementState.SKIING:
			var ski := player.get_node_or_null("SkiPhysics")
			if ski != null:
				ski.physics_step(delta)
		GameEnums.PlayerMovementState.ROPING:
			# The rope system moves the climber
			pass
		GameEnums.PlayerMovementState.FALLING:
			_update_falling(delta)
		GameEnums.PlayerMovementState.ARRESTED:
			_hold_on_face(delta)
		GameEnums.PlayerMovementState.RESTING:
			_update_resting(delta)
		GameEnums.PlayerMovementState.INCAPACITATED:
			_apply_deceleration(delta)


# =============================================================================
# STANDING STATE
# =============================================================================

func _update_standing(delta: float) -> void:
	# State changes are the state machine's job; just come to rest
	_apply_deceleration(delta)


# =============================================================================
# WALKING STATE
# =============================================================================

func _update_walking(delta: float) -> void:
	var input := player.input_handler.move_input
	if input.length() < 0.1:
		_apply_deceleration(delta)
		return

	# Calculate move direction in world space
	move_direction = _get_world_move_direction(input)

	# Calculate slope factor
	_calculate_slope_factor()

	# Calculate target speed
	var target_speed := player.get_current_speed() * slope_factor

	# Apply acceleration toward target
	target_velocity = move_direction * target_speed
	_apply_acceleration(delta)

	# Rotate player to face movement direction
	_rotate_to_direction(delta)

	# Track distance for fatigue
	_track_distance(delta)


func _get_world_move_direction(input: Vector2) -> Vector3:
	# Get camera-relative direction
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector3(input.x, 0, input.y).normalized()

	var forward := -camera.global_transform.basis.z
	var right := camera.global_transform.basis.x

	# Flatten to horizontal plane
	forward.y = 0
	forward = forward.normalized()
	right.y = 0
	right = right.normalized()

	var direction := (forward * -input.y + right * input.x).normalized()

	# Adjust for terrain slope
	if player.current_cell and player.current_cell.slope_angle > 5.0:
		# Project onto terrain plane
		var normal := player.current_cell.normal
		direction = (direction - normal * direction.dot(normal)).normalized()

	return direction


## Walking pace on this slope in this direction: Tobler's hiking function on
## the grade along the path, slowed further by the side slope across it
func _calculate_slope_factor() -> void:
	slope_factor = 1.0
	is_uphill = false

	var cell := player.current_cell
	if cell == null or cell.slope_angle < slope_effect_start:
		return

	var heading := Vector3(move_direction.x, 0.0, move_direction.z)
	if heading.length_squared() < 0.0001:
		return
	heading = heading.normalized()

	var steepness := tan(deg_to_rad(cell.slope_angle))
	var along := heading.dot(cell.slope_direction)  # +1 straight downhill
	var across := sqrt(maxf(0.0, 1.0 - along * along))
	is_uphill = along < -0.3

	slope_factor = TractionModel.tobler_factor(-steepness * along, steepness * across, cell.surface_type)


func _apply_acceleration(delta: float) -> void:
	var current := Vector3(player.velocity.x, 0, player.velocity.z)
	var target := Vector3(target_velocity.x, 0, target_velocity.z)

	var diff := target - current
	var accel := walk_acceleration * delta

	if diff.length() < accel:
		player.velocity.x = target.x
		player.velocity.z = target.z
	else:
		var accel_dir := diff.normalized()
		player.velocity.x += accel_dir.x * accel
		player.velocity.z += accel_dir.z * accel


func _apply_deceleration(delta: float) -> void:
	var current := Vector3(player.velocity.x, 0, player.velocity.z)
	var decel := walk_deceleration * delta

	if current.length() < decel:
		player.velocity.x = 0
		player.velocity.z = 0
	else:
		var decel_dir := -current.normalized()
		player.velocity.x += decel_dir.x * decel
		player.velocity.z += decel_dir.z * decel


## Yaw that turns the climber model (which faces -Z) toward a direction
static func yaw_facing(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


func _rotate_to_direction(delta: float) -> void:
	if move_direction.length() < 0.1:
		return
	_turn_toward(yaw_facing(move_direction), turn_speed, delta)


func _turn_toward(target_yaw: float, rate: float, delta: float) -> void:
	var diff := wrapf(target_yaw - player.rotation.y, -PI, PI)
	player.rotation.y += signf(diff) * minf(absf(diff), rate * delta)


func _track_distance(delta: float) -> void:
	var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
	distance_accumulator += horizontal_speed * delta

	if distance_accumulator >= fatigue_distance:
		distance_accumulator -= fatigue_distance

		# Add fatigue based on slope and speed (per fatigue_distance metres;
		# FatigueManager adds the time-based component on top)
		var fatigue_amount := 0.003

		if is_uphill and player.current_cell:
			fatigue_amount *= 1.0 + (player.current_cell.slope_angle / 45.0)

		player.add_fatigue(fatigue_amount)


# =============================================================================
# DOWNCLIMBING STATE
# =============================================================================

## Facing in, the climber moves one placement at a time: the speed pulses
## with each reach and step, steep or icy faces are slower, climbing back up
## slower still. The body follows the surface; it does not slide off it.
func _update_downclimbing(delta: float) -> void:
	var cell := player.current_cell
	var input := player.input_handler.move_input
	if cell == null or input.length() < 0.1:
		_hold_on_face(delta)
		_orient_on_face(Vector3.ZERO, delta)
		return

	move_direction = _get_world_move_direction(input)
	var heading := Vector3(move_direction.x, 0.0, move_direction.z)
	if heading.length_squared() < 0.0001:
		_hold_on_face(delta)
		return
	heading = heading.normalized()

	var along := heading.dot(cell.slope_direction)  # +1 straight down the fall line
	var speed := TractionModel.downclimb_speed(cell.slope_angle, cell.surface_type, player.get_traction_footwear())
	if player.body_state:
		speed *= player.body_state.get_movement_modifier()
	if TractionModel.is_rock(cell.surface_type) or cell.surface_type == GameEnums.SurfaceType.MIXED:
		# Holds are worked with the fingers
		speed *= lerpf(0.5, 1.0, player.get_hand_dexterity())
	if along < -0.3:
		speed *= 0.6  # Climbing back up
	elif absf(along) < 0.5:
		speed *= 0.8  # Traversing the face

	# One placement at a time: reach, weight, step
	climb_phase = fmod(climb_phase + speed * delta / downclimb_move_length * PI, TAU)
	var pulse := sin(climb_phase)
	var surface_speed := speed * (0.3 + 0.7 * pulse * pulse)

	# Along the surface: the path drops tan(slope) * along per horizontal metre
	var path_grade := tan(deg_to_rad(cell.slope_angle)) * along
	var horizontal_speed := surface_speed / sqrt(1.0 + path_grade * path_grade)

	# Follow the surface height and only ease toward contact: asking for more
	# drop than the slope gives would press the body into the face, and the
	# physics would slide the excess downhill (a free ride down the face)
	var here := player.global_position
	var next := here + heading * horizontal_speed * delta
	var follow := 0.0
	if player.terrain_service != null:
		follow = (player.terrain_service.get_height_at(next) - player.terrain_service.get_height_at(here)) / delta
	player.velocity.x = heading.x * horizontal_speed
	player.velocity.z = heading.z * horizontal_speed
	player.velocity.y = follow + _settle_speed(cell.slope_angle)

	_orient_on_face(heading, delta)
	_track_climb_fatigue()


## Stay put on the face: no drift, settle onto the surface
func _hold_on_face(_delta: float) -> void:
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	var slope := player.current_cell.slope_angle if player.current_cell else 0.0
	player.velocity.y = _settle_speed(slope)


## Gentle vertical correction toward resting contact with the face
func _settle_speed(slope: float) -> float:
	var gap := _contact_height(player.global_position, slope) - player.global_position.y
	return clampf(gap * 4.0, -0.6, 0.6)


## Where the capsule rests on a slope: its round bottom touches the surface
## uphill of the centre, so the feet sit a little above the terrain below
func _contact_height(at: Vector3, slope: float) -> float:
	if player.terrain_service == null:
		return at.y
	var radius := 0.3
	if player.collision_shape != null and player.collision_shape.shape is CapsuleShape3D:
		radius = (player.collision_shape.shape as CapsuleShape3D).radius
	var cos_slope := cos(deg_to_rad(clampf(slope, 0.0, 80.0)))
	return player.terrain_service.get_height_at(at) + radius * (1.0 / cos_slope - 1.0)


## Face out on easy ground, side-on on moderate faces, into the slope when it
## steepens (the way a climber turns as the angle grows)
func _orient_on_face(heading: Vector3, delta: float) -> void:
	var cell := player.current_cell
	if cell == null or cell.slope_direction.length_squared() < 0.01:
		return
	var downhill := cell.slope_direction
	var target := Vector3.ZERO
	if cell.slope_angle >= 45.0:
		target = -downhill  # Face in
	else:
		# Side-on: whichever side is nearer the way we are going (or facing)
		var side := downhill.cross(Vector3.UP).normalized()
		var reference := heading if heading.length_squared() > 0.01 else player.get_facing_direction()
		target = side if side.dot(reference) >= 0.0 else -side
	_turn_toward(yaw_facing(target), turn_speed * 0.5, delta)


func _track_climb_fatigue() -> void:
	var height := player.global_position.y
	if is_nan(_climb_reference_height):
		_climb_reference_height = height
		return
	var change := height - _climb_reference_height
	if absf(change) < 1.0:
		return
	# Climbing back up is twice the work of going down
	var rate := downclimb_fatigue_per_metre * (2.0 if change > 0.0 else 1.0)
	player.add_fatigue(rate * absf(change))
	_climb_reference_height = height


# =============================================================================
# TRAVERSING STATE
# =============================================================================

func _update_traversing(delta: float) -> void:
	var input := player.input_handler.move_input

	if input.length() < 0.1:
		_apply_deceleration(delta)
		return

	# Traverse perpendicular to slope
	if player.current_cell:
		var slope_dir := player.current_cell.slope_direction
		var traverse_dir := slope_dir.cross(Vector3.UP).normalized()

		# Use input to choose left or right traverse
		if input.x < 0:
			traverse_dir = -traverse_dir

		move_direction = traverse_dir
		target_velocity = move_direction * player.traverse_speed
		_apply_acceleration(delta)

		_rotate_to_direction(delta)


# =============================================================================
# FALLING STATE
# =============================================================================

func _update_falling(delta: float) -> void:
	# A falling body can barely change where it goes; the landing is
	# resolved by PlayerController when it touches down
	var input := player.input_handler.move_input

	if input.length() > 0.1:
		var air_control := 1.0
		move_direction = _get_world_move_direction(input)
		player.velocity.x += move_direction.x * air_control * delta
		player.velocity.z += move_direction.z * air_control * delta


# =============================================================================
# RESTING STATE
# =============================================================================

func _update_resting(delta: float) -> void:
	# No movement while resting
	_apply_deceleration(delta)

	# Recover fatigue slowly
	if player.body_state:
		player.body_state.recover_fatigue(delta * 0.05)


# =============================================================================
# UTILITY
# =============================================================================

## Get horizontal speed
func get_horizontal_speed() -> float:
	return Vector2(player.velocity.x, player.velocity.z).length()


## Check if moving fast
func is_moving_fast() -> bool:
	return get_horizontal_speed() > player.base_walk_speed * 0.8


## Get the current slope angle
func get_current_slope() -> float:
	if player.current_cell:
		return player.current_cell.slope_angle
	return 0.0
