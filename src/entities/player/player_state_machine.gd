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
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.SKIING,
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
		GameEnums.PlayerMovementState.SKIING,
		GameEnums.PlayerMovementState.ROPING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.RESTING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.DOWNCLIMBING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.TRAVERSING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.SKIING,
		GameEnums.PlayerMovementState.ROPING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.RESTING,
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
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.SKIING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.ARRESTED,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.ROPING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.FALLING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.SKIING,
		GameEnums.PlayerMovementState.ARRESTED,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.ARRESTED: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.SKIING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.RESTING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	],
	GameEnums.PlayerMovementState.INCAPACITATED: [
		# Can only be rescued or die from incapacitated
	],
	GameEnums.PlayerMovementState.SKIING: [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.SLIDING,
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.RESTING,
		GameEnums.PlayerMovementState.INCAPACITATED,
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
	states[GameEnums.PlayerMovementState.SKIING] = SkiingState.new(player)

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

	var next: PlayerState = states.get(new_state)
	if next == null:
		push_warning("[PlayerStateMachine] No state instance for: %s" % GameEnums.PlayerMovementState.keys()[new_state])
		return

	current_state = next
	state_time = 0.0
	current_state.enter()


## Where a climber ends up when an activity stops: on skis, clinging to a
## steep face, or standing
static func _back_on_feet(climber: PlayerController) -> GameEnums.PlayerMovementState:
	if climber.is_on_skis():
		return GameEnums.PlayerMovementState.SKIING
	var cell := climber.current_cell
	if cell != null and cell.slope_angle > PlayerController.DOWNCLIMB_ENTER_SLOPE:
		return GameEnums.PlayerMovementState.DOWNCLIMBING
	return GameEnums.PlayerMovementState.STANDING


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
		if player.is_on_skis():
			return GameEnums.PlayerMovementState.SKIING

		# Too steep to stand facing out: turn in and hold on
		var cell := player.current_cell
		if cell != null and cell.slope_angle > PlayerController.DOWNCLIMB_ENTER_SLOPE:
			return GameEnums.PlayerMovementState.DOWNCLIMBING

		if player.input_handler == null:
			return GameEnums.PlayerMovementState.STANDING

		# Check for movement input
		if player.input_handler.has_active_input():
			return GameEnums.PlayerMovementState.WALKING

		# Check for rest input
		if player.input_handler.is_action_just_pressed("check_self"):
			return GameEnums.PlayerMovementState.RESTING

		# Sitting down into a slide from a standstill is allowed too
		if player.input_handler.is_action_just_pressed("slide_initiate"):
			if player.can_initiate_slide():
				player.start_slide(false, "glissade")
				return player.current_state

		# Rope: the rope system decides whether there is anything to rope down
		if player.input_handler.is_action_just_pressed("rope_deploy"):
			player.request_rope()
			return player.current_state

		return GameEnums.PlayerMovementState.STANDING


# =============================================================================
# WALKING STATE
# =============================================================================

class WalkingState extends PlayerState:
	func enter() -> void:
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SPEED_CHANGE, 0.5)

	func check_transitions() -> GameEnums.PlayerMovementState:
		if player.is_on_skis():
			return GameEnums.PlayerMovementState.SKIING

		# No input -> standing
		if player.input_handler == null or not player.input_handler.has_active_input():
			return GameEnums.PlayerMovementState.STANDING

		# Steep terrain -> turn to the slope and downclimb
		var cell := player.current_cell
		if cell != null and cell.slope_angle > PlayerController.DOWNCLIMB_ENTER_SLOPE:
			return GameEnums.PlayerMovementState.DOWNCLIMBING

		# Slide initiation
		if player.input_handler.is_action_just_pressed("slide_initiate"):
			if player.can_initiate_slide():
				player.start_slide(false, "glissade")
				return player.current_state

		if player.input_handler.is_action_just_pressed("rope_deploy"):
			player.request_rope()
			return player.current_state

		return GameEnums.PlayerMovementState.WALKING


# =============================================================================
# DOWNCLIMBING STATE
# =============================================================================

class DownclimbingState extends PlayerState:
	func enter() -> void:
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SLOPE_CHANGE, 0.7)
		var cell := player.current_cell
		EventBus.record_decision("start_downclimb", {
			"slope": cell.slope_angle if cell != null else 0.0,
			"surface": GameEnums.SurfaceType.keys()[cell.surface_type] if cell != null else "unknown",
			"footwear": GameEnums.Footwear.keys()[player.footwear]
		})

	func check_transitions() -> GameEnums.PlayerMovementState:
		if player.is_on_skis():
			return GameEnums.PlayerMovementState.SKIING

		# Easier ground -> face out and walk
		var cell := player.current_cell
		if cell != null and cell.slope_angle < PlayerController.DOWNCLIMB_EXIT_SLOPE:
			if player.input_handler != null and player.input_handler.has_active_input():
				return GameEnums.PlayerMovementState.WALKING
			return GameEnums.PlayerMovementState.STANDING

		if player.input_handler == null:
			return GameEnums.PlayerMovementState.DOWNCLIMBING

		# Rope deployment
		if player.input_handler.is_action_just_pressed("rope_deploy"):
			player.request_rope()
			return player.current_state

		# Sit down and glissade the snow below
		if player.input_handler.is_action_just_pressed("slide_initiate"):
			if player.can_initiate_slide():
				player.start_slide(false, "glissade")
				return player.current_state

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
		# Note: slide_started is emitted by SlideSystem.begin_slide() with the
		# initialized slide state. Do not emit here to avoid duplicate signals.

	func exit() -> void:
		# Note: slide_ended is emitted by SlideSystem.end_slide() with the
		# actual outcome. Do not emit here to avoid duplicate signals
		# with a hardcoded CLEAN_STOP outcome.
		pass

	func update(_delta: float) -> void:
		# Sliding physics handled by SlideSystem
		# This is placeholder - full implementation in SlideSystem
		pass

	func check_transitions() -> GameEnums.PlayerMovementState:
		# SlideSystem ends the slide (stop, arrest, fall) and picks the next state;
		# if it is not running one, never leave the climber stuck sliding
		var slides := player.get_slide_system()
		if (slides == null or not slides.is_sliding) and player.state_time > 0.5:
			return PlayerStateMachine._back_on_feet(player)
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
		# R again: strip the anchor, unclip on a ledge, or build the next one
		if player.input_handler and player.input_handler.is_action_just_pressed("rope_deploy"):
			player.request_rope()
		# RopeService ends the rope work (off rope, cancelled, anchor failure);
		# with no rope work going on, step off the rope
		var rope := ServiceLocator.get_service("RopeService") as RopeService
		if (rope == null or rope.phase == RopeService.RopePhase.NONE) and player.state_time > 1.0 \
				and player.current_state == GameEnums.PlayerMovementState.ROPING:
			return PlayerStateMachine._back_on_feet(player)
		return player.current_state


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
		# PlayerController resolves the landing (impact, injury, where you end up)
		return GameEnums.PlayerMovementState.FALLING


# =============================================================================
# ARRESTED STATE
# =============================================================================

class ArrestedState extends PlayerState:
	## Seconds spent hanging on the axe before getting back on your feet
	const HOLD_TIME := 1.2

	var arrest_time: float = 0.0

	func enter() -> void:
		arrest_time = 0.0
		EventBus.record_incident("self_arrest", {
			"position": player.global_position if player else Vector3.ZERO,
			"slope": player.current_cell.slope_angle if player and player.current_cell else 0.0
		})

	func update(delta: float) -> void:
		arrest_time += delta

	func check_transitions() -> GameEnums.PlayerMovementState:
		if player == null or arrest_time < HOLD_TIME:
			return GameEnums.PlayerMovementState.ARRESTED
		# Kick in, stand up (or stay facing in if it is steep)
		if player.is_on_skis():
			return GameEnums.PlayerMovementState.SKIING
		var cell := player.current_cell
		if cell != null and cell.slope_angle > PlayerController.DOWNCLIMB_EXIT_SLOPE:
			return GameEnums.PlayerMovementState.DOWNCLIMBING
		return GameEnums.PlayerMovementState.STANDING


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


# =============================================================================
# SKIING STATE
# =============================================================================

class SkiingState extends PlayerState:
	func enter() -> void:
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SPEED_CHANGE, 0.6)
		EventBus.record_decision("start_skiing", {
			"position": player.global_position,
			"footwear": GameEnums.Footwear.keys()[player.footwear]
		})

	func check_transitions() -> GameEnums.PlayerMovementState:
		# SkiPhysics turns crashes into slides and falls
		if not player.is_on_skis():
			return GameEnums.PlayerMovementState.STANDING
		if player.input_handler != null and player.input_handler.is_action_just_pressed("check_self"):
			if player.smooth_velocity.length() < 0.5:
				return GameEnums.PlayerMovementState.RESTING
		if player.input_handler != null and player.input_handler.is_action_just_pressed("rope_deploy"):
			player.say("Take your skis off before you rope up.")
		return GameEnums.PlayerMovementState.SKIING
