class_name PlayerInput
extends Node
## Handles player input with fatigue-based delay and hesitation penalties
## Creates the "judgment under fatigue" feel

# =============================================================================
# CONFIGURATION
# =============================================================================

## Maximum input delay in seconds
var max_input_delay: float = 0.3

## Hesitation penalty multiplier
var hesitation_penalty_rate: float = 0.1

## Time before hesitation penalty kicks in
var hesitation_threshold: float = 0.5

## Input deadzone
var deadzone: float = 0.15

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Current movement input (processed)
var move_input: Vector2 = Vector2.ZERO

## Raw movement input (unprocessed)
var raw_move_input: Vector2 = Vector2.ZERO

## Input buffer for delayed inputs
var input_buffer: Array[Dictionary] = []

## Current input delay
var current_delay: float = 0.0

## Time input has been held without action
var hesitation_time: float = 0.0

## Actions pressed this frame
var actions_just_pressed: Dictionary = {}

## Actions held
var actions_held: Dictionary = {}

## Last lean input
var lean_input: float = 0.0

## Is looking at map
var is_map_open: bool = false

## Is checking self
var is_self_checking: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(controller: PlayerController) -> void:
	player = controller


# =============================================================================
# UPDATE
# =============================================================================

func update(delta: float, delay: float) -> void:
	current_delay = delay

	# Read raw input
	_read_raw_input()

	# Process input with delay
	_process_buffered_input(delta)

	# Update hesitation
	_update_hesitation(delta)

	# Update action states
	_update_actions()


func _read_raw_input() -> void:
	# Movement input
	raw_move_input = Vector2.ZERO

	if Input.is_action_pressed("move_forward"):
		raw_move_input.y -= 1.0
	if Input.is_action_pressed("move_back"):
		raw_move_input.y += 1.0
	if Input.is_action_pressed("move_left"):
		raw_move_input.x -= 1.0
	if Input.is_action_pressed("move_right"):
		raw_move_input.x += 1.0

	# Apply deadzone
	if raw_move_input.length() < deadzone:
		raw_move_input = Vector2.ZERO
	elif raw_move_input.length() > 1.0:
		raw_move_input = raw_move_input.normalized()

	# Lean input
	lean_input = 0.0
	if Input.is_action_pressed("lean_left"):
		lean_input -= 1.0
	if Input.is_action_pressed("lean_right"):
		lean_input += 1.0


func _process_buffered_input(delta: float) -> void:
	if current_delay <= 0.001:
		# No delay - direct input
		move_input = raw_move_input
		return

	# Add current input to buffer
	input_buffer.append({
		"input": raw_move_input,
		"time": current_delay
	})

	# Process buffer
	var processed := []
	for entry in input_buffer:
		entry.time -= delta
		if entry.time <= 0:
			processed.append(entry)

	# Use oldest ready input
	if processed.size() > 0:
		move_input = processed[0].input
		for entry in processed:
			input_buffer.erase(entry)
	else:
		# No input ready - use last processed or zero
		if input_buffer.size() > 0:
			# Partial responsiveness - blend toward buffered input
			var target: Vector2 = input_buffer[0].input
			var blend := 1.0 - (input_buffer[0].time / current_delay)
			move_input = move_input.lerp(target, blend * 0.5)

	# Limit buffer size
	while input_buffer.size() > 10:
		input_buffer.pop_front()


func _update_hesitation(delta: float) -> void:
	# Track hesitation when player has input but isn't committing
	if raw_move_input.length() > 0.1:
		hesitation_time += delta

		# Hesitation penalty affects stability
		if hesitation_time > hesitation_threshold:
			var penalty := (hesitation_time - hesitation_threshold) * hesitation_penalty_rate * delta
			player.set_stability(player.stability - penalty)
	else:
		hesitation_time = 0.0


func _update_actions() -> void:
	# Track action presses
	var action_names := [
		"slide_initiate",
		"rope_deploy",
		"check_self",
		"open_map"
	]

	for action in action_names:
		var was_pressed: bool = actions_held.get(action, false)
		var is_pressed: bool = Input.is_action_pressed(action)

		actions_just_pressed[action] = is_pressed and not was_pressed
		actions_held[action] = is_pressed


# =============================================================================
# INPUT QUERIES
# =============================================================================

## Check if an action was just pressed
func is_action_just_pressed(action: String) -> bool:
	return actions_just_pressed.get(action, false)


## Check if an action is held
func is_action_held(action: String) -> bool:
	return actions_held.get(action, false)


## Get lean input (-1 to 1)
func get_lean_input() -> float:
	return lean_input


## Check if player is actively inputting
func has_active_input() -> bool:
	return raw_move_input.length() > deadzone


## Get input direction normalized
func get_input_direction() -> Vector2:
	if move_input.length() < deadzone:
		return Vector2.ZERO
	return move_input.normalized()


## Get input magnitude (0-1)
func get_input_magnitude() -> float:
	return clampf(move_input.length(), 0.0, 1.0)


## Check if input is forward
func is_moving_forward() -> bool:
	return move_input.y < -deadzone


## Check if input is backward
func is_moving_backward() -> bool:
	return move_input.y > deadzone


## Check if input is strafing
func is_strafing() -> bool:
	return absf(move_input.x) > absf(move_input.y)


# =============================================================================
# SPECIAL ACTIONS
# =============================================================================

## Start self-check
func start_self_check() -> void:
	is_self_checking = true
	EventBus.self_check_started.emit()


## End self-check
func end_self_check() -> void:
	is_self_checking = false
	if player.body_state:
		EventBus.self_check_completed.emit(player.body_state)


## Open map
func open_map() -> void:
	is_map_open = true
	EventBus.map_opened.emit()


## Close map
func close_map() -> void:
	is_map_open = false
	EventBus.map_closed.emit()


# =============================================================================
# DEBUG
# =============================================================================

func get_debug_info() -> Dictionary:
	return {
		"raw_input": raw_move_input,
		"processed_input": move_input,
		"current_delay": current_delay,
		"buffer_size": input_buffer.size(),
		"hesitation_time": hesitation_time,
		"lean": lean_input
	}
