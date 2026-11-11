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
const StreamingSettingsScene := preload("res://src/ui/settings/streaming_settings.tscn")
const OBSIntegrationScene := preload("res://src/systems/streaming/obs_integration.tscn")

## Key of the world a resumed run was saved in, carried on the run from
## Continue until the descent is built (see _on_continue_pressed)
const RESUME_META := "resume_world"

## A run on skis can be saved when it is going no faster than this (m/s)
const SUSPEND_MAX_GLIDE_SPEED := 1.0

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

## The replay on the mountain: its stage (in the world) and its controls
var replay_stage: ReplayStage = null
var replay_screen: ReplayScreen = null
var _world_visible_before_replay: bool = true

## Lifetime record (main menu > Logbook)
var stats_display: StatsDisplay = null

## Sound, display and camera settings (main menu and pause menu > Settings)
var settings_screen: SettingsScreen = null

## Active streaming settings screen
var streaming_settings: StreamingSettings = null

## OBS integration instance
var obs_integration: OBSIntegration = null

# =============================================================================
# GAMEPLAY REFERENCES
# =============================================================================

## Active player instance
var player: PlayerController = null

## Terrain service reference
var terrain_service: TerrainService = null

## Environment service reference (owns time/weather/temperature/surface)
var environment_service: EnvironmentService = null

## Time service reference
var time_service: TimeService = null

## Weather service reference
var weather_service: WeatherService = null

## Base camp marker + arrival detection for the active descent
var descent_goal: DescentGoal = null

## Summit cairn (and, on a full route, the summit check)
var summit_goal: SummitGoal = null

## In-game HUD (elevation, distance to base camp, control hints)
var descent_hud: Control = null

## HUD scene path (loaded lazily so the scene is optional)
const DESCENT_HUD_SCENE := "res://src/ui/hud/descent_hud.tscn"

## A full route starts this far from the camp centre, toward the summit (metres)
const FULL_ROUTE_START_OFFSET := 9.0

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
	EventBus.player_position_updated.connect(_on_player_position_updated)

	# Create the always-on services (databases, persistence, audio, camera AI)
	_bootstrap_core_services()

	# Initialize OBS integration
	_initialize_obs_integration()

	# Transition to main menu
	GameStateManager.transition_to(GameEnums.GameState.MAIN_MENU)

	print("[Main] Initialization complete")

	# Developer shortcut straight into a descent (opt-in):
	#   godot --path . -- --quick-start [--mountain=<id>]
	if _has_user_arg("--quick-start"):
		_debug_quick_start()


# =============================================================================
# SERVICE BOOTSTRAP
# =============================================================================

## Instantiate a service node and add it under the given parent,
## unless something already registered under that name
func _bootstrap_service(service_name: String, script_type: GDScript, parent: Node) -> void:
	if ServiceLocator.has_service(service_name):
		return
	var node: Node = script_type.new()
	node.name = service_name
	parent.add_child(node)


## Services that must exist for menus and the whole game session.
## These classes register themselves with ServiceLocator in _ready(),
## but nothing instantiated them - without this, mountain/gear selection,
## saving, audio and the camera AI silently never come online.
func _bootstrap_core_services() -> void:
	# Data + persistence
	_bootstrap_service("MountainDatabase", MountainDatabase, self)
	_bootstrap_service("GearDatabase", GearDatabase, self)
	_bootstrap_service("SaveManager", SaveManager, self)
	_bootstrap_service("PlanningService", PlanningService, self)
	_bootstrap_service("AvalancheService", AvalancheService, self)

	# Audio stack - AudioInitializer creates AudioService and all managers
	if not ServiceLocator.has_service("AudioService"):
		var audio := AudioInitializer.new()
		audio.name = "AudioInitializer"
		add_child(audio)

	# The player's settings (after the audio stack: it sets the sound levels)
	_bootstrap_service("GameSettings", GameSettings, self)

	# Camera Director AI (components resolve each other via ServiceLocator)
	_bootstrap_service("SignalDetector", SignalDetector, self)
	_bootstrap_service("EmotionalRhythmEngine", EmotionalRhythmEngine, self)
	_bootstrap_service("IntentSelector", IntentSelector, self)
	_bootstrap_service("ImperfectionEngine", ImperfectionEngine, self)
	_bootstrap_service("CameraDirector", CameraDirector, self)

	# Drone (spawns the drone entity itself when a descent starts)
	_bootstrap_service("DroneService", DroneService, self)

	# Recording / replay / streamer tooling
	_bootstrap_service("RecordingService", RecordingService, self)
	_bootstrap_service("ReplayPlayer", ReplayPlayer, self)
	_bootstrap_service("SpeedrunTimer", SpeedrunTimer, self)
	_bootstrap_service("StreamerTools", StreamerTools, self)
	_bootstrap_service("HighlightGenerator", HighlightGenerator, self)

	print("[Main] Core services bootstrapped")


## Gameplay simulation systems needed during a descent.
## Created once (on first descent) and reused for later runs.
func _bootstrap_descent_systems() -> void:
	_bootstrap_service("BodyConditionService", BodyConditionService, world)
	_bootstrap_service("SlideSystem", SlideSystem, world)
	_bootstrap_service("RopeService", RopeService, world)
	_bootstrap_service("CrevasseSystem", CrevasseSystem, world)
	_bootstrap_service("AvalancheSystem", AvalancheSystem, world)
	_bootstrap_service("RiskDetectionService", RiskDetectionService, world)
	_bootstrap_service("FatalEventManager", FatalEventManager, world)
	_bootstrap_service("FatalityDetector", FatalityDetector, world)
	_bootstrap_service("FatalAudioController", FatalAudioController, world)
	_bootstrap_service("TutorialManager", TutorialManager, world)
	_bootstrap_service("TutorialTriggers", TutorialTriggers, world)

	print("[Main] Descent systems bootstrapped")


# =============================================================================
# DEBUG
# =============================================================================

## True when the given flag was passed after "--" on the command line
func _has_user_arg(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()


## Value of a "--name=value" user argument, or the default when absent
func _get_user_arg_value(flag: String, default: String) -> String:
	var prefix := flag + "="
	for arg in OS.get_cmdline_user_args():
		var text := str(arg)
		if text.begins_with(prefix):
			return text.trim_prefix(prefix)
	return default


func _debug_quick_start() -> void:
	# Skip the menus and start a descent on a real mountain
	var mountain_id := _get_user_arg_value("--mountain", "knife_edge")
	print("[Main] Quick start requested for '%s'" % mountain_id)

	# The developer shortcut ignores unlock progress
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db != null and not mountain_db.select_mountain(mountain_id, true):
		var available := mountain_db.get_available_mountains()
		if available.is_empty():
			push_error("[Main] Quick start: no mountains available")
			return
		mountain_id = available[0].id
		mountain_db.select_mountain(mountain_id, true)
		print("[Main] Quick start: unknown mountain, using '%s'" % mountain_id)

	# Create test conditions
	var conditions := StartConditions.create_moderate()
	conditions.mountain_id = mountain_id
	# Today's snowpack; --avalanche=N picks a day with that danger (0: none)
	var avalanches := ServiceLocator.get_service("AvalancheService") as AvalancheService
	if avalanches != null:
		var level := int(_get_user_arg_value("--avalanche", "-1"))
		if level > 0:
			conditions.avalanche = avalanches.generate_with_danger(mountain_id, clampi(level, 1, 5), randi())
		elif level < 0:
			conditions.avalanche = avalanches.today(mountain_id)
	if _has_user_arg("--full-route") and mountain_db != null:
		# Developer shortcut: the full route without beating the game first
		mountain_db.full_route_override = true
		mountain_db.set_route_mode(GameEnums.RouteMode.FULL_ROUTE)
	_apply_route_mode(conditions)

	# Transition through states with frame delays to let signal handlers complete
	GameStateManager.transition_to(GameEnums.GameState.MOUNTAIN_SELECT)
	await get_tree().process_frame

	GameStateManager.transition_to(GameEnums.GameState.LOADOUT_CONFIG)
	await get_tree().process_frame

	GameStateManager.transition_to(GameEnums.GameState.PLANNING)
	await get_tree().process_frame

	var run := GameStateManager.start_run(mountain_id, conditions)
	if run:
		print("[Main] Quick start run created: %s" % run.run_id)
	else:
		push_error("[Main] Quick start: failed to create run")
		return

	GameStateManager.transition_to(GameEnums.GameState.DESCENT)


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	print("[Main] Game state: %s -> %s" % [
		GameEnums.GameState.keys()[old_state],
		GameEnums.GameState.keys()[new_state]
	])

	_update_mouse_mode(new_state)

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
			# Only a fresh descent builds the world; returning from the pause
			# menu or the map check just resumes it
			if old_state != GameEnums.GameState.PAUSED and old_state != GameEnums.GameState.MAP_CHECK:
				_start_descent()
		GameEnums.GameState.PAUSED:
			_show_pause_menu()
		GameEnums.GameState.MAP_CHECK:
			_show_map_check()
		GameEnums.GameState.RESOLUTION:
			_end_descent()
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


## The mouse is captured for camera look only while actually descending
func _update_mouse_mode(state: GameEnums.GameState) -> void:
	if state == GameEnums.GameState.DESCENT:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _on_run_started(run_context: RunContext) -> void:
	print("[Main] Run started: %s" % run_context.run_id)
	print("[Main] Difficulty: %.2f" % run_context.start_conditions.get_difficulty_score())


func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	print("[Main] Run ended: %s" % GameEnums.ResolutionType.keys()[outcome])
	var summary := run_context.get_run_summary()
	print("[Main] Summary: %s" % str(summary))

	# Score the line before the run is recorded (on-sight is judged on the
	# knowledge the climber started with)
	_score_run(run_context)

	# Progress, knowledge and unlocks live in the mountain database
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db != null:
		mountain_db.record_run(run_context.mountain_id, outcome, run_context.game_time_elapsed * 60.0)


## Grade and score the line actually travelled and file it in the logbook
func _score_run(run: RunContext) -> void:
	var routes: Array[RouteSurvey.GuideRoute] = []
	if terrain_service != null and terrain_service.current_mountain == run.mountain_id:
		routes = RouteSurvey.survey(terrain_service)
	var score := RouteScorer.score_run(run, terrain_service, routes)
	run.route_score = score

	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db != null:
		run.set_meta("score_is_best", mountain_db.record_score(run.mountain_id, score.to_dict()))
		var home := run.outcome == GameEnums.ResolutionType.CLEAN_RETURN or run.outcome == GameEnums.ResolutionType.INJURED_RETURN
		if home:
			for route in routes:
				if route.name == score.route_name or (run.summit_reached and route.name == score.ascent_route_name):
					mountain_db.record_route_climbed(run.mountain_id, route.id)

	print("[Main] Route score: %d - %s (style %s, pace x%.2f, plan %d%%)" % [
		score.total, score.get_title(), score.style_label, score.pace_factor, roundi(score.plan_share * 100.0)
	])


## Feed the climber's altitude to the environment (temperature, hazards)
var _environment_sample_time: float = 0.0

func _on_player_position_updated(position: Vector3, _velocity: Vector3) -> void:
	if environment_service == null or GameStateManager.current_state != GameEnums.GameState.DESCENT:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _environment_sample_time < 0.5:
		return
	_environment_sample_time = now
	environment_service.update_player_position(position)


# =============================================================================
# SAVE AND QUIT, CONTINUE (a run set aside part-way)
# =============================================================================

## Why the run cannot be saved right now ("" when it can). A run is saved
## standing on the mountain and in control, never part-way through something
## the save could not put back (a rope, a slide, moving snow).
func get_suspend_block_reason() -> String:
	var run := GameStateManager.current_run
	if run == null or run.is_complete or player == null or not is_instance_valid(player) or environment_service == null:
		return "There is no descent to save."
	var fatal := ServiceLocator.get_service("FatalEventManager") as FatalEventManager
	if fatal != null and fatal.is_fatal_active:
		return "Not now."
	var ropes := ServiceLocator.get_service("RopeService") as RopeService
	if ropes != null and (ropes.rope_in_use or ropes.phase != RopeService.RopePhase.NONE):
		return "Finish with the rope first."
	var avalanches := ServiceLocator.get_service("AvalancheSystem") as AvalancheSystem
	if avalanches != null and (avalanches.is_caught() or not avalanches.flows.is_empty()):
		return "Not while the snow is moving."
	var crevasses := ServiceLocator.get_service("CrevasseSystem") as CrevasseSystem
	if crevasses != null and crevasses.in_crevasse != null:
		return "Climb out of the crevasse first."
	if player.gear_action != &"":
		return "Finish changing what is on your feet first."
	match player.current_state:
		GameEnums.PlayerMovementState.STANDING, GameEnums.PlayerMovementState.WALKING, GameEnums.PlayerMovementState.RESTING:
			pass
		GameEnums.PlayerMovementState.SKIING:
			if player.velocity.length() > SUSPEND_MAX_GLIDE_SPEED:
				return "Come to a stop first."
		_:
			return "Get to ground you can stand on first."
	if not player.is_grounded:
		return "Get to ground you can stand on first."
	return ""


## There is one place for a run set aside: say so when saving this one
## would replace another ("" when it would not)
func _suspend_replaces_note() -> String:
	var saves := ServiceLocator.get_service("SaveManager") as SaveManager
	var summary: Dictionary = saves.get_suspended_run_summary() if saves != null else {}
	if summary.is_empty():
		return ""
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain: MountainDatabase.MountainData = mountain_db.get_mountain(str(summary.get("mountain_id", ""))) if mountain_db != null else null
	return "Saving replaces the descent you set aside%s." % ((" on %s" % mountain.name) if mountain != null else "")


## The run as it stands and the world around it, as plain data for
## SaveManager.save_suspended_run
func _capture_suspended_run() -> Dictionary:
	var run := GameStateManager.current_run
	run.position = player.global_position
	run.current_elevation = player.global_position.y
	return {
		"saved_at": Time.get_datetime_string_from_system(),
		"run": run.to_save(),
		"world": {
			"player": {
				"position": player.global_position,
				"yaw": player.rotation.y,
				"footwear": int(player.footwear),
			},
			"environment": environment_service.to_save(),
			"mountain": _capture_mountain(),
			"recording": _capture_recording(),
		},
	}


## The recording of the run so far, so that the replay of a run that was set
## aside and continued is whole
func _capture_recording() -> Dictionary:
	var recorder := ServiceLocator.get_service("RecordingService") as RecordingService
	return recorder.to_save() if recorder != null else {}


## What has changed on the mountain since the day began (ground that slid or
## opened, what the avalanches left to be seen, the climber's probe holes)
func _capture_mountain() -> Dictionary:
	var data := {}
	if terrain_service != null:
		data["terrain"] = terrain_service.get_changes()
	var avalanche_system := ServiceLocator.get_service("AvalancheSystem") as AvalancheSystem
	if avalanche_system != null:
		data["avalanches"] = avalanche_system.to_save()
	var crevasse_system := ServiceLocator.get_service("CrevasseSystem") as CrevasseSystem
	if crevasse_system != null:
		data["crevasses"] = crevasse_system.to_save()
	return data


## Pause menu > Save and Quit: write the run to disk, set it aside and go to
## the main menu. Nothing is recorded: the run has no outcome yet.
func _on_save_and_quit() -> void:
	if GameStateManager.current_state != GameEnums.GameState.PAUSED or not get_suspend_block_reason().is_empty():
		return
	var saves := ServiceLocator.get_service("SaveManager") as SaveManager
	if saves == null or not saves.save_suspended_run(_capture_suspended_run()):
		# Still on the mountain, still paused: say so rather than lose the run
		if pause_menu != null:
			pause_menu.set_save_quit_blocked("The descent could not be saved.")
		return
	print("[Main] Run saved; leaving for the main menu")
	GameStateManager.suspend_run()
	GameStateManager.transition_to(GameEnums.GameState.MAIN_MENU)


## The window is being closed with a descent on: keep it, if it can be kept.
## Never in place of a run already set aside (nobody was asked), and never
## where Save and Quit would be refused. Returns whether the run was written.
func save_run_on_close() -> bool:
	if not GameStateManager.is_run_active() or not get_suspend_block_reason().is_empty():
		return false
	var saves := ServiceLocator.get_service("SaveManager") as SaveManager
	if saves == null or saves.has_suspended_run():
		return false
	var written := saves.save_suspended_run(_capture_suspended_run())
	if written:
		print("[Main] Window closed on a descent: run saved for Continue")
	return written


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_run_on_close()


## Main menu > Continue: load the run that was set aside and carry on with it
func _on_continue_pressed() -> void:
	# Only from the menu, and only once (a second press finds a descent under way)
	if GameStateManager.current_state != GameEnums.GameState.MAIN_MENU:
		return
	var saves := ServiceLocator.get_service("SaveManager") as SaveManager
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var record: Dictionary = saves.load_suspended_run() if saves != null else {}
	var run: RunContext = RunContext.from_save(record["run"]) if not record.is_empty() else null
	if run == null or mountain_db == null or not mountain_db.select_mountain(run.mountain_id, true):
		push_warning("[Main] There is no run to continue")
		if main_menu != null:
			main_menu.refresh()
		return

	# The mountain, the way round it and the day's snowpack, as they were
	if run.is_full_route() and not mountain_db.set_route_mode(GameEnums.RouteMode.FULL_ROUTE):
		mountain_db.full_route_override = true
		mountain_db.set_route_mode(GameEnums.RouteMode.FULL_ROUTE)
	elif not run.is_full_route():
		mountain_db.set_route_mode(GameEnums.RouteMode.DESCENT)
	run.start_conditions.avalanche = StartConditions.avalanche_from_save(
		record["run"]["start_conditions"], mountain_db.get_mountain(run.mountain_id))
	var avalanches := ServiceLocator.get_service("AvalancheService") as AvalancheService
	if avalanches != null and run.start_conditions.avalanche != null:
		avalanches.set_today(run.mountain_id, run.start_conditions.avalanche)

	var world_saved: Variant = record.get("world")
	run.set_meta(RESUME_META, world_saved if world_saved is Dictionary else {})
	# The recording goes on from where it was (the recorder takes it up when
	# the run starts)
	var recorder := ServiceLocator.get_service("RecordingService") as RecordingService
	if recorder != null and world_saved is Dictionary and world_saved.get("recording") is Dictionary:
		recorder.pending_restore = world_saved["recording"]
	GameStateManager.resume_run(run)
	GameStateManager.transition_to(GameEnums.GameState.DESCENT)


## Stand the climber where the run was saved, facing the way they faced and
## with the same things on their feet. Returns the position used (fallback
## when the save names none, or one that is no longer on the mountain).
func _place_resumed_player(saved: Dictionary, fallback: Vector3) -> Vector3:
	var spot := fallback
	if saved.get("position") is Vector3:
		spot = saved["position"]
	if terrain_service != null:
		var low := terrain_service.terrain_bounds_min
		var high := terrain_service.terrain_bounds_max
		if spot.x < low.x or spot.x > high.x or spot.z < low.z or spot.z > high.z:
			spot = fallback
		# Never under the snow (a mountain whose shape changed between versions)
		spot.y = maxf(spot.y, terrain_service.get_height_at(spot) + 0.3)
	player.global_position = spot
	player.rotation = Vector3(0.0, float(saved.get("yaw", player.rotation.y)), 0.0)
	player.velocity = Vector3.ZERO
	player.last_position = spot
	var footwear := int(saved.get("footwear", player.footwear))
	if footwear >= 0 and footwear < GameEnums.Footwear.size():
		player.set_footwear(footwear as GameEnums.Footwear)
	var pivot := player.camera_pivot as PlayerCamera
	if pivot != null:
		pivot.snap_behind_player()
	return spot


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
		main_menu.logbook_pressed.connect(_show_logbook)
		main_menu.settings_pressed.connect(_show_settings)
		main_menu.continue_pressed.connect(_on_continue_pressed)
		ui.add_child(main_menu)
	else:
		main_menu.show_menu()

	# Keys and gamepads: the menu starts on the run to continue, else on a new one
	UIFocus.take(main_menu.continue_button if main_menu.has_save else main_menu.new_descent_button)

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

	mountain_select_screen.focus_default()

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
		# The selection may have changed since the screen was built
		var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
		if mountain_db != null:
			loadout_config_screen.set_mountain(mountain_db.get_selected_mountain())

	UIFocus.take(loadout_config_screen.find_child("StartButton", true, false) as Control)

	print("[Main] Loadout config loaded")


func _hide_loadout_config() -> void:
	if loadout_config_screen != null:
		loadout_config_screen.visible = false


func _show_planning() -> void:
	print("[Main] Showing planning screen...")

	# Hide other screens (Retry arrives here straight from the post-game analysis)
	_hide_main_menu()
	_hide_mountain_select()
	_hide_loadout_config()
	_hide_post_game_screen()
	_hide_resolution_screen()

	# Get mountain and loadout for planning
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain := mountain_db.get_selected_mountain() if mountain_db else null

	# Load terrain now so the planning map and route analysis have data;
	# without terrain the route can never validate and descent can't begin
	if mountain != null:
		_ensure_terrain_loaded(mountain.id)

	# Create planning screen if not exists
	if planning_screen == null:
		planning_screen = PlanningScene.instantiate()
		# Planning again after a run picked up from a save: start from the
		# day that run was (the screen has not seen it this session)
		var last := GameStateManager.current_run
		if last != null and last.start_conditions != null and not last.start_conditions.weather_id.is_empty():
			planning_screen.weather_id = last.start_conditions.weather_id
			if not last.start_conditions.climb_id.is_empty():
				planning_screen.climb_id = last.start_conditions.climb_id
		ui.add_child(planning_screen)
		planning_screen.planning_complete.connect(_on_planning_complete)
	else:
		planning_screen.visible = true
		planning_screen.refresh()

	UIFocus.take(planning_screen.confirm_button)

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
		# No loadout screen this session (the last run was picked up from a
		# save and is being tried again): the pack that run set out with
		var last := GameStateManager.current_run
		loadout = last.start_conditions.gear_state.duplicate_state() \
			if last != null and last.start_conditions != null and last.start_conditions.gear_state != null \
			else GearState.create_standard_loadout()

	# The day chosen at the hut: how the climb went and the weather window
	var conditions := StartConditions.create_for_day(planning_screen.climb_id, planning_screen.weather_id) \
		if planning_screen != null else StartConditions.create_for_day()
	conditions.gear_state = loadout
	conditions.mountain_id = mountain.id
	conditions.knowledge_level = mountain_db.get_knowledge_level(mountain.id)
	_apply_route_mode(conditions)
	# The snowpack the bulletin at the hut described
	var avalanches := ServiceLocator.get_service("AvalancheService") as AvalancheService
	if avalanches != null:
		conditions.avalanche = avalanches.today(mountain.id)

	# Start run with planned route
	var run := GameStateManager.start_run(mountain.id, conditions)
	if run:
		run.set_meta("planned_route", route)
		if planning_screen != null:
			if run.is_full_route():
				run.set_meta("planned_ascent", planning_screen.get_planned_route(GameEnums.RunPhase.ASCENT))
			run.set_meta("guide_route", planning_screen.get_selected_guide_id())

	# Transition handled by planning screen


## The selected route mode shapes the day: a full route leaves base camp
## fresh at an alpine start; a descent starts on the summit after the climb
func _apply_route_mode(conditions: StartConditions) -> void:
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db == null:
		return
	conditions.apply_route_mode(mountain_db.get_route_mode())


func _start_descent() -> void:
	print("[Main] Starting descent...")

	# Hide every menu screen; the world is the view now
	_hide_main_menu()
	_hide_mountain_select()
	_hide_loadout_config()
	_hide_planning()
	_hide_post_game_screen()
	_hide_resolution_screen()

	# Initialize gameplay systems (terrain, environment, player, goal, HUD);
	# the world is revealed inside, once the climber and camera are placed
	await _initialize_descent_systems()

	print("[Main] Descent initialized")


func _initialize_descent_systems() -> void:
	var run := GameStateManager.current_run
	if run == null:
		push_error("[Main] Cannot start descent without active run")
		return

	# 1. Initialize terrain
	await _setup_terrain(run.mountain_id)

	# 1b. A run picked up again: the mountain as it was left (debris, beds,
	# opened crevasses), before anyone stands on it
	var world_saved: Dictionary = run.get_meta(RESUME_META, {})
	var mountain_saved: Dictionary = world_saved["mountain"] if world_saved.get("mountain") is Dictionary else {}
	if mountain_saved.get("terrain") is Dictionary and terrain_service != null:
		terrain_service.restore_changes(mountain_saved["terrain"])

	# 2. Initialize environment services
	_setup_environment(run)

	# 2b. Create gameplay simulation systems (body, sliding, rope, risk, fatal, tutorial)
	_bootstrap_descent_systems()
	if mountain_saved.get("avalanches") is Dictionary:
		var avalanche_system := ServiceLocator.get_service("AvalancheSystem") as AvalancheSystem
		if avalanche_system != null:
			avalanche_system.pending_restore = mountain_saved["avalanches"]

	# 3. Spawn player at start position
	_spawn_player(run)

	# Reveal the world now: the climber's camera must be the current one
	# before anything else (the drone) enters the tree, and the first
	# rendered frame should already be the new summit
	world.visible = true

	# 4. Base camp marker + arrival detection
	_setup_descent_goal()

	# 5. Setup HUD elements
	_setup_hud()

	# A run picked up again is on the mountain now: the save has done its job
	# (there is no going back to it after a bad turn)
	if run.has_meta(RESUME_META):
		run.remove_meta(RESUME_META)
		var saves := ServiceLocator.get_service("SaveManager") as SaveManager
		if saves != null:
			saves.clear_suspended_run()

	# Emit descent ready signal
	EventBus.descent_ready.emit()

	# The climber's own marks on the glacier, once its systems are ready
	if mountain_saved.get("crevasses") is Dictionary:
		var crevasse_system := ServiceLocator.get_service("CrevasseSystem") as CrevasseSystem
		if crevasse_system != null:
			crevasse_system.restore(mountain_saved["crevasses"])


func _setup_terrain(mountain_id: String) -> void:
	print("[Main] Loading terrain for: %s" % mountain_id)

	_ensure_terrain_loaded(mountain_id)

	# Wait for terrain to be ready
	await get_tree().process_frame


## Get or create the terrain service and load the given mountain
## (skipped when that mountain is already loaded, e.g. during planning)
func _ensure_terrain_loaded(mountain_id: String) -> void:
	terrain_service = ServiceLocator.get_service("TerrainService") as TerrainService
	if terrain_service == null:
		terrain_service = TerrainService.new()
		terrain_service.name = "TerrainService"
		world.add_child(terrain_service)

	# A new day on a mountain whose snow or ice was changed last time (an
	# avalanche's debris, an opened crevasse) starts from the fresh mountain
	if terrain_service.current_mountain != mountain_id or terrain_service.modified:
		terrain_service.load_terrain(mountain_id)


func _setup_environment(run: RunContext) -> void:
	print("[Main] Setting up environment...")

	# EnvironmentService creates and owns TimeService, WeatherService,
	# TemperatureSystem and SurfaceConditionManager - don't create them here
	# too, or the duplicates fight over the service registry
	environment_service = ServiceLocator.get_service("EnvironmentService") as EnvironmentService
	if environment_service == null:
		environment_service = EnvironmentService.new()
		environment_service.name = "EnvironmentService"
		world.add_child(environment_service)

	time_service = ServiceLocator.get_service("TimeService") as TimeService
	weather_service = ServiceLocator.get_service("WeatherService") as WeatherService

	# Seed the run's environment from the start conditions
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain: MountainDatabase.MountainData = mountain_db.get_mountain(run.mountain_id) if mountain_db != null else null
	var config := EnvironmentService.EnvironmentConfig.from_conditions(run.start_conditions, mountain)
	config.start_elevation = _get_start_position().y
	var resumed: Dictionary = run.get_meta(RESUME_META, {})
	if resumed.get("environment") is Dictionary:
		config.start_elevation = run.current_elevation
		environment_service.resume_run(config, resumed["environment"])
	else:
		environment_service.initialize_run(config)


func _spawn_player(run: RunContext) -> void:
	print("[Main] Spawning player...")

	# One player node lives for the whole session: every system that cached
	# it or connected to its signals keeps working across runs
	var is_new := false
	if player == null or not is_instance_valid(player):
		player = PlayerScene.instantiate()
		world.add_child(player)
		is_new = true
	else:
		player.visible = true
		player.process_mode = Node.PROCESS_MODE_INHERIT

	# Position at summit/start area, facing base camp so the first view is
	# down the mountain; the camera snaps behind the climber after that.
	# A full route starts at the edge of base camp, facing the summit.
	var start_pos := _get_start_position()
	var goal_pos := _get_goal_position()
	var facing := goal_pos - start_pos
	if run.is_full_route():
		var summit := start_pos
		start_pos = _get_full_route_start(summit, goal_pos)
		facing = summit - start_pos
	player.global_position = start_pos
	facing.y = 0.0
	if facing.length_squared() > 0.01:
		player.look_at(start_pos + facing, Vector3.UP)
	if is_new:
		var pivot := player.camera_pivot as PlayerCamera
		if pivot != null:
			pivot.snap_behind_player()
	else:
		player.reset_for_new_run()

	# Link run context to player. Handing over the pack puts the day's
	# footwear on: that is the start of the day, not a decision made in it
	var logged := run.decisions.size()
	player.body_state = run.body_state
	player.gear_state = run.gear_state

	# A run picked up again stands where it was saved, with the same things
	# on its feet; its own record of the day so far is left as it is
	var resumed: Dictionary = run.get_meta(RESUME_META, {})
	if resumed.get("player") is Dictionary:
		start_pos = _place_resumed_player(resumed["player"], start_pos)
		run.decisions.resize(logged)
		run.position = start_pos
		run.current_elevation = start_pos.y
		run.target_elevation = goal_pos.y
		run.reset_position_tracking()
		print("[Main] Player back at: %s" % start_pos)
		return
	run.decisions.resize(logged)

	# Update run context with start position
	run.position = start_pos
	run.start_elevation = start_pos.y
	run.current_elevation = start_pos.y
	run.target_elevation = goal_pos.y
	run.reset_position_tracking()

	print("[Main] Player spawned at: %s (base camp at %s)" % [start_pos, goal_pos])


func _get_start_position() -> Vector3:
	if terrain_service != null:
		# Terrain provides a flattened summit plateau to start from
		if terrain_service.start_position != Vector3.ZERO:
			return terrain_service.start_position + Vector3(0, 0.5, 0)

		# Otherwise start near the centre, at terrain height
		var bounds_max := terrain_service.terrain_bounds_max
		var bounds_min := terrain_service.terrain_bounds_min

		# Start near center, at terrain height
		var center_x := (bounds_max.x + bounds_min.x) * 0.5
		var center_z := (bounds_max.z + bounds_min.z) * 0.5

		var height := terrain_service.get_height_at(Vector3(center_x, 0, center_z))
		return Vector3(center_x, height + 1.0, center_z)

	# Fallback position
	return Vector3(0, 3000, 0)


## Full route start: just outside base camp on the summit side, on the ground
func _get_full_route_start(summit: Vector3, base: Vector3) -> Vector3:
	var toward := Vector3(summit.x - base.x, 0.0, summit.z - base.z)
	if toward.length_squared() < 0.01:
		return base + Vector3(0, 0.5, 0)
	var spot := base + toward.normalized() * FULL_ROUTE_START_OFFSET
	if terrain_service != null:
		spot.y = terrain_service.get_height_at(spot)
	return spot + Vector3(0, 0.5, 0)


## Base camp position: terrain goal, else the lowest terrain corner
func _get_goal_position() -> Vector3:
	if terrain_service == null:
		return Vector3.ZERO
	if terrain_service.goal_position != Vector3.ZERO:
		return terrain_service.goal_position
	return Vector3(
		terrain_service.terrain_bounds_min.x,
		terrain_service.terrain_bounds_min.y,
		terrain_service.terrain_bounds_min.z
	)


func _setup_descent_goal() -> void:
	if descent_goal != null:
		descent_goal.queue_free()

	descent_goal = DescentGoal.new()
	descent_goal.player_ref = player
	world.add_child(descent_goal)

	# The summit cairn stands on every run; on a full route it is the turn
	if summit_goal != null:
		summit_goal.queue_free()
	summit_goal = SummitGoal.new()
	summit_goal.player_ref = player
	world.add_child(summit_goal)


func _setup_hud() -> void:
	print("[Main] Setting up HUD...")

	# Create physical map if not exists
	if physical_map == null:
		physical_map = PhysicalMapScene.instantiate()
		ui.add_child(physical_map)

	# Descent HUD (elevation, distance to base camp, control hints)
	if descent_hud == null and ResourceLoader.exists(DESCENT_HUD_SCENE):
		var hud_scene := load(DESCENT_HUD_SCENE) as PackedScene
		if hud_scene != null:
			descent_hud = hud_scene.instantiate() as Control
			ui.add_child(descent_hud)

	print("[Main] HUD ready")


## The run is over: freeze the climber where they stand (still visible
## behind the resolution screen) and stop the goal from firing again
func _end_descent() -> void:
	if player != null and is_instance_valid(player):
		player.velocity = Vector3.ZERO
		player.process_mode = Node.PROCESS_MODE_DISABLED
	if descent_goal != null and is_instance_valid(descent_goal):
		descent_goal.set_physics_process(false)
	if summit_goal != null and is_instance_valid(summit_goal):
		summit_goal.set_physics_process(false)


func _cleanup_descent() -> void:
	# Park the player until the next run (see _spawn_player)
	if player != null and is_instance_valid(player):
		player.velocity = Vector3.ZERO
		player.visible = false
		player.process_mode = Node.PROCESS_MODE_DISABLED

	# Clean up base camp marker
	if descent_goal != null:
		descent_goal.queue_free()
		descent_goal = null
	if summit_goal != null:
		summit_goal.queue_free()
		summit_goal = null

	# Clean up HUD
	if physical_map != null:
		physical_map.queue_free()
		physical_map = null

	if descent_hud != null:
		descent_hud.queue_free()
		descent_hud = null

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
	_hide_logbook()
	_hide_settings()
	if main_menu != null:
		main_menu.hide_menu()


## The lifetime record, over the main menu
func _show_logbook() -> void:
	if stats_display == null:
		stats_display = StatsDisplay.new()
		stats_display.name = "Logbook"
		stats_display.close_requested.connect(_hide_logbook)
		ui.add_child(stats_display)
	else:
		stats_display.refresh()
	stats_display.visible = true
	UIFocus.take(stats_display.find_child("CloseButton", true, false) as Control)


func _hide_logbook() -> void:
	if stats_display != null:
		if stats_display.visible and main_menu != null and main_menu.visible:
			UIFocus.take(main_menu.logbook_button)
		stats_display.visible = false


## The settings screen, over the main menu or in place of the pause menu
func _show_settings() -> void:
	# From the pause menu: put it away but stay paused
	if pause_menu != null and pause_menu.visible:
		pause_menu.visible = false
	if settings_screen == null:
		settings_screen = SettingsScreen.new()
		settings_screen.name = "SettingsScreen"
		settings_screen.close_requested.connect(_on_settings_closed)
		ui.add_child(settings_screen)
	# Above whatever was added since (the descent's HUD)
	ui.move_child(settings_screen, -1)
	settings_screen.show_settings()


func _hide_settings() -> void:
	if settings_screen != null:
		settings_screen.hide_settings()


func _on_settings_closed() -> void:
	_hide_settings()
	# Back to the pause menu when that is where it was opened from
	if pause_menu != null and GameStateManager.current_state == GameEnums.GameState.PAUSED:
		pause_menu.visible = true
		pause_menu.show_menu()
	elif main_menu != null and main_menu.visible:
		# Back on the main menu, where the focus was
		UIFocus.take(main_menu.settings_button)


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

	UIFocus.take(resolution_screen.continue_button)

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
		post_game_screen.watch_replay_pressed.connect(_show_replay)
		ui.add_child(post_game_screen)

	# Show analysis
	post_game_screen.show_analysis(run)
	post_game_screen.set_replay_available(_recording_of(run) != null)

	UIFocus.take(post_game_screen.return_button)

	print("[Main] Post-game analysis shown")


func _hide_post_game_screen() -> void:
	_hide_topo_replay()
	_hide_replay(false)
	if post_game_screen != null:
		post_game_screen.hide_analysis()


func _on_view_replay_pressed() -> void:
	_show_topo_replay()


# =============================================================================
# REPLAY ON THE MOUNTAIN
# =============================================================================

## The recording of a run, when the recorder still holds it and it is worth
## watching (null otherwise)
func _recording_of(run: RunContext) -> RecordingService.RecordingData:
	var recorder := ServiceLocator.get_service("RecordingService") as RecordingService
	var recording: RecordingService.RecordingData = recorder.get_current_recording() if recorder != null else null
	if run == null or recording == null or recording.run_id != run.run_id or recording.frames.size() < 2:
		return null
	return recording


## Post-game > Watch it again: the run just finished, replayed on the
## mountain. The climber is moved through the recording, the hour and the
## weather are the recording's, and ReplayPlayer keeps to the rules for a run
## that ended in a fatal event.
func _show_replay() -> void:
	if replay_screen != null and replay_screen.visible:
		return
	var run := post_game_screen.get_run_context() if post_game_screen != null else GameStateManager.current_run
	var recording := _recording_of(run)
	var replays := ServiceLocator.get_service("ReplayPlayer") as ReplayPlayer
	if recording == null or replays == null:
		return
	if replay_stage == null:
		replay_stage = ReplayStage.new()
		replay_stage.name = "ReplayStage"
		world.add_child(replay_stage)
	if not replay_stage.begin(recording, run):
		return
	if not replays.open(recording, replay_stage):
		replay_stage.end()
		return
	print("[Main] Showing the replay (%d frames, %.0f s)" % [recording.frames.size(), recording.get_duration()])

	_world_visible_before_replay = world.visible
	world.visible = true
	_hide_topo_replay()
	post_game_screen.visible = false
	if replay_screen == null:
		replay_screen = ReplayScreen.new()
		replay_screen.name = "ReplayScreen"
		replay_screen.close_requested.connect(_hide_replay)
		replay_screen.map_replay_requested.connect(func() -> void:
			_hide_replay()
			_show_topo_replay())
		ui.add_child(replay_screen)
	var highlights: Array = []
	var generator := ServiceLocator.get_service("HighlightGenerator") as HighlightGenerator
	if generator != null and terrain_service != null:
		highlights = generator.generate_highlights(recording, terrain_service.start_position.y, terrain_service.goal_position.y)
	replay_screen.open(replays, run, highlights)
	replays.play()


## Put the mountain away again and go back to the day's summary
## (back_to_summary false: the summary itself is being left)
func _hide_replay(back_to_summary: bool = true) -> void:
	if replay_screen == null or not replay_screen.visible:
		return
	replay_screen.close()
	var replays := ServiceLocator.get_service("ReplayPlayer") as ReplayPlayer
	if replays != null:
		replays.close()
	if replay_stage != null:
		replay_stage.end()
	world.visible = _world_visible_before_replay
	if back_to_summary and post_game_screen != null:
		post_game_screen.visible = true
		post_game_screen.modulate.a = 1.0
		UIFocus.take(post_game_screen.watch_button)


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
	UIFocus.take(topo_replay.play_button)

	print("[Main] Topo replay shown")


func _hide_topo_replay() -> void:
	if topo_replay != null:
		topo_replay.hide_visualization()


func _on_topo_replay_closed() -> void:
	_hide_topo_replay()


# =============================================================================
# PAUSE MENU
# =============================================================================

func _initialize_obs_integration() -> void:
	# Create OBS integration for streaming support
	if obs_integration == null:
		obs_integration = OBSIntegrationScene.instantiate()
		add_child(obs_integration)
		print("[Main] OBS integration initialized")


func _show_pause_menu() -> void:
	print("[Main] Showing pause menu...")

	# Pause the game tree
	get_tree().paused = true

	# Create pause menu if not exists
	if pause_menu == null:
		pause_menu = PauseMenuScene.instantiate()
		pause_menu.self_check_pressed.connect(_on_self_check_pressed)
		pause_menu.streaming_settings_pressed.connect(_on_streaming_settings_pressed)
		pause_menu.settings_pressed.connect(_show_settings)
		pause_menu.save_quit_pressed.connect(_on_save_and_quit)
		ui.add_child(pause_menu)

	pause_menu.set_save_quit_blocked(get_suspend_block_reason(), _suspend_replaces_note())
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


func _on_streaming_settings_pressed() -> void:
	_show_streaming_settings()


func _show_streaming_settings() -> void:
	print("[Main] Showing streaming settings...")

	# Hide pause menu but stay paused
	if pause_menu != null:
		pause_menu.visible = false

	# Create streaming settings screen if not exists
	if streaming_settings == null:
		streaming_settings = StreamingSettingsScene.instantiate()
		streaming_settings.close_requested.connect(_on_streaming_settings_closed)
		ui.add_child(streaming_settings)

	streaming_settings.show_settings()
	print("[Main] Streaming settings shown")


func _hide_streaming_settings() -> void:
	if streaming_settings != null:
		streaming_settings.hide_settings()


func _on_streaming_settings_closed() -> void:
	_hide_streaming_settings()
	# Show pause menu again
	if pause_menu != null:
		pause_menu.visible = true
		pause_menu.show_menu()


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
	# Pause toggle during descent ("cancel" only folds the map away)
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		var state := GameStateManager.current_state
		if state == GameEnums.GameState.DESCENT:
			# Close physical map first if open
			if physical_map != null and physical_map.is_open:
				physical_map.close_map()
				get_viewport().set_input_as_handled()
				return
			if event.is_action_pressed("pause"):
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
