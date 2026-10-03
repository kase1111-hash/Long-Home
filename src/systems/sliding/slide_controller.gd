class_name SlideController
extends Node
## Handles player input during sliding
## Provides indirect control - influence, not command
##
## Key inputs:
## - Lean (A/D or Q/E): push the slide sideways across its line
## - Brake (S, held): dig the heels in and drag the axe spike; builds up over
##   half a second and is worth a lot on soft snow, little on firm snow and
##   nothing on ice. With crampons on, the points can catch and flip you.
## - Tuck (W, held): lift the heels and lie back, a little faster
## - Self-arrest (Space): roll onto the axe and drive the pick in

# =============================================================================
# CONFIGURATION
# =============================================================================

## Sideways acceleration from a full lean on good snow (m/s^2)
var max_lean_force: float = 2.5

## Lean effectiveness lost per m/s of speed
var lean_speed_falloff: float = 0.03

## Control bonus from a set brake
var edge_control_max: float = 0.1

## How quickly the brake builds (per second)
var edge_buildup_rate: float = 2.5

## How quickly the brake releases (per second)
var edge_decay_rate: float = 4.0

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

## Current brake engagement (0 to 1): heels and spike in the snow
var edge_engagement: float = 0.0

## Is player actively braking
var is_engaging_edges: bool = false

## Is player tucked (heels up, lying back)
var tucked: bool = false

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

	# Brake: heels and spike dug in
	is_engaging_edges = Input.is_action_pressed("move_back")

	# Tuck: heels up, lie back
	tucked = Input.is_action_pressed("move_forward") and not is_engaging_edges

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
		edge_engagement = minf(1.0, edge_engagement + edge_buildup_rate * delta)
	else:
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
	# Space during a slide is always an arrest (it started the glissade too;
	# SlideSystem ignores the press that began the slide)
	if Input.is_action_just_pressed("slide_initiate"):
		slide_system.attempt_self_arrest()


func _reset_state() -> void:
	lean_input = 0.0
	edge_engagement = 0.0
	is_engaging_edges = false
	tucked = false
	time_since_commitment = 0.0
	hesitation_accumulated = 0.0
	is_committed = false
	input_direction = Vector2.ZERO


# =============================================================================
# FORCE CALCULATIONS
# =============================================================================

## Get the influence force (acceleration) from player input
func get_influence_force(_delta: float) -> Vector3:
	if not slide_system.is_sliding or slide_system.arrest_engaged:
		return Vector3.ZERO

	var state := slide_system.current_state
	if absf(lean_input) < 0.1 or state.velocity.length() < 0.5:
		return Vector3.ZERO

	# Leaning works through the snow: little on ice, nothing while tumbling
	var grip := clampf(TractionModel.brake_friction(state.surface_type, false) / 0.25, 0.15, 1.2)
	var effectiveness := maxf(1.0 - state.speed * lean_speed_falloff, 0.3)
	effectiveness *= state.control * grip

	var velocity_dir := state.velocity.normalized()
	var right := velocity_dir.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		return Vector3.ZERO
	return right.normalized() * lean_input * max_lean_force * effectiveness


## How hard the brake is set (0-1)
func get_brake_level() -> float:
	return edge_engagement


## Heels up and lying back
func is_tucked() -> bool:
	return tucked


## Kept for older callers: friction is now TractionModel.brake_friction * level
func get_edge_friction_bonus() -> float:
	return edge_engagement


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
		"tucked": tucked,
		"is_committed": is_committed,
		"hesitation": hesitation_accumulated
	}
