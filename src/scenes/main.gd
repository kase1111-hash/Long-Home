extends Node
## Main scene controller
## Entry point for the game

# =============================================================================
# REFERENCES
# =============================================================================

@onready var world: Node3D = $World
@onready var ui: CanvasLayer = $UI

# =============================================================================
# UI SCENES
# =============================================================================

const MainMenuScene := preload("res://src/ui/main_menu.tscn")
const PlayerScene := preload("res://src/entities/player/player.tscn")
const ResolutionScreenScene := preload("res://src/ui/resolution_screen.tscn")
const PostGameScreenScene := preload("res://src/ui/post_game_screen.tscn")
const MountainSelectScene := preload("res://src/ui/selection/mountain_select_screen.tscn")
const LoadoutConfigScene := preload("res://src/ui/selection/loadout_config_screen.tscn")
const PlanningScene := preload("res://src/ui/planning/planning_screen.tscn")
const PauseMenuScene := preload("res://src/ui/pause/pause_menu.tscn")
const MapCheckScene := preload("res://src/ui/pause/map_check_overlay.tscn")
const PhysicalMapScene := preload("res://src/ui/hud/physical_map.tscn")
const SelfCheckScene := preload("res://src/ui/hud/self_check_screen.tscn")
const TopoReplayScene := preload("res://src/ui/analysis/topo_replay_visualization.tscn")

## Active main menu instance
var main_menu: MainMenu = null

## Active resolution screen instance
var resolution_screen: ResolutionScreen = null

## Active post-game screen instance
var post_game_screen: PostGameScreen = null

## Active mountain select screen
var mountain_select_screen: MountainSelectScreen = null

## Active loadout config screen
var loadout_config_screen: LoadoutConfigScreen = null

## Active planning screen
var planning_screen: PlanningScreen = null

## Active pause menu
var pause_menu: PauseMenu = null

## Active map check overlay
var map_check_overlay: MapCheckOverlay = null

## Active physical map (in-game)
var physical_map: PhysicalMap = null

## Active self-check screen
var self_check_screen: SelfCheckScreen = null

## Active topo replay visualization
var topo_replay: TopoReplayVisualization = null

# =============================================================================
# GAMEPLAY REFERENCES
# =============================================================================

## Active player instance
var player: PlayerController = null

## Terrain service reference
var terrain_service: TerrainService = null

## Time service reference
var time_service: TimeService = null

## Weather service reference
var weather_service: WeatherService = null

## Environment light
var environment_light: DirectionalLight3D = null

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
		GameEnums.GameState.MOUNTAIN_SELECT:
			_show_mountain_select()
		GameEnums.GameState.LOADOUT_CONFIG:
			_show_loadout_config()
		GameEnums.GameState.PLANNING:
			_show_planning()
		GameEnums.GameState.DESCENT:
			_start_descent()
		GameEnums.GameState.PAUSED:
			_show_pause_menu()
		GameEnums.GameState.MAP_CHECK:
			_show_map_check()
		GameEnums.GameState.RESOLUTION:
			_show_resolution()
		GameEnums.GameState.POST_GAME:
			_show_post_game()

	# Handle exiting pause/map states
	match old_state:
		GameEnums.GameState.PAUSED:
			if new_state != GameEnums.GameState.MAP_CHECK:
				_hide_pause_menu()
		GameEnums.GameState.MAP_CHECK:
			_hide_map_check()
			if new_state == GameEnums.GameState.PAUSED:
				_on_return_to_pause_from_map()


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
	print("[Main] Showing main menu...")

	# Clean up any active descent
	_cleanup_descent()

	# Hide other screens
	_hide_mountain_select()
	_hide_loadout_config()
	_hide_planning()

	# Hide world during menu
	world.visible = false

	# Create main menu if not exists
	if main_menu == null:
		main_menu = MainMenuScene.instantiate()
		ui.add_child(main_menu)
	else:
		main_menu.show_menu()

	print("[Main] Main menu loaded")


func _show_mountain_select() -> void:
	print("[Main] Showing mountain select...")

	# Hide main menu
	_hide_main_menu()

	# Hide other screens
	_hide_loadout_config()
	_hide_planning()

	# Create mountain select screen if not exists
	if mountain_select_screen == null:
		mountain_select_screen = MountainSelectScene.instantiate()
		ui.add_child(mountain_select_screen)
	else:
		mountain_select_screen.visible = true
		mountain_select_screen.refresh()

	print("[Main] Mountain select loaded")


func _hide_mountain_select() -> void:
	if mountain_select_screen != null:
		mountain_select_screen.visible = false


func _show_loadout_config() -> void:
	print("[Main] Showing loadout config...")

	# Hide other screens
	_hide_main_menu()
	_hide_mountain_select()
	_hide_planning()

	# Create loadout config screen if not exists
	if loadout_config_screen == null:
		loadout_config_screen = LoadoutConfigScene.instantiate()
		ui.add_child(loadout_config_screen)
	else:
		loadout_config_screen.visible = true

	print("[Main] Loadout config loaded")


func _hide_loadout_config() -> void:
	if loadout_config_screen != null:
		loadout_config_screen.visible = false


func _show_planning() -> void:
	print("[Main] Showing planning screen...")

	# Hide other screens
	_hide_main_menu()
	_hide_mountain_select()
	_hide_loadout_config()

	# Get mountain and loadout for planning
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain := mountain_db.get_selected_mountain() if mountain_db else null

	# Create planning screen if not exists
	if planning_screen == null:
		planning_screen = PlanningScene.instantiate()
		ui.add_child(planning_screen)
		planning_screen.planning_complete.connect(_on_planning_complete)
	else:
		planning_screen.visible = true

	print("[Main] Planning screen loaded")


func _hide_planning() -> void:
	if planning_screen != null:
		planning_screen.visible = false


func _on_planning_complete(route: PackedVector3Array) -> void:
	# Get selected mountain and loadout
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain := mountain_db.get_selected_mountain() if mountain_db else null

	if mountain == null:
		push_error("[Main] No mountain selected for descent")
		return

	# Get loadout from loadout screen
	var loadout: GearState = null
	if loadout_config_screen != null:
		loadout = loadout_config_screen.get_loadout()
	else:
		loadout = GearState.create_standard_loadout()

	# Create start conditions
	var conditions := StartConditions.create_moderate()
	conditions.gear_state = loadout
	conditions.mountain_id = mountain.id
	conditions.knowledge_level = mountain_db.get_knowledge_level(mountain.id)

	# Start run with planned route
	var run := GameStateManager.start_run(mountain.id, conditions)
	if run:
		run.set_meta("planned_route", route)

	# Transition handled by planning screen


func _start_descent() -> void:
	print("[Main] Starting descent...")

	# Hide main menu
	_hide_main_menu()

	# Show world
	world.visible = true

	# Initialize gameplay systems
	await _initialize_descent_systems()

	print("[Main] Descent initialized")


func _initialize_descent_systems() -> void:
	var run := GameStateManager.current_run
	if run == null:
		push_error("[Main] Cannot start descent without active run")
		return

	# 1. Initialize terrain
	await _setup_terrain(run.mountain_id)

	# 2. Initialize environment services
	_setup_environment(run)

	# 3. Spawn player at start position
	_spawn_player(run)

	# 4. Setup lighting
	_setup_lighting(run)

	# 5. Setup HUD elements
	_setup_hud()

	# Emit descent ready signal
	EventBus.descent_ready.emit()


func _setup_terrain(mountain_id: String) -> void:
	print("[Main] Loading terrain for: %s" % mountain_id)

	# Get or create terrain service
	terrain_service = ServiceLocator.get_service("TerrainService") as TerrainService
	if terrain_service == null:
		terrain_service = TerrainService.new()
		world.add_child(terrain_service)

	# Load terrain
	terrain_service.load_terrain(mountain_id)

	# Wait for terrain to be ready
	await get_tree().process_frame


func _setup_environment(run: RunContext) -> void:
	print("[Main] Setting up environment...")

	# Initialize time service
	time_service = ServiceLocator.get_service("TimeService") as TimeService
	if time_service == null:
		time_service = TimeService.new()
		world.add_child(time_service)

	# Set initial time from run conditions
	time_service.current_time = run.start_conditions.time_of_day

	# Initialize weather service
	weather_service = ServiceLocator.get_service("WeatherService") as WeatherService
	if weather_service == null:
		weather_service = WeatherService.new()
		world.add_child(weather_service)

	# Set initial weather from run conditions
	weather_service.current_weather = run.start_conditions.weather


func _spawn_player(run: RunContext) -> void:
	print("[Main] Spawning player...")

	# Remove existing player if any
	if player != null:
		player.queue_free()
		player = null

	# Create new player
	player = PlayerScene.instantiate()
	world.add_child(player)

	# Position at summit/start area
	var start_pos := _get_start_position()
	player.global_position = start_pos

	# Link run context to player
	player.body_state = run.body_state
	player.gear_state = run.gear_state

	# Update run context with start position
	run.position = start_pos
	run.start_elevation = start_pos.y
	run.current_elevation = start_pos.y
	run.target_elevation = 0.0  # Base camp at sea level (simplified)

	print("[Main] Player spawned at: %s" % start_pos)


func _get_start_position() -> Vector3:
	# Find highest point in terrain as start
	if terrain_service != null:
		var bounds_max := terrain_service.terrain_bounds_max
		var bounds_min := terrain_service.terrain_bounds_min

		# Start near center, at terrain height
		var center_x := (bounds_max.x + bounds_min.x) * 0.5
		var center_z := (bounds_max.z + bounds_min.z) * 0.5

		var height := terrain_service.get_height_at(Vector3(center_x, 0, center_z))
		return Vector3(center_x, height + 1.0, center_z)

	# Fallback position
	return Vector3(0, 3000, 0)


func _setup_lighting(run: RunContext) -> void:
	# Create or get directional light for sun
	if environment_light == null:
		environment_light = DirectionalLight3D.new()
		environment_light.name = "SunLight"
		environment_light.shadow_enabled = true
		environment_light.light_energy = 1.0
		environment_light.light_color = Color(1.0, 0.95, 0.9)
		world.add_child(environment_light)

	# Position sun based on time of day
	_update_sun_position(run.start_conditions.time_of_day)


func _update_sun_position(game_time: float) -> void:
	if environment_light == null:
		return

	# Simple sun arc calculation
	# 6:00 = sunrise (east), 12:00 = noon (high), 18:00 = sunset (west)
	var time_normalized := (game_time - 6.0) / 12.0  # 0 at sunrise, 1 at sunset
	time_normalized = clampf(time_normalized, 0.0, 1.0)

	# Sun angle: 0° at horizon, 60° at noon
	var elevation_angle := sin(time_normalized * PI) * 60.0
	var azimuth_angle := time_normalized * 180.0 - 90.0  # -90° (east) to 90° (west)

	environment_light.rotation_degrees = Vector3(-elevation_angle, azimuth_angle, 0)

	# Adjust light color/intensity based on time
	if game_time < 7.0 or game_time > 17.0:
		# Golden hour
		environment_light.light_color = Color(1.0, 0.8, 0.6)
		environment_light.light_energy = 0.7
	else:
		# Daytime
		environment_light.light_color = Color(1.0, 0.98, 0.95)
		environment_light.light_energy = 1.0


func _setup_hud() -> void:
	print("[Main] Setting up HUD...")

	# Create physical map if not exists
	if physical_map == null:
		physical_map = PhysicalMapScene.instantiate()
		ui.add_child(physical_map)

	print("[Main] HUD ready")


func _cleanup_descent() -> void:
	# Clean up player
	if player != null:
		player.queue_free()
		player = null

	# Clean up lighting
	if environment_light != null:
		environment_light.queue_free()
		environment_light = null

	# Clean up HUD
	if physical_map != null:
		physical_map.queue_free()
		physical_map = null

	if self_check_screen != null:
		self_check_screen.queue_free()
		self_check_screen = null

	# Clean up UI screens
	_hide_resolution_screen()
	_hide_post_game_screen()


func _hide_resolution_screen() -> void:
	if resolution_screen != null:
		resolution_screen.hide_resolution()


func _hide_main_menu() -> void:
	if main_menu != null:
		main_menu.hide_menu()


func _show_resolution() -> void:
	print("[Main] Showing resolution...")

	# Get run context and outcome
	var run := GameStateManager.current_run
	if run == null:
		push_error("[Main] No run context for resolution")
		return

	# Create resolution screen if not exists
	if resolution_screen == null:
		resolution_screen = ResolutionScreenScene.instantiate()
		ui.add_child(resolution_screen)

	# Show with run results
	resolution_screen.show_resolution(run, run.outcome)

	print("[Main] Resolution screen shown: %s" % GameEnums.ResolutionType.keys()[run.outcome])


func _show_post_game() -> void:
	print("[Main] Showing post-game analysis...")

	# Hide resolution screen
	_hide_resolution_screen()

	# Get run context
	var run := GameStateManager.current_run
	if run == null:
		push_error("[Main] No run context for post-game")
		return

	# Create post-game screen if not exists
	if post_game_screen == null:
		post_game_screen = PostGameScreenScene.instantiate()
		post_game_screen.view_replay_pressed.connect(_on_view_replay_pressed)
		ui.add_child(post_game_screen)

	# Show analysis
	post_game_screen.show_analysis(run)

	print("[Main] Post-game analysis shown")


func _hide_post_game_screen() -> void:
	if post_game_screen != null:
		post_game_screen.hide_analysis()


func _on_view_replay_pressed() -> void:
	_show_topo_replay()


func _show_topo_replay() -> void:
	print("[Main] Showing topo replay visualization...")

	# Get run context from post-game screen
	var run := post_game_screen.get_run_context() if post_game_screen else GameStateManager.current_run
	if run == null:
		push_error("[Main] No run context for replay")
		return

	# Create topo replay if not exists
	if topo_replay == null:
		topo_replay = TopoReplayScene.instantiate()
		topo_replay.close_requested.connect(_on_topo_replay_closed)
		ui.add_child(topo_replay)

	# Show visualization
	topo_replay.show_visualization(run)

	print("[Main] Topo replay shown")


func _hide_topo_replay() -> void:
	if topo_replay != null:
		topo_replay.hide_visualization()


func _on_topo_replay_closed() -> void:
	_hide_topo_replay()


# =============================================================================
# PAUSE MENU
# =============================================================================

func _show_pause_menu() -> void:
	print("[Main] Showing pause menu...")

	# Pause the game tree
	get_tree().paused = true

	# Create pause menu if not exists
	if pause_menu == null:
		pause_menu = PauseMenuScene.instantiate()
		pause_menu.self_check_pressed.connect(_on_self_check_pressed)
		ui.add_child(pause_menu)

	pause_menu.show_menu()
	print("[Main] Game paused")


func _hide_pause_menu() -> void:
	if pause_menu != null:
		pause_menu.hide_menu()

	# Unpause the game tree
	get_tree().paused = false


func _on_self_check_pressed() -> void:
	_show_self_check()


func _show_self_check() -> void:
	print("[Main] Showing self-check...")

	# Hide pause menu but stay paused
	if pause_menu != null:
		pause_menu.visible = false

	# Create self-check screen if not exists
	if self_check_screen == null:
		self_check_screen = SelfCheckScene.instantiate()
		self_check_screen.close_requested.connect(_on_self_check_closed)
		ui.add_child(self_check_screen)

	self_check_screen.show_check()
	print("[Main] Self-check shown")


func _hide_self_check() -> void:
	if self_check_screen != null:
		self_check_screen.hide_check()


func _on_self_check_closed() -> void:
	_hide_self_check()
	# Show pause menu again
	if pause_menu != null:
		pause_menu.visible = true
		pause_menu.show_menu()
	print("[Main] Game resumed")


func _show_map_check() -> void:
	print("[Main] Showing map check...")

	# Hide pause menu but stay paused
	if pause_menu != null:
		pause_menu.visible = false

	# Create map check overlay if not exists
	if map_check_overlay == null:
		map_check_overlay = MapCheckScene.instantiate()
		ui.add_child(map_check_overlay)

	map_check_overlay.show_overlay()
	print("[Main] Map check shown")


func _hide_map_check() -> void:
	if map_check_overlay != null:
		map_check_overlay.hide_overlay()


func _on_return_to_pause_from_map() -> void:
	# Show pause menu again when returning from map check to pause
	if pause_menu != null:
		pause_menu.visible = true
		pause_menu.show_menu()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	# Pause toggle during descent
	if event.is_action_pressed("ui_cancel"):
		var state := GameStateManager.current_state
		if state == GameEnums.GameState.DESCENT:
			# Close physical map first if open
			if physical_map != null and physical_map.is_open:
				physical_map.close_map()
				get_viewport().set_input_as_handled()
				return
			GameStateManager.toggle_pause()
			get_viewport().set_input_as_handled()

	# Physical map toggle during descent
	if event.is_action_pressed("open_map"):
		var state := GameStateManager.current_state
		if state == GameEnums.GameState.DESCENT:
			if physical_map != null:
				physical_map.toggle_map()
				get_viewport().set_input_as_handled()

	# Debug shortcuts
	if OS.is_debug_build():
		if event.is_action_pressed("ui_home"):
			# Print debug info
			print("=== DEBUG INFO ===")
			print("GameState: %s" % GameStateManager.get_debug_info())
			print("Services: %s" % ServiceLocator.get_debug_info())
			if GameStateManager.current_run:
				print("Run: %s" % GameStateManager.current_run.get_run_summary())
