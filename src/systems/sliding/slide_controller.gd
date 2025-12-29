class_name SlideController
extends Node
## Handles player input during sliding
## Provides indirect control - influence, not command
##
## Key inputs:
## - Lean (left/right): Affects trajectory
## - Edge engagement: Affects friction/control
## - Arrest attempt: Try to stop

# =============================================================================
# CONFIGURATION
# =============================================================================

## Maximum lean force
var max_lean_force: float = 3.0

## Lean effectiveness at different speeds (reduces with speed)
var lean_speed_falloff: float = 0.05

## Edge engagement friction bonus
var edge_friction_max: float = 0.1

## Edge engagement control bonus
var edge_control_max: float = 0.15

## How quickly edge engagement builds
var edge_buildup_rate: float = 2.0

## How quickly edge engagement decays
var edge_decay_rate: float = 3.0

## Commitment time - hesitation penalty window
var commitment_window: float = 0.3

## Hesitation control penalty per second
var hesitation_penalty: float = 0.1

# =============================================================================
# STATE
# =============================================================================

## Reference to slide system
var slide_system: SlideSystem

## Current lean input (-1 to 1)
var lean_input: float = 0.0

## Current edge engagement (0 to 1)
var edge_engagement: float = 0.0

## Is player actively engaging edges
var is_engaging_edges: bool = false

## Time since last committed input
var time_since_commitment: float = 0.0

## Accumulated hesitation penalty
var hesitation_accumulated: float = 0.0

## Input direction for trajectory influence
var input_direction: Vector2 = Vector2.ZERO

## Has player committed to this slide
var is_committed: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(system: SlideSystem) -> void:
	slide_system = system


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not slide_system.is_sliding:
		_reset_state()
		return

	_read_input()
	_update_edge_engagement(delta)
	_update_hesitation(delta)
	_check_arrest_input()


func _read_input() -> void:
	# Lean input from dedicated lean keys or analog stick
	lean_input = 0.0

	if Input.is_action_pressed("lean_left"):
		lean_input -= 1.0
	if Input.is_action_pressed("lean_right"):
		lean_input += 1.0

	# Also accept strafe keys for lean during slide
	if Input.is_action_pressed("move_left"):
		lean_input -= 0.7
	if Input.is_action_pressed("move_right"):
		lean_input += 0.7

	lean_input = clampf(lean_input, -1.0, 1.0)

	# Edge engagement from backward input (digging in)
	is_engaging_edges = Input.is_action_pressed("move_back")

	# Forward input reduces friction (tuck)
	if Input.is_action_pressed("move_forward"):
		edge_engagement = maxf(0, edge_engagement - 0.5)

	# Track if player has any input (commitment)
	input_direction = Vector2(lean_input, 0)
	if Input.is_action_pressed("move_forward"):
		input_direction.y = -1
	if Input.is_action_pressed("move_back"):
		input_direction.y = 1

	if input_direction.length() > 0.1:
		is_committed = true
		time_since_commitment = 0.0


func _update_edge_engagement(delta: float) -> void:
	if is_engaging_edges:
		# Build up edge engagement
		edge_engagement = minf(1.0, edge_engagement + edge_buildup_rate * delta)
	else:
		# Decay edge engagement
		edge_engagement = maxf(0.0, edge_engagement - edge_decay_rate * delta)


func _update_hesitation(delta: float) -> void:
	time_since_commitment += delta

	# If no commitment in window, accumulate penalty
	if time_since_commitment > commitment_window and not is_committed:
		hesitation_accumulated += hesitation_penalty * delta
		hesitation_accumulated = minf(hesitation_accumulated, 0.5)
	else:
		# Slowly recover from hesitation
		hesitation_accumulated = maxf(0, hesitation_accumulated - delta * 0.1)


func _check_arrest_input() -> void:
	# Check for self-arrest attempt (usually a quick action)
	if Input.is_action_just_pressed("slide_initiate"):  # Same key, context-dependent
		# At high speed, this becomes arrest attempt
		if slide_system.current_state.speed > 5.0:
			slide_system.attempt_self_arrest()


func _reset_state() -> void:
	lean_input = 0.0
	edge_engagement = 0.0
	is_engaging_edges = false
	time_since_commitment = 0.0
	hesitation_accumulated = 0.0
	is_committed = false
	input_direction = Vector2.ZERO


# =============================================================================
# FORCE CALCULATIONS
# =============================================================================

## Get the influence force from player input
func get_influence_force(delta: float) -> Vector3:
	if not slide_system.is_sliding:
		return Vector3.ZERO

	var force := Vector3.ZERO
	var state := slide_system.current_state

	# Calculate lean effectiveness (reduces with speed)
	var lean_effectiveness := 1.0 - (state.speed * lean_speed_falloff)
	lean_effectiveness = maxf(lean_effectiveness, 0.2)

	# Apply control level modifier
	lean_effectiveness *= state.control

	# Calculate lean force perpendicular to velocity
	if absf(lean_input) > 0.1 and state.velocity.length() > 0.5:
		var velocity_dir := state.velocity.normalized()
		var right := velocity_dir.cross(Vector3.UP).normalized()

		var lean_force := right * lean_input * max_lean_force * lean_effectiveness
		force += lean_force

	return force


## Get friction bonus from edge engagement
func get_edge_friction_bonus() -> float:
	return edge_engagement * edge_friction_max


## Get control bonus from edge engagement
func get_control_bonus() -> float:
	var bonus := edge_engagement * edge_control_max

	# Reduce by hesitation penalty
	bonus -= hesitation_accumulated

	return maxf(0, bonus)


# =============================================================================
# QUERIES
# =============================================================================

## Get current lean value
func get_lean() -> float:
	return lean_input


## Get edge engagement level
func get_edge_level() -> float:
	return edge_engagement


## Check if player is hesitating
func is_hesitating() -> bool:
	return time_since_commitment > commitment_window * 2


## Get input state for UI/feedback
func get_input_state() -> Dictionary:
	return {
		"lean": lean_input,
		"edge_engagement": edge_engagement,
		"is_engaging": is_engaging_edges,
		"is_committed": is_committed,
		"hesitation": hesitation_accumulated
	}
