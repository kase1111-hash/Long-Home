class_name RopeDeploymentSystem
extends Node
## Manages the rope deployment state machine
## Handles the time-costly process of setting up for rappel
##
## Design Philosophy:
## - Rope deployment is slow and deliberate
## - Rushing increases failure probability
## - Players must commit to the process
## - Cancellation is possible but costly

# =============================================================================
# ENUMS
# =============================================================================

enum DeploymentState {
	IDLE,            # Not deploying
	SELECTING,       # Looking for anchor
	APPROACHING,     # Moving to anchor
	PLACING,         # Setting anchor (animation)
	TESTING,         # Brief pause to test
	THREADING,       # Threading rope through
	READY,           # Ready to rappel
	ABORTING         # Cancelling deployment
}


# =============================================================================
# SIGNALS
# =============================================================================

signal state_changed(old_state: DeploymentState, new_state: DeploymentState)
signal deployment_started()
signal deployment_complete(anchor: AnchorPoint, rope: Rope)
signal deployment_failed(reason: String)
signal deployment_cancelled()
signal progress_updated(progress: float, state: DeploymentState)
signal anchor_selected(anchor: AnchorPoint)
signal time_remaining_updated(seconds: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Timing")
## Base time to place anchor (seconds)
@export var base_place_time: float = 15.0
## Time to test anchor (seconds)
@export var test_time: float = 3.0
## Time to thread rope (seconds)
@export var thread_time: float = 8.0
## Time to abort (seconds)
@export var abort_time: float = 5.0

@export_group("Modifiers")
## Fatigue time multiplier (at max fatigue)
@export var fatigue_multiplier: float = 1.5
## Cold hands time multiplier
@export var cold_multiplier: float = 1.3
## Wind time multiplier (at strong wind)
@export var wind_multiplier: float = 1.4
## Wet rope time multiplier
@export var wet_rope_multiplier: float = 1.2


# =============================================================================
# STATE
# =============================================================================

## Current deployment state
var current_state: DeploymentState = DeploymentState.IDLE

## Selected anchor for deployment
var selected_anchor: AnchorPoint = null

## Rope being deployed
var deploying_rope: Rope = null

## Progress through current state (0-1)
var state_progress: float = 0.0

## Time spent in current state
var state_time: float = 0.0

## Target time for current state
var target_time: float = 0.0

## Player reference
var player: Node

## Anchor detector reference
var anchor_detector: AnchorDetector

## Rope inventory reference
var rope_inventory: RopeInventory

## Is deployment in progress
var is_deploying: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)
	ServiceLocator.register_service("RopeDeploymentSystem", self)


func _on_player_ready(service: Object) -> void:
	player = service


## Set dependencies
func initialize(detector: AnchorDetector, inventory: RopeInventory) -> void:
	anchor_detector = detector
	rope_inventory = inventory


# =============================================================================
# DEPLOYMENT LIFECYCLE
# =============================================================================

## Start the deployment process
func begin_deployment() -> bool:
	if current_state != DeploymentState.IDLE:
		return false

	if rope_inventory == null or not rope_inventory.has_usable_rope():
		deployment_failed.emit("No usable rope available")
		return false

	is_deploying = true
	_transition_to(DeploymentState.SELECTING)
	deployment_started.emit()

	return true


## Select an anchor for deployment
func select_anchor(anchor: AnchorPoint) -> bool:
	if current_state != DeploymentState.SELECTING:
		return false

	if anchor == null:
		return false

	selected_anchor = anchor
	anchor_selected.emit(anchor)

	# Get best rope for this deployment
	deploying_rope = rope_inventory.get_best_rope()
	if deploying_rope == null:
		deployment_failed.emit("No suitable rope")
		_transition_to(DeploymentState.IDLE)
		return false

	_transition_to(DeploymentState.APPROACHING)
	return true


## Confirm arrival at anchor (called by movement system)
func confirm_at_anchor() -> void:
	if current_state == DeploymentState.APPROACHING:
		_transition_to(DeploymentState.PLACING)


## Cancel deployment
func cancel_deployment() -> void:
	if current_state == DeploymentState.IDLE:
		return

	if current_state == DeploymentState.READY:
		# Already deployed, need to recover instead
		return

	_transition_to(DeploymentState.ABORTING)


## Force abort (emergency)
func force_abort() -> void:
	is_deploying = false
	selected_anchor = null
	deploying_rope = null
	_transition_to(DeploymentState.IDLE)
	deployment_cancelled.emit()


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not is_deploying:
		return

	match current_state:
		DeploymentState.PLACING:
			_update_timed_state(delta)
			if state_progress >= 1.0:
				_transition_to(DeploymentState.TESTING)

		DeploymentState.TESTING:
			_update_timed_state(delta)
			if state_progress >= 1.0:
				_complete_test()

		DeploymentState.THREADING:
			_update_timed_state(delta)
			if state_progress >= 1.0:
				_complete_threading()

		DeploymentState.ABORTING:
			_update_timed_state(delta)
			if state_progress >= 1.0:
				_complete_abort()

		_:
			pass


func _update_timed_state(delta: float) -> void:
	state_time += delta
	state_progress = clampf(state_time / target_time, 0.0, 1.0)

	progress_updated.emit(state_progress, current_state)
	time_remaining_updated.emit(target_time - state_time)


# =============================================================================
# STATE TRANSITIONS
# =============================================================================

func _transition_to(new_state: DeploymentState) -> void:
	var old_state := current_state
	current_state = new_state
	state_time = 0.0
	state_progress = 0.0

	# Set target time for timed states
	match new_state:
		DeploymentState.PLACING:
			target_time = _calculate_place_time()
		DeploymentState.TESTING:
			target_time = test_time
		DeploymentState.THREADING:
			target_time = _calculate_thread_time()
		DeploymentState.ABORTING:
			target_time = abort_time
		_:
			target_time = 0.0

	state_changed.emit(old_state, new_state)


func _complete_test() -> void:
	if selected_anchor == null:
		deployment_failed.emit("Anchor lost")
		_transition_to(DeploymentState.IDLE)
		return

	# Test the anchor (probabilistic)
	var test_load := 500.0  # N, body weight test
	var load_dir := Vector3.DOWN

	if selected_anchor.test_hold(test_load, load_dir):
		# Anchor holds, proceed
		_transition_to(DeploymentState.THREADING)
	else:
		# Anchor failed test
		deployment_failed.emit("Anchor failed test - find another")
		selected_anchor = null
		_transition_to(DeploymentState.SELECTING)


func _complete_threading() -> void:
	if deploying_rope == null or selected_anchor == null:
		deployment_failed.emit("Lost rope or anchor")
		_transition_to(DeploymentState.IDLE)
		return

	# Calculate deploy length based on terrain
	var deploy_length := _calculate_deploy_length()

	if rope_inventory.deploy(deploying_rope, deploy_length):
		selected_anchor.activate()
		is_deploying = false
		_transition_to(DeploymentState.READY)
		deployment_complete.emit(selected_anchor, deploying_rope)
	else:
		deployment_failed.emit("Failed to deploy rope")
		_transition_to(DeploymentState.IDLE)


func _complete_abort() -> void:
	is_deploying = false
	selected_anchor = null
	deploying_rope = null
	_transition_to(DeploymentState.IDLE)
	deployment_cancelled.emit()


# =============================================================================
# TIME CALCULATIONS
# =============================================================================

func _calculate_place_time() -> float:
	var time := base_place_time

	# Anchor difficulty
	if selected_anchor:
		time += selected_anchor.get_placement_difficulty() * 10.0

	# Apply modifiers
	time *= _get_condition_multiplier()

	return time


func _calculate_thread_time() -> float:
	var time := thread_time

	# Wet rope is slower
	if deploying_rope and deploying_rope.is_wet:
		time *= wet_rope_multiplier

	# Frozen rope much slower
	if deploying_rope and deploying_rope.is_frozen:
		time *= 2.0

	# Apply condition modifiers
	time *= _get_condition_multiplier()

	return time


func _get_condition_multiplier() -> float:
	var multiplier := 1.0

	if player == null:
		return multiplier

	# Fatigue
	if player.has_method("get_fatigue"):
		var fatigue: float = player.get_fatigue()
		multiplier *= 1.0 + fatigue * (fatigue_multiplier - 1.0)

	# Cold (would check body state)
	# multiplier *= cold_multiplier based on hand warmth

	# Wind (would check weather service)
	# multiplier *= wind_multiplier based on wind strength

	return multiplier


func _calculate_deploy_length() -> float:
	# Would calculate based on terrain below
	# For now, use reasonable default or rope length
	if deploying_rope:
		return minf(deploying_rope.available_length, 30.0)
	return 30.0


# =============================================================================
# QUERIES
# =============================================================================

## Get current state
func get_state() -> DeploymentState:
	return current_state


## Get state name for UI/debug
func get_state_name() -> String:
	return DeploymentState.keys()[current_state]


## Check if ready to rappel
func is_ready() -> bool:
	return current_state == DeploymentState.READY


## Check if can start deployment
func can_deploy() -> bool:
	if current_state != DeploymentState.IDLE:
		return false
	if rope_inventory == null or not rope_inventory.has_usable_rope():
		return false
	return true


## Get deployment progress info
func get_progress_info() -> Dictionary:
	return {
		"state": get_state_name(),
		"progress": state_progress,
		"time_elapsed": state_time,
		"time_remaining": maxf(0.0, target_time - state_time),
		"anchor": selected_anchor,
		"rope": deploying_rope
	}


## Get total estimated time for full deployment
func get_estimated_total_time() -> float:
	var total := base_place_time + test_time + thread_time
	total *= _get_condition_multiplier()

	if selected_anchor:
		total += selected_anchor.get_placement_difficulty() * 10.0

	return total
