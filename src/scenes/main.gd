extends Node
## Main scene controller
## Entry point for the game

# =============================================================================
# REFERENCES
# =============================================================================

@onready var world: Node3D = $World
@onready var ui: CanvasLayer = $UI

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	print("[Main] Long Home starting...")
	print("[Main] Version: 0.1.0")

	_initialize_game()


func _initialize_game() -> void:
	# Wait for autoloads to be ready
	await get_tree().process_frame

	# Connect to core signals
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.run_started.connect(_on_run_started)
	EventBus.run_ended.connect(_on_run_ended)

	# Transition to main menu
	GameStateManager.transition_to(GameEnums.GameState.MAIN_MENU)

	print("[Main] Initialization complete")

	# For testing: Start a quick run with default conditions
	if OS.is_debug_build():
		_debug_quick_start()


# =============================================================================
# DEBUG
# =============================================================================

func _debug_quick_start() -> void:
	# Quick start for development testing
	print("[Main] DEBUG: Quick start enabled")

	# Create test conditions
	var conditions := StartConditions.create_moderate()

	# Start a test run
	GameStateManager.transition_to(GameEnums.GameState.MOUNTAIN_SELECT)
	GameStateManager.transition_to(GameEnums.GameState.LOADOUT_CONFIG)
	GameStateManager.transition_to(GameEnums.GameState.PLANNING)

	var run := GameStateManager.start_run("test_mountain", conditions)
	print("[Main] Test run created: %s" % run.run_id)

	GameStateManager.transition_to(GameEnums.GameState.DESCENT)


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	print("[Main] Game state: %s -> %s" % [
		GameEnums.GameState.keys()[old_state],
		GameEnums.GameState.keys()[new_state]
	])

	match new_state:
		GameEnums.GameState.MAIN_MENU:
			_show_main_menu()
		GameEnums.GameState.DESCENT:
			_start_descent()
		GameEnums.GameState.RESOLUTION:
			_show_resolution()
		GameEnums.GameState.POST_GAME:
			_show_post_game()


func _on_run_started(run_context: RunContext) -> void:
	print("[Main] Run started: %s" % run_context.run_id)
	print("[Main] Difficulty: %.2f" % run_context.start_conditions.get_difficulty_score())


func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	print("[Main] Run ended: %s" % GameEnums.ResolutionType.keys()[outcome])
	var summary := run_context.get_run_summary()
	print("[Main] Summary: %s" % str(summary))


# =============================================================================
# STATE HANDLERS
# =============================================================================

func _show_main_menu() -> void:
	# TODO: Load main menu scene
	print("[Main] Showing main menu...")


func _start_descent() -> void:
	# TODO: Initialize descent gameplay
	print("[Main] Starting descent...")


func _show_resolution() -> void:
	# TODO: Show resolution screen
	print("[Main] Showing resolution...")


func _show_post_game() -> void:
	# TODO: Show post-game analysis
	print("[Main] Showing post-game...")


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	# Debug shortcuts
	if OS.is_debug_build():
		if event.is_action_pressed("ui_home"):
			# Print debug info
			print("=== DEBUG INFO ===")
			print("GameState: %s" % GameStateManager.get_debug_info())
			print("Services: %s" % ServiceLocator.get_debug_info())
			if GameStateManager.current_run:
				print("Run: %s" % GameStateManager.current_run.get_run_summary())
