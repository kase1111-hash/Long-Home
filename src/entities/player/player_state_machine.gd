class_name PlayerStateMachine
extends Node
## Manages player movement state transitions
## Validates and executes state changes

# =============================================================================
# STATE CONFIGURATION
# =============================================================================

## Valid transitions from each state
var transitions: Dictionary = {
	GameEnums.PlayerMovementState.STANDING: [
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.ROPING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.RESTING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.WALKING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.TRAVERSING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.ROPING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.RESTING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.DOWNCLIMBING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.TRAVERSING,
		GameEnums.PlayerMovementState.ROPING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.TRAVERSING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.SLIDING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.ARRESTED,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.ROPING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.FALLING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.ARRESTED,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.ARRESTED: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.RESTING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.INCAPACITATED: [
		# Can only be rescued or die from incapacitated
	],
}

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Current state instance
var current_state: PlayerState

## All state instances
var states: Dictionary = {}

## Time in current state
var state_time: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(controller: PlayerController) -> void:
	player = controller
	_create_states()


func _create_states() -> void:
	states[GameEnums.PlayerMovementState.STANDING] = StandingState.new(player)
	states[GameEnums.PlayerMovementState.WALKING] = WalkingState.new(player)
	states[GameEnums.PlayerMovementState.DOWNCLIMBING] = DownclimbingState.new(player)
	states[GameEnums.PlayerMovementState.TRAVERSING] = TraversingState.new(player)
	states[GameEnums.PlayerMovementState.SLIDING] = SlidingState.new(player)
	states[GameEnums.PlayerMovementState.ROPING] = RopingState.new(player)
	states[GameEnums.PlayerMovementState.FALLING] = FallingState.new(player)
	states[GameEnums.PlayerMovementState.ARRESTED] = ArrestedState.new(player)
	states[GameEnums.PlayerMovementState.RESTING] = RestingState.new(player)
	states[GameEnums.PlayerMovementState.INCAPACITATED] = IncapacitatedState.new(player)

	# Set initial state
	current_state = states[GameEnums.PlayerMovementState.STANDING]


# =============================================================================
# UPDATE
# =============================================================================

func update(delta: float) -> void:
	if player == null:
		return

	state_time += delta

	if current_state:
		current_state.update(delta)

		# Check for automatic transitions
		var next_state := current_state.check_transitions()
		if next_state != player.current_state:
			player.change_state(next_state)


# =============================================================================
# STATE TRANSITIONS
# =============================================================================

## Check if transition is valid
func can_transition_to(from_state: GameEnums.PlayerMovementState, to_state: GameEnums.PlayerMovementState) -> bool:
	if not transitions.has(from_state):
		return false
	return to_state in transitions[from_state]


## Execute transition to new state
func transition_to(new_state: GameEnums.PlayerMovementState) -> void:
	if current_state:
		current_state.exit()

	var next := states.get(new_state)
	if next == null:
		push_warning("[PlayerStateMachine] No state instance for: %s" % GameEnums.PlayerMovementState.keys()[new_state])
		return

	current_state = next
	state_time = 0.0
	current_state.enter()


# =============================================================================
# BASE STATE CLASS
# =============================================================================

class PlayerState:
	var player: PlayerController

	func _init(controller: PlayerController) -> void:
		player = controller

	func enter() -> void:
		pass

	func exit() -> void:
		pass

	func update(_delta: float) -> void:
		pass

	func check_transitions() -> GameEnums.PlayerMovementState:
		return player.current_state


# =============================================================================
# STANDING STATE
# =============================================================================

class StandingState extends PlayerState:
	func enter() -> void:
		# Emit camera signal
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SPEED_CHANGE, 0.3)

	func check_transitions() -> GameEnums.PlayerMovementState:
		# Check for movement input
		if player.input_handler and player.input_handler.has_active_input():
			return GameEnums.PlayerMovementState.WALKING

		# Check for rest input
		if player.input_handler and player.input_handler.is_action_just_pressed("check_self"):
			return GameEnums.PlayerMovementState.RESTING

		# Check for rope deployment
		if player.input_handler and player.input_handler.is_action_just_pressed("rope_deploy"):
			var cell := player.current_cell
			if player.needs_rope() or (cell != null and cell.slope_angle > 40):
				return GameEnums.PlayerMovementState.ROPING

		return GameEnums.PlayerMovementState.STANDING


# =============================================================================
# WALKING STATE
# =============================================================================

class WalkingState extends PlayerState:
	func enter() -> void:
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SPEED_CHANGE, 0.5)

	func check_transitions() -> GameEnums.PlayerMovementState:
		# No input -> standing
		if player.input_handler == null or not player.input_handler.has_active_input():
			return GameEnums.PlayerMovementState.STANDING

		# Steep terrain -> downclimbing
		var cell := player.current_cell
		if cell != null:
			if cell.slope_angle > 35 and not cell.is_slideable:
				return GameEnums.PlayerMovementState.DOWNCLIMBING

		# Slide initiation
		if player.input_handler and player.input_handler.is_action_just_pressed("slide_initiate"):
			if player.can_initiate_slide():
				return GameEnums.PlayerMovementState.SLIDING

		return GameEnums.PlayerMovementState.WALKING


# =============================================================================
# DOWNCLIMBING STATE
# =============================================================================

class DownclimbingState extends PlayerState:
	func enter() -> void:
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SLOPE_CHANGE, 0.7)
		var cell := player.current_cell
		EventBus.record_decision("start_downclimb", {
			"slope": cell.slope_angle if cell != null else 0.0
		})

	func check_transitions() -> GameEnums.PlayerMovementState:
		# Moderate terrain -> walking
		var cell := player.current_cell
		if cell != null and cell.slope_angle < 30:
			return GameEnums.PlayerMovementState.WALKING

		# Rope deployment
		if player.input_handler and player.input_handler.is_action_just_pressed("rope_deploy"):
			return GameEnums.PlayerMovementState.ROPING

		return GameEnums.PlayerMovementState.DOWNCLIMBING


# =============================================================================
# TRAVERSING STATE
# =============================================================================

class TraversingState extends PlayerState:
	func check_transitions() -> GameEnums.PlayerMovementState:
		if player.input_handler == null or not player.input_handler.has_active_input():
			return GameEnums.PlayerMovementState.STANDING

		# Check if no longer on traverse terrain
		var cell := player.current_cell
		if cell != null and cell.slope_angle < 20:
			return GameEnums.PlayerMovementState.WALKING

		return GameEnums.PlayerMovementState.TRAVERSING


# =============================================================================
# SLIDING STATE
# =============================================================================

class SlidingState extends PlayerState:
	func enter() -> void:
		if player == null:
			return
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SLIDE_ENTRY, 1.0)
		var cell := player.current_cell
		var slope_angle := cell.slope_angle if cell != null else 0.0
		var speed := player.smooth_velocity.length() if player.smooth_velocity else 0.0
		EventBus.record_decision("start_slide", {
			"position": player.global_position,
			"slope": slope_angle,
			"speed": speed
		})
		EventBus.slide_started.emit(speed, slope_angle)

	func exit() -> void:
		var speed := player.smooth_velocity.length() if player and player.smooth_velocity else 0.0
		EventBus.slide_ended.emit(GameEnums.SlideOutcome.CLEAN_STOP, speed)

	func update(_delta: float) -> void:
		# Sliding physics handled by SlideSystem
		# This is placeholder - full implementation in SlideSystem
		pass

	func check_transitions() -> GameEnums.PlayerMovementState:
		if player == null:
			return GameEnums.PlayerMovementState.SLIDING
		var cell := player.current_cell
		var is_slow := player.smooth_velocity.length() < 2.0 if player.smooth_velocity else true

		# Exit slide when slope decreases and speed low
		if cell != null:
			var is_flat := cell.slope_angle < 20

			if is_flat and is_slow:
				return GameEnums.PlayerMovementState.STANDING

			# Check for exit zone
			if cell.is_exit_zone and is_slow:
				return GameEnums.PlayerMovementState.STANDING
		elif is_slow:
			# No terrain data but moving slowly - exit slide
			return GameEnums.PlayerMovementState.STANDING

		return GameEnums.PlayerMovementState.SLIDING


# =============================================================================
# ROPING STATE
# =============================================================================

class RopingState extends PlayerState:
	var rope_time: float = 0.0
	var deployment_time: float = 5.0  # Time to deploy rope

	func enter() -> void:
		rope_time = 0.0
		EventBus.emit_camera_signal(GameEnums.CameraSignal.ROPE_DEPLOYMENT, 0.8)
		EventBus.record_decision("deploy_rope", {
			"position": player.global_position
		})

	func update(delta: float) -> void:
		rope_time += delta
		# Rope deployment logic handled by RopeSystem

	func check_transitions() -> GameEnums.PlayerMovementState:
		# Roping completes -> standing (at bottom of rope)
		# This would be controlled by RopeSystem
		return GameEnums.PlayerMovementState.ROPING


# =============================================================================
# FALLING STATE
# =============================================================================

class FallingState extends PlayerState:
	func enter() -> void:
		EventBus.emit_camera_signal(GameEnums.CameraSignal.MICRO_SLIP, 1.0)
		EventBus.record_incident("fall_started", {
			"position": player.global_position,
			"velocity": player.velocity
		})

	func check_transitions() -> GameEnums.PlayerMovementState:
		# Landing handled by PlayerMovement
		if player.is_grounded:
			return GameEnums.PlayerMovementState.STANDING

		return GameEnums.PlayerMovementState.FALLING


# =============================================================================
# ARRESTED STATE
# =============================================================================

class ArrestedState extends PlayerState:
	var arrest_time: float = 0.0

	func enter() -> void:
		arrest_time = 0.0
		var speed := player.smooth_velocity.length() if player and player.smooth_velocity else 0.0
		EventBus.record_incident("self_arrest", {
			"position": player.global_position if player else Vector3.ZERO,
			"speed": speed
		})

	func update(delta: float) -> void:
		arrest_time += delta
		# Gradually stop

	func check_transitions() -> GameEnums.PlayerMovementState:
		if player == null:
			return GameEnums.PlayerMovementState.ARRESTED
		var current_speed := player.smooth_velocity.length() if player.smooth_velocity else 0.0
		if current_speed < 0.5:
			return GameEnums.PlayerMovementState.STANDING

		# Failed arrest -> continue sliding or falling
		if arrest_time > 3.0:
			var cell := player.current_cell
			if cell != null and cell.is_slideable:
				return GameEnums.PlayerMovementState.SLIDING
			else:
				return GameEnums.PlayerMovementState.FALLING

		return GameEnums.PlayerMovementState.ARRESTED


# =============================================================================
# RESTING STATE
# =============================================================================

class RestingState extends PlayerState:
	func enter() -> void:
		if player.input_handler:
			player.input_handler.start_self_check()

	func exit() -> void:
		if player.input_handler:
			player.input_handler.end_self_check()

	func check_transitions() -> GameEnums.PlayerMovementState:
		# Any significant input exits rest
		if player.input_handler and player.input_handler.has_active_input():
			return GameEnums.PlayerMovementState.STANDING

		return GameEnums.PlayerMovementState.RESTING


# =============================================================================
# INCAPACITATED STATE
# =============================================================================

class IncapacitatedState extends PlayerState:
	func enter() -> void:
		EventBus.record_incident("incapacitated", {
			"position": player.global_position,
			"body_state": player.body_state.duplicate_state() if player.body_state else null
		})

	func check_transitions() -> GameEnums.PlayerMovementState:
		# Cannot transition out on own - requires rescue or ends run
		return GameEnums.PlayerMovementState.INCAPACITATED
