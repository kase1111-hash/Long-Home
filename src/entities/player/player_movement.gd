class_name PlayerMovement
extends Node
## Handles player movement physics and terrain interaction
## Works with PlayerController to move the player based on state

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
var slope_effect_start: float = 15.0

## Maximum slope for walking (beyond this requires downclimb)
var max_walk_slope: float = 35.0

## Uphill movement penalty multiplier
var uphill_penalty: float = 0.4

## Downhill movement bonus multiplier
var downhill_bonus: float = 1.3

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


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(controller: PlayerController) -> void:
	player = controller


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
			# Sliding is handled by SlideSystem
			pass
		GameEnums.PlayerMovementState.ROPING:
			# Roping is handled by RopeSystem
			pass
		GameEnums.PlayerMovementState.FALLING:
			_update_falling(delta)
		GameEnums.PlayerMovementState.RESTING:
			_update_resting(delta)


# =============================================================================
# STANDING STATE
# =============================================================================

func _update_standing(delta: float) -> void:
	var input := player.input_handler.move_input

	# Check for movement input
	if input.length() > 0.1:
		player.change_state(GameEnums.PlayerMovementState.WALKING)
		return

	# Apply deceleration
	_apply_deceleration(delta)

	# Stability recovery when standing still
	if player.stability < 1.0:
		player.set_stability(player.stability + delta * 0.3)


# =============================================================================
# WALKING STATE
# =============================================================================

func _update_walking(delta: float) -> void:
	var input := player.input_handler.move_input

	# Check for no input - return to standing
	if input.length() < 0.1:
		player.change_state(GameEnums.PlayerMovementState.STANDING)
		return

	# Check if terrain requires different state
	if player.current_cell:
		var slope := player.current_cell.slope_angle

		# Need to downclimb on steep terrain
		if slope > max_walk_slope and not player.current_cell.is_slideable:
			player.change_state(GameEnums.PlayerMovementState.DOWNCLIMBING)
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

	# Check for slide opportunity
	if player.input_handler.is_action_just_pressed("slide_initiate"):
		if player.can_initiate_slide():
			player.change_state(GameEnums.PlayerMovementState.SLIDING)


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


func _calculate_slope_factor() -> void:
	slope_factor = 1.0

	if player.current_cell == null:
		return

	var slope := player.current_cell.slope_angle
	if slope < slope_effect_start:
		return

	# Determine if moving uphill or downhill
	var slope_dir := player.current_cell.slope_direction
	var move_dot := move_direction.dot(slope_dir)

	is_uphill = move_dot < -0.3

	if is_uphill:
		# Moving uphill - penalty
		var uphill_factor := absf(move_dot)
		var slope_penalty := (slope - slope_effect_start) / (max_walk_slope - slope_effect_start)
		slope_factor = 1.0 - (slope_penalty * uphill_penalty * uphill_factor)
	else:
		# Moving downhill - slight bonus but more risk
		var downhill_factor := move_dot
		slope_factor = 1.0 + (downhill_factor * 0.2)

	slope_factor = clampf(slope_factor, 0.3, downhill_bonus)


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


func _rotate_to_direction(delta: float) -> void:
	if move_direction.length() < 0.1:
		return

	var target_rotation := atan2(move_direction.x, move_direction.z)
	var current_rotation := player.rotation.y

	var diff := wrapf(target_rotation - current_rotation, -PI, PI)
	var rotation_amount := signf(diff) * minf(absf(diff), turn_speed * delta)

	player.rotation.y += rotation_amount


func _track_distance(delta: float) -> void:
	var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
	distance_accumulator += horizontal_speed * delta

	if distance_accumulator >= fatigue_distance:
		distance_accumulator -= fatigue_distance

		# Add fatigue based on slope and speed
		var fatigue_amount := 0.01

		if is_uphill and player.current_cell:
			fatigue_amount *= 1.0 + (player.current_cell.slope_angle / 45.0)

		player.add_fatigue(fatigue_amount)


# =============================================================================
# DOWNCLIMBING STATE
# =============================================================================

func _update_downclimbing(delta: float) -> void:
	var input := player.input_handler.move_input

	# Downclimbing is slower and more deliberate
	if input.length() < 0.1:
		_apply_deceleration(delta)
		return

	# Check if we can return to walking
	if player.current_cell and player.current_cell.slope_angle < max_walk_slope:
		player.change_state(GameEnums.PlayerMovementState.WALKING)
		return

	# Move slowly in input direction
	move_direction = _get_world_move_direction(input)
	var target_speed := player.downclimb_speed

	# Apply body state modifier
	if player.body_state:
		target_speed *= player.body_state.get_movement_modifier()

	target_velocity = move_direction * target_speed
	_apply_acceleration(delta)

	# Face the slope (looking at terrain)
	if player.current_cell:
		var face_dir := -player.current_cell.slope_direction
		if face_dir.length() > 0.1:
			var target_rot := atan2(face_dir.x, face_dir.z)
			player.rotation.y = lerpf(player.rotation.y, target_rot, delta * 2.0)

	# Higher fatigue rate when downclimbing
	distance_accumulator += player.smooth_velocity.length() * delta
	if distance_accumulator >= fatigue_distance * 0.5:
		distance_accumulator = 0.0
		player.add_fatigue(0.02)

	# Stability affected by downclimbing
	var stability_drain := 0.1 * delta
	if player.current_cell:
		stability_drain *= player.current_cell.slope_angle / 45.0
	player.set_stability(player.stability - stability_drain)


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
	# Limited air control
	var input := player.input_handler.move_input

	if input.length() > 0.1:
		var air_control := 2.0
		move_direction = _get_world_move_direction(input)
		player.velocity.x += move_direction.x * air_control * delta
		player.velocity.z += move_direction.z * air_control * delta

	# Check for landing
	if player.is_grounded:
		_handle_landing()


func _handle_landing() -> void:
	var fall_speed := absf(player.smooth_velocity.y)

	if fall_speed < 5.0:
		# Soft landing
		player.change_state(GameEnums.PlayerMovementState.STANDING)
	elif fall_speed < 10.0:
		# Hard landing - stability loss
		player.set_stability(player.stability - 0.3)
		player.change_state(GameEnums.PlayerMovementState.STANDING)

		EventBus.record_incident("hard_landing", {
			"fall_speed": fall_speed
		})
	else:
		# Injury landing
		var injury_severity := (fall_speed - 10.0) / 20.0
		_apply_fall_injury(injury_severity)
		player.change_state(GameEnums.PlayerMovementState.INCAPACITATED)


func _apply_fall_injury(severity: float) -> void:
	if player.body_state == null:
		return

	# Determine injury type and location
	var injury_type := GameEnums.InjuryType.SPRAIN
	if severity > 0.5:
		injury_type = GameEnums.InjuryType.FRACTURE

	# Usually leg injuries from falls
	var location := GameEnums.BodyPart.LEFT_LEG
	if randf() > 0.5:
		location = GameEnums.BodyPart.RIGHT_LEG

	var injury := Injury.new(injury_type, severity, location, 0.0)
	player.body_state.add_injury(injury)

	EventBus.injury_occurred.emit(injury)
	EventBus.record_incident("fall_injury", {
		"severity": severity,
		"type": GameEnums.InjuryType.keys()[injury_type],
		"location": GameEnums.BodyPart.keys()[location]
	})


# =============================================================================
# RESTING STATE
# =============================================================================

func _update_resting(delta: float) -> void:
	# No movement while resting
	_apply_deceleration(delta)

	# Recover fatigue slowly
	if player.body_state:
		player.body_state.recover_fatigue(delta * 0.05)

	# Stability recovery
	player.set_stability(minf(1.0, player.stability + delta * 0.5))

	# Check for input to exit rest
	var input := player.input_handler.move_input
	if input.length() > 0.3:
		player.change_state(GameEnums.PlayerMovementState.STANDING)


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
