extends Node
## Central game state manager
## Autoloaded as GameStateManager
##
## Manages game state transitions, run lifecycle, and pause state

# =============================================================================
# STATE
# =============================================================================

## Current game state
var current_state: GameEnums.GameState = GameEnums.GameState.NONE

## Previous game state (for back navigation)
var previous_state: GameEnums.GameState = GameEnums.GameState.NONE

## Current run context (null when not in a run)
var current_run: RunContext = null

## Is the game paused
var is_paused: bool = false

## Valid state transitions
var _valid_transitions: Dictionary = {}

# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_setup_valid_transitions()
	_connect_signals()
	print("[GameStateManager] Initialized")


func _setup_valid_transitions() -> void:
	# Define valid state transitions
	_valid_transitions = {
		GameEnums.GameState.NONE: [
			GameEnums.GameState.MAIN_MENU
		],
		GameEnums.GameState.MAIN_MENU: [
			GameEnums.GameState.MOUNTAIN_SELECT,
			GameEnums.GameState.NONE  # Exit game
		],
		GameEnums.GameState.MOUNTAIN_SELECT: [
			GameEnums.GameState.LOADOUT_CONFIG,
			GameEnums.GameState.MAIN_MENU
		],
		GameEnums.GameState.LOADOUT_CONFIG: [
			GameEnums.GameState.PLANNING,
			GameEnums.GameState.MOUNTAIN_SELECT
		],
		GameEnums.GameState.PLANNING: [
			GameEnums.GameState.TUTORIAL,
			GameEnums.GameState.DESCENT,
			GameEnums.GameState.LOADOUT_CONFIG
		],
		GameEnums.GameState.TUTORIAL: [
			GameEnums.GameState.DESCENT,
			GameEnums.GameState.PLANNING
		],
		GameEnums.GameState.DESCENT: [
			GameEnums.GameState.PAUSED,
			GameEnums.GameState.MAP_CHECK,
			GameEnums.GameState.RESOLUTION
		],
		GameEnums.GameState.PAUSED: [
			GameEnums.GameState.DESCENT,
			GameEnums.GameState.MAP_CHECK,
			GameEnums.GameState.MAIN_MENU  # Abandon run
		],
		GameEnums.GameState.MAP_CHECK: [
			GameEnums.GameState.DESCENT,
			GameEnums.GameState.PAUSED
		],
		GameEnums.GameState.RESOLUTION: [
			GameEnums.GameState.POST_GAME
		],
		GameEnums.GameState.POST_GAME: [
			GameEnums.GameState.MAIN_MENU,
			GameEnums.GameState.PLANNING  # Retry same mountain
		]
	}


func _connect_signals() -> void:
	# Connect to relevant EventBus signals
	EventBus.fatal_event_completed.connect(_on_fatal_event_completed)


# =============================================================================
# STATE TRANSITIONS
# =============================================================================

## Attempt to transition to a new state
func transition_to(new_state: GameEnums.GameState) -> bool:
	if not _can_transition_to(new_state):
		push_warning("[GameStateManager] Invalid transition: %s -> %s" % [
			GameEnums.GameState.keys()[current_state],
			GameEnums.GameState.keys()[new_state]
		])
		return false

	var old_state := current_state
	previous_state = current_state
	current_state = new_state

	_handle_state_exit(old_state)
	_handle_state_enter(new_state)

	EventBus.game_state_changed.emit(old_state, new_state)

	print("[GameStateManager] State: %s -> %s" % [
		GameEnums.GameState.keys()[old_state],
		GameEnums.GameState.keys()[new_state]
	])

	return true


## Check if transition to state is valid
func _can_transition_to(new_state: GameEnums.GameState) -> bool:
	if not _valid_transitions.has(current_state):
		return false
	return new_state in _valid_transitions[current_state]


## Handle exiting a state
func _handle_state_exit(state: GameEnums.GameState) -> void:
	match state:
		GameEnums.GameState.DESCENT:
			# Ensure pause state is cleared
			if is_paused:
				_set_paused(false)
		GameEnums.GameState.PAUSED:
			_set_paused(false)


## Handle entering a state
func _handle_state_enter(state: GameEnums.GameState) -> void:
	match state:
		GameEnums.GameState.PAUSED:
			_set_paused(true)
		GameEnums.GameState.RESOLUTION:
			_handle_run_end()


# =============================================================================
# RUN MANAGEMENT
# =============================================================================

## Start a new run with given conditions
func start_run(mountain_id: String, conditions: StartConditions) -> RunContext:
	if current_run != null:
		push_warning("[GameStateManager] Abandoning existing run to start new one")
		_abandon_run()

	current_run = RunContext.create_new_run(mountain_id, conditions)
	current_run.start_elevation = 0.0  # Will be set by terrain system after spawn

	EventBus.run_started.emit(current_run)

	print("[GameStateManager] Run started: %s on %s" % [current_run.run_id, mountain_id])

	return current_run


## Get the current run context
func get_current_run() -> RunContext:
	return current_run


## Check if a run is active
func is_run_active() -> bool:
	return current_run != null and not current_run.is_complete


## Complete the current run
func complete_run(outcome: GameEnums.ResolutionType, cause: String = "") -> void:
	if current_run == null:
		push_warning("[GameStateManager] No run to complete")
		return

	current_run.complete_run(outcome, cause)
	EventBus.run_ended.emit(current_run, outcome)

	print("[GameStateManager] Run completed: %s - %s" % [
		GameEnums.ResolutionType.keys()[outcome],
		cause
	])

	# Transition to resolution state
	transition_to(GameEnums.GameState.RESOLUTION)


## Abandon the current run without completion
func _abandon_run() -> void:
	if current_run != null:
		current_run.complete_run(GameEnums.ResolutionType.FATALITY, "Run abandoned")
		current_run = null


func _handle_run_end() -> void:
	# The run context remains available for post-game analysis
	# It will be cleared when starting a new run or returning to menu
	pass


# =============================================================================
# PAUSE MANAGEMENT
# =============================================================================

## Toggle pause state
func toggle_pause() -> void:
	if current_state == GameEnums.GameState.DESCENT:
		transition_to(GameEnums.GameState.PAUSED)
	elif current_state == GameEnums.GameState.PAUSED:
		transition_to(GameEnums.GameState.DESCENT)


## Internal pause state setter
func _set_paused(paused: bool) -> void:
	if is_paused == paused:
		return

	is_paused = paused
	get_tree().paused = paused
	EventBus.pause_state_changed.emit(is_paused)


# =============================================================================
# MAP CHECK
# =============================================================================

## Enter map check mode (during descent or pause)
func enter_map_check() -> bool:
	if current_state != GameEnums.GameState.DESCENT and current_state != GameEnums.GameState.PAUSED:
		return false
	return transition_to(GameEnums.GameState.MAP_CHECK)


## Exit map check mode
func exit_map_check() -> bool:
	if current_state != GameEnums.GameState.MAP_CHECK:
		return false
	# Return to previous state (DESCENT or PAUSED)
	if previous_state == GameEnums.GameState.PAUSED:
		return transition_to(GameEnums.GameState.PAUSED)
	return transition_to(GameEnums.GameState.DESCENT)


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_fatal_event_completed() -> void:
	# When fatal event sequence finishes, complete the run
	if is_run_active():
		complete_run(GameEnums.ResolutionType.FATALITY, "Fatal incident")


# =============================================================================
# INPUT HANDLING
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		match current_state:
			GameEnums.GameState.DESCENT:
				toggle_pause()
			GameEnums.GameState.PAUSED:
				toggle_pause()
			GameEnums.GameState.MAP_CHECK:
				exit_map_check()

	if event.is_action_pressed("open_map"):
		if current_state == GameEnums.GameState.DESCENT:
			enter_map_check()


# =============================================================================
# DEBUG
# =============================================================================

## Get current state as string
func get_state_name() -> String:
	return GameEnums.GameState.keys()[current_state]


## Get a debug summary
func get_debug_info() -> Dictionary:
	return {
		"state": get_state_name(),
		"paused": is_paused,
		"run_active": is_run_active(),
		"run_id": current_run.run_id if current_run else "none"
	}
