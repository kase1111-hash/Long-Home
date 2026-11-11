extends SceneTree
## UI screenshot tour: walks every screen of the game the way a player would
## (pressing the real buttons) and saves a PNG of each, so the whole flow can
## be inspected offline. Also a smoke test: it fails if any transition does
## not happen.
##
## Run from the project root (needs a display; xvfb works, headless does not):
##   mkdir -p /tmp/tour && xvfb-run -a -s "-screen 0 1280x720x24" \
##     godot --path . --rendering-driver opengl3 --audio-driver Dummy \
##     -s res://tests/ui_tour.gd -- --out=/tmp/tour
##
## Screens, in order: main menu, mountain select, loadout, planning, descent
## (start + after walking), pause menu, map check, self-check, physical map,
## resolution, post-game with its map replay and the replay on the mountain,
## then a second mountain ending in a real fatal event (and that run's replay,
## under the rules for one), and a third run completed and retried. Exit code
## 0 on PASS, 1 on FAIL.
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time; everything is
## reached via /root/<autoload> nodes and load() after the deferred _run().

const SETTLE := 20
const DESCENT_SETTLE := 90
const WALK_FRAMES := 150

var out_dir: String = "/tmp"
var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _states: Dictionary = {}
var _failures: Array[String] = []
var _shots: Array[String] = []


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := str(arg)
		if text.begins_with("--out="):
			out_dir = text.trim_prefix("--out=")
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	if _state_manager == null or _enums == null or _locator == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_states = _enums.GameState

	var packed: PackedScene = load("res://src/scenes/main.tscn") as PackedScene
	var main_scene: Node = packed.instantiate()
	root.add_child(main_scene)
	await _wait(SETTLE)

	# The tour reads and changes settings without writing them to disk
	var settings: Node = _locator.get_service("GameSettings") as Node
	if settings != null:
		settings.persist = false
		settings.reset()

	# 1. Main menu
	_expect_state("MAIN_MENU", "boot")
	_shot("01_main_menu.png")
	await _check_settings(main_scene, "01b_settings")
	_press(main_scene.get("main_menu"), "new_descent_button")
	await _wait(SETTLE)

	# 2. Mountain select: pick the first available card, continue
	_expect_state("MOUNTAIN_SELECT", "New Descent button")
	var select_screen: Node = main_scene.get("mountain_select_screen")
	_shot("02_mountain_select.png")
	if select_screen != null and select_screen.has_method("_on_continue_pressed"):
		select_screen._on_continue_pressed()
	await _wait(SETTLE)

	# 3. Loadout: start with the default kit
	_expect_state("LOADOUT_CONFIG", "mountain select Continue")
	_shot("03_loadout.png")
	var loadout_screen: Node = main_scene.get("loadout_config_screen")
	_check_loadout_summary(loadout_screen)
	if loadout_screen != null and loadout_screen.has_method("_on_start_pressed"):
		loadout_screen._on_start_pressed()
	await _wait(SETTLE)

	# 4. Planning: the default summit-to-base line must be startable
	_expect_state("PLANNING", "loadout Start")
	await _wait(SETTLE)
	_shot("04_planning.png")
	var planning_screen: Node = main_scene.get("planning_screen")
	await _check_day_choice(planning_screen)
	var confirm: Button = _find_button(planning_screen, "ConfirmButton")
	_expect(confirm != null and not confirm.disabled, "Begin Descent is enabled without waypoints")
	if confirm != null:
		confirm.pressed.emit()
	await _wait(5)

	# 5. Descent
	_expect_state("DESCENT", "Begin Descent")
	await _wait(DESCENT_SETTLE)
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	_expect(player != null, "player exists in descent")
	var day_weather: Node = _locator.get_service("WeatherService") as Node
	_expect(day_weather != null and int(day_weather.current_weather) == int(_enums.WeatherState["CLEAR"]),
		"the descent starts in the settled weather that was chosen")
	_expect(_find_node(main_scene, "DescentGoal") != null, "base camp marker exists")
	_expect(_find_node(main_scene, "EnvironmentVisuals") != null, "environment visuals exist")
	_expect(_find_node(main_scene, "TerrainMeshes") != null, "terrain meshes exist")
	var planning_visible: bool = planning_screen != null and planning_screen.visible
	_expect(not planning_visible, "planning screen hidden during descent")
	_shot("05_descent_start.png")

	Input.action_press("move_forward")
	await _wait(WALK_FRAMES)
	Input.action_release("move_forward")
	await _wait(5)
	if player != null:
		_expect(player.is_on_floor(), "player on the ground after walking")
	_shot("06_descent_walk.png")

	# 6. Pause menu (Esc), then its Check Map and Check Body screens
	_state_manager.toggle_pause()
	await _wait(SETTLE)
	_expect_state("PAUSED", "toggle_pause")
	_shot("07_pause.png")

	var pause_menu_node: Node = main_scene.get("pause_menu")
	if pause_menu_node != null and pause_menu_node.has_method("_on_map_pressed"):
		pause_menu_node._on_map_pressed()
		await _wait(SETTLE * 2)
		_expect_state("MAP_CHECK", "pause menu Check Map")
		_shot("07b_map_check.png")
		_state_manager.exit_map_check()
		await _wait(SETTLE)
		_expect_state("PAUSED", "leaving the map check")

		pause_menu_node._on_self_check_pressed()
		await _wait(SETTLE * 3)
		var self_check: Node = main_scene.get("self_check_screen")
		_expect(self_check != null and self_check.visible, "self-check screen opens from the pause menu")
		_shot("07c_self_check.png")
		if self_check != null and self_check.has_signal("close_requested"):
			self_check.close_requested.emit()
		await _wait(SETTLE)
		_expect(pause_menu_node.visible, "pause menu returns after the self-check")

		# Settings from the pause menu: the game stays paused behind it
		(pause_menu_node.get("settings_button") as Button).pressed.emit()
		await _wait(SETTLE)
		var paused_settings: Control = main_scene.get("settings_screen") as Control
		_expect(paused_settings != null and paused_settings.visible and not pause_menu_node.visible,
			"Settings in the pause menu opens the settings screen in its place")
		_expect_state("PAUSED", "opening settings from the pause menu")
		_shot("07d_settings_paused.png")
		if paused_settings != null:
			_press(paused_settings, "back_button")
		await _wait(SETTLE)
		_expect(pause_menu_node.visible, "and Back returns to the pause menu")

		# Save and Quit, then Continue from the main menu: back on the
		# mountain, and paused again for what follows
		await _check_save_and_continue(main_scene, pause_menu_node)
	else:
		_expect(false, "pause menu exists")

	_state_manager.toggle_pause()
	await _wait(SETTLE)
	_expect_state("DESCENT", "resume")

	# 7. Physical map (M)
	var physical_map: Node = main_scene.get("physical_map")
	if physical_map != null and physical_map.has_method("open_map"):
		physical_map.open_map()
		await _wait(SETTLE * 2)
		_expect(bool(physical_map.get("is_open")), "physical map opens")
		_shot("08_physical_map.png")
		physical_map.close_map()
		await _wait(SETTLE)
	else:
		_expect(false, "physical map exists")

	# 8. Reach base camp -> resolution
	var terrain: Object = _locator.get_service("TerrainService")
	if player != null and is_instance_valid(terrain):
		var goal: Vector3 = terrain.goal_position
		player.global_position = goal + Vector3(0, 1, 0)
	await _wait(40)
	_expect_state("RESOLUTION", "arriving at base camp")
	await _wait(SETTLE * 3)
	_shot("09_resolution.png")
	_press(main_scene.get("resolution_screen"), "continue_button")
	await _wait(SETTLE * 3)

	# 9. Post-game analysis, then home
	_expect_state("POST_GAME", "resolution Continue")
	_shot("10_post_game.png")
	await _check_map_replay(main_scene)
	await _check_replay(main_scene)
	_press(main_scene.get("post_game_screen"), "return_button")
	await _wait(SETTLE)
	_expect_state("MAIN_MENU", "post-game Return")
	var parked: Node3D = _locator.get_service("PlayerController") as Node3D
	_expect(parked == null or not parked.visible, "player parked (hidden) after the run")
	_shot("11_main_menu_again.png")
	await _check_logbook(main_scene)

	# 10. Second run: a different mountain (unlocked by the clean return),
	#     ended by a real fall -> fatal event sequence
	_press(main_scene.get("main_menu"), "new_descent_button")
	await _wait(SETTLE)
	_expect_state("MOUNTAIN_SELECT", "second New Descent")
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	_expect(is_instance_valid(mountain_db) and mountain_db.is_unlocked("north_face"), "north_face unlocked by finishing knife_edge")
	if select_screen != null and select_screen.has_method("_select_mountain"):
		select_screen._select_mountain("north_face")
	if select_screen != null and select_screen.has_method("_on_continue_pressed"):
		select_screen._on_continue_pressed()
	await _wait(SETTLE)
	_expect_state("LOADOUT_CONFIG", "second mountain Continue")
	var loadout_mountain: Object = loadout_screen.get("mountain") if loadout_screen != null else null
	_expect(loadout_mountain != null and loadout_mountain.id == "north_face", "loadout screen shows the newly selected mountain")
	if loadout_screen != null and loadout_screen.has_method("_on_start_pressed"):
		loadout_screen._on_start_pressed()
	await _wait(SETTLE * 2)
	_expect_state("PLANNING", "second loadout Start")
	var terrain2: Object = _locator.get_service("TerrainService")
	_expect(is_instance_valid(terrain2) and terrain2.current_mountain == "north_face", "terrain reloaded for north_face")
	_expect(not (main_scene.get("post_game_screen") as Node).visible, "post-game screen hidden while planning")
	confirm = _find_button(planning_screen, "ConfirmButton")
	_expect(confirm != null and not confirm.disabled, "Begin Descent enabled for the second run")
	if confirm != null:
		confirm.pressed.emit()
	await _wait(DESCENT_SETTLE)
	_expect_state("DESCENT", "second Begin Descent")
	var player2: Node3D = _locator.get_service("PlayerController") as Node3D
	_expect(player2 != null and player2.is_inside_tree() and player2.visible, "player alive and visible in the second run")
	if player2 != null:
		_expect(player2.is_on_floor(), "player on the ground in the second run")
	_shot("12_second_descent.png")

	# A long fall: the fatality detector should run the full fatal sequence
	if player2 != null:
		player2.global_position = player2.global_position + Vector3(0, 120, 0)
	var fatal_waited := 0
	while _state() == int(_states["DESCENT"]) and fatal_waited < 60 * 45:
		await process_frame
		fatal_waited += 1
	_expect_state("RESOLUTION", "the fall's fatal event sequence")
	var run2: Object = _state_manager.current_run
	_expect(run2 != null and run2.outcome == int(_enums.ResolutionType["FATALITY"]), "second run ended in FATALITY")
	await _wait(SETTLE * 3)
	_shot("13_resolution_fatality.png")
	_press(main_scene.get("resolution_screen"), "continue_button")
	await _wait(SETTLE * 3)
	_expect_state("POST_GAME", "second resolution Continue")
	var retry_after_fatality: Button = (main_scene.get("post_game_screen") as Node).get("retry_button") as Button
	_expect(retry_after_fatality != null and not retry_after_fatality.visible, "no Retry offered after a fatality")
	await _check_fatal_replay(main_scene)
	_press(main_scene.get("post_game_screen"), "return_button")
	await _wait(SETTLE)
	_expect_state("MAIN_MENU", "second Return")

	# 11. Third run on knife_edge, completed, then Retry from the post-game screen
	_press(main_scene.get("main_menu"), "new_descent_button")
	await _wait(SETTLE)
	if select_screen != null and select_screen.has_method("_select_mountain"):
		select_screen._select_mountain("knife_edge")
	if select_screen != null and select_screen.has_method("_on_continue_pressed"):
		select_screen._on_continue_pressed()
	await _wait(SETTLE)
	if loadout_screen != null and loadout_screen.has_method("_on_start_pressed"):
		loadout_screen._on_start_pressed()
	await _wait(SETTLE * 2)
	_expect_state("PLANNING", "third loadout Start")
	confirm = _find_button(planning_screen, "ConfirmButton")
	if confirm != null:
		confirm.pressed.emit()
	await _wait(DESCENT_SETTLE)
	_expect_state("DESCENT", "third Begin Descent")
	var player3: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain3: Object = _locator.get_service("TerrainService")
	if player3 != null and is_instance_valid(terrain3):
		_expect(player3.is_on_floor(), "player on the ground in the third run")
		player3.global_position = terrain3.goal_position + Vector3(0, 1, 0)
	await _wait(40)
	_expect_state("RESOLUTION", "arriving at base camp on the third run")
	_press(main_scene.get("resolution_screen"), "continue_button")
	await _wait(SETTLE * 3)
	_expect_state("POST_GAME", "third resolution Continue")
	var retry_button: Button = (main_scene.get("post_game_screen") as Node).get("retry_button") as Button
	_expect(retry_button != null and retry_button.visible, "Retry offered after a return")
	if retry_button != null:
		retry_button.pressed.emit()
	await _wait(SETTLE * 2)
	_expect_state("PLANNING", "post-game Retry")
	_expect(not (main_scene.get("post_game_screen") as Node).visible, "post-game screen hidden after Retry")
	var frozen: Node3D = _locator.get_service("PlayerController") as Node3D
	_expect(frozen == null or frozen.process_mode == Node.PROCESS_MODE_DISABLED, "climber frozen while planning the retry")
	confirm = _find_button(planning_screen, "ConfirmButton")
	if confirm != null:
		confirm.pressed.emit()
	await _wait(DESCENT_SETTLE)
	_expect_state("DESCENT", "retry Begin Descent")
	var player4: Node3D = _locator.get_service("PlayerController") as Node3D
	if player4 != null and is_instance_valid(terrain3):
		_expect(player4.is_on_floor(), "player on the ground on the retry")
		_expect(player4.global_position.distance_to(terrain3.start_position) < 3.0, "retry starts at the summit plateau")
		player4.global_position = terrain3.goal_position + Vector3(0, 1, 0)
	await _wait(40)
	_expect_state("RESOLUTION", "arriving at base camp on the retry")
	_press(main_scene.get("resolution_screen"), "continue_button")
	await _wait(SETTLE * 3)
	_press(main_scene.get("post_game_screen"), "return_button")
	await _wait(SETTLE)
	_expect_state("MAIN_MENU", "final Return")
	_shot("14_main_menu_final.png")

	_finish("")


# =============================================================================
# HELPERS
# =============================================================================

func _state() -> int:
	var state: int = _state_manager.current_state
	return state


func _expect_state(name: String, after: String) -> void:
	var wanted: int = int(_states[name])
	_expect(_state() == wanted, "state is %s after %s (got %d)" % [name, after, _state()])


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("[ui_tour] ok: %s" % what)
	else:
		print("[ui_tour] FAILED: %s" % what)
		_failures.append(what)


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


## Emit pressed on a Button stored in a screen's variable
func _press(screen: Object, button_var: String) -> void:
	if screen == null:
		_expect(false, "screen for '%s' exists" % button_var)
		return
	var button: Button = screen.get(button_var) as Button
	if button == null:
		_expect(false, "button '%s' exists" % button_var)
		return
	button.pressed.emit()


func _find_button(parent: Node, button_name: String) -> Button:
	if parent == null:
		return null
	return parent.find_child(button_name, true, false) as Button


func _find_node(parent: Node, node_name: String) -> Node:
	if parent == null:
		return null
	return parent.find_child(node_name, true, false)


## The loadout screen's summary panel is filled in from the loadout (it
## once showed "0.0 kg" for any pack: its labels were looked up by a node path
## that never matched)
func _check_loadout_summary(screen: Node) -> void:
	if screen == null:
		_expect(false, "loadout screen exists")
		return
	var content := "MainContainer/Content/SummaryPanel/MarginContainer/SummaryContent"
	var weight: Label = screen.get_node_or_null(content + "/WeightValue") as Label
	var loadout: Object = screen.get("current_loadout")
	_expect(weight != null and loadout != null and loadout.total_weight > 1.0
		and weight.text == "%.1f kg" % loadout.total_weight,
		"the loadout summary shows the pack's weight (%s)" % (weight.text if weight != null else "no label"))
	var stats: Node = screen.get_node_or_null(content + "/LoadoutStats")
	var messages: Node = screen.get_node_or_null(content + "/ValidationMessages")
	_expect(stats != null and stats.get_child_count() >= 2, "and what the loadout does to speed and warmth")
	_expect(messages != null and messages.get_child_count() >= 1, "and whether the mountain's requirements are met")


## The plan chooses the day: how the climb went and the weather window, each
## with a line saying what it costs. (Every run used to start from one fixed
## preset, in weather drawn at random.) Leaves the day on a steady climb in
## settled weather.
func _check_day_choice(planning: Node) -> void:
	var climb: OptionButton = planning.get("climb_picker") if planning != null else null
	var weather: OptionButton = planning.get("weather_picker") if planning != null else null
	_expect(climb != null and climb.is_visible_in_tree() and climb.item_count >= 3, "the plan offers a choice of climbs")
	_expect(weather != null and weather.is_visible_in_tree() and weather.item_count >= 3, "the plan offers a choice of weather windows")
	if climb == null or weather == null:
		return
	var last := weather.item_count - 1
	weather.select(last)
	weather.item_selected.emit(last)
	climb.select(0)
	climb.item_selected.emit(0)
	await _wait(SETTLE)
	var weather_note: Label = planning.get("weather_note")
	var climb_note: Label = planning.get("climb_note")
	_expect(weather_note != null and weather_note.is_visible_in_tree() and weather_note.text.contains("logbook"),
		"the hardest window says what it counts for")
	_expect(climb_note != null and climb_note.is_visible_in_tree() and climb_note.text.contains("daylight"),
		"the climb says how much of the day it leaves")
	_shot("04b_planning_storm_day.png")
	planning.set_day("steady", "settled")
	await _wait(2)
	_expect(weather.selected == 0 and planning.weather_id == "settled", "the day is back on settled weather")


## The pause menu's Save and Quit sets the run aside and goes to the main
## menu, which now offers Continue; Continue puts the climber back where they
## stood. (Continue used to appear after any finished run and do nothing, and
## the only way out of a descent was to abandon it.) Ends paused, as it began.
func _check_save_and_continue(main_scene: Node, pause_menu_node: Node) -> void:
	var saves: Node = _locator.get_service("SaveManager") as Node
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var save_quit: Button = pause_menu_node.get("save_quit_button")
	_expect(save_quit != null and save_quit.is_visible_in_tree() and not save_quit.disabled, "the pause menu offers Save and Quit")
	if saves == null or player == null or save_quit == null:
		return
	# A file of the tour's own: whoever runs this keeps their own saved run
	var real_path: String = saves.suspend_path
	saves.suspend_path = "user://suspended_run_ui_tour.dat"
	var stood: Vector3 = player.global_position
	var run_id: String = _state_manager.current_run.run_id
	save_quit.pressed.emit()
	await _wait(SETTLE * 2)
	_expect_state("MAIN_MENU", "Save and Quit")
	var menu: Node = main_scene.get("main_menu")
	var continue_button: Button = menu.get("continue_button") if menu != null else null
	_expect(continue_button != null and continue_button.is_visible_in_tree(), "the main menu offers Continue for the run set aside")
	_shot("07e_menu_continue.png")
	if continue_button == null:
		saves.suspend_path = real_path
		return
	continue_button.pressed.emit()
	await _wait(DESCENT_SETTLE)
	_expect_state("DESCENT", "Continue")
	var run: Object = _state_manager.current_run
	_expect(run != null and run.run_id == run_id, "Continue brings the same run back")
	_expect(player.visible and player.global_position.distance_to(stood) < 1.5,
		"the climber stands where they stood (%.2f m off)" % player.global_position.distance_to(stood))
	_expect(not menu.visible, "the main menu is gone")
	_expect(not saves.has_suspended_run(), "the save is used up")
	_shot("07f_continued.png")
	saves.clear_suspended_run()
	saves.suspend_path = real_path
	_state_manager.toggle_pause()
	await _wait(SETTLE)
	_expect_state("PAUSED", "pausing the continued descent")


## The main menu's Settings opens the settings screen: three pages, controls
## that change settings, and Back. (The button used to do nothing.)
func _check_settings(main_scene: Node, shot_prefix: String) -> void:
	_press(main_scene.get("main_menu"), "settings_button")
	await _wait(SETTLE)
	var screen: Control = main_scene.get("settings_screen") as Control
	_expect(screen != null and screen.visible, "the main menu's Settings opens the settings screen")
	if screen == null:
		return
	var tabs: TabContainer = screen.get("tabs")
	_expect(tabs != null and tabs.get_tab_count() == 3, "with Sound, Display and Controls pages")
	var names := ["sound", "display", "controls"]
	for page in range(tabs.get_tab_count()):
		tabs.current_tab = page
		await _wait(SETTLE)
		_shot("%s_%s.png" % [shot_prefix, names[page]])
	tabs.current_tab = 0
	var settings: Node = _locator.get_service("GameSettings") as Node
	var controls: Dictionary = screen.get("_controls")
	(controls["volume_ambient"] as HSlider).value = 0.5
	await _wait(3)
	var ambient_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Ambient"))
	_expect(is_equal_approx(settings.get_value("volume_ambient"), 0.5) and absf(ambient_db + 12.04) < 0.2,
		"turning the wind down turns the wind down (%.1f dB)" % ambient_db)
	settings.reset()
	_press(screen, "back_button")
	await _wait(SETTLE)
	_expect(not screen.visible and (main_scene.get("main_menu") as Control).visible, "Back returns to the main menu")


## The main menu's Logbook shows the lifetime record, with the run just made
## in it. (The screen existed but nothing opened it, and its panels could not
## find their own contents.)
func _check_logbook(main_scene: Node) -> void:
	_press(main_scene.get("main_menu"), "logbook_button")
	await _wait(SETTLE)
	var logbook: Control = main_scene.get("stats_display") as Control
	_expect(logbook != null and logbook.visible, "the main menu's Logbook opens the lifetime record")
	if logbook == null:
		return
	_expect(logbook.size.x > 600.0 and logbook.size.y > 400.0, "and it fills the screen (%s)" % logbook.size)
	var save: Object = _locator.get_service("SaveManager")
	var runs: int = save.get_profile().total_runs
	for panel_name in ["LifetimeStatistics", "RecentRuns", "Achievements"]:
		var panel: Node = logbook.find_child(panel_name, true, false)
		var content: Node = panel.find_child("Content", true, false) if panel != null else null
		# Every panel starts with its title and a rule; anything more is content
		_expect(content != null and content.get_child_count() > 2,
			"its %s panel has something in it (%d rows)" % [panel_name, content.get_child_count() if content != null else -1])
	_expect(runs >= 1, "the run just finished is on record (%d runs)" % runs)
	_shot("11b_logbook.png")
	var close: Button = _find_button(logbook, "CloseButton")
	_expect(close != null, "the logbook has a Close button")
	if close != null:
		close.pressed.emit()
	await _wait(SETTLE)
	_expect(not logbook.visible and (main_scene.get("main_menu") as Control).visible, "Close returns to the main menu")


## "Replay on the map" on the post-game screen opens the topo replay with the
## line that was travelled, and Close comes back. (The replay screen existed
## for a long time with no button that opened it.)
func _check_map_replay(main_scene: Node) -> void:
	var post_game: Node = main_scene.get("post_game_screen")
	_press(post_game, "replay_button")
	await _wait(SETTLE)
	var replay: Node = main_scene.get("topo_replay")
	_expect(replay != null and replay.visible, "Replay on the map opens the map replay")
	if replay == null:
		return
	var run: Object = _state_manager.current_run
	_expect(replay.path_points_3d.size() >= 2 and replay.path_points_3d.size() == run.path_history.size(),
		"with the line that was travelled (%d points)" % replay.path_points_3d.size())
	_expect(replay.topo_texture != null, "drawn over the mountain's topo map")
	_expect(replay.total_duration > 0.0, "and a day to play back (%.3f game hours)" % replay.total_duration)
	await _wait(SETTLE * 2)
	_shot("10b_map_replay.png")
	# While the line is still drawing itself, the first press only finishes it
	if replay.is_drawing_path:
		replay.play_button.pressed.emit()
	replay.play_button.pressed.emit()
	_expect(replay.is_playing, "Play starts the day playing")
	await _wait(SETTLE * 3)
	_expect(replay.playback_time > 0.0, "and moves the playhead through it")
	_press(replay, "close_button")
	await _wait(SETTLE)
	_expect(not replay.visible and post_game.visible, "Close returns to the post-game screen")


## "Watch it again" on the post-game screen replays the run on the mountain:
## the climber where they were, three cameras, a timeline, the day's moments,
## and Close comes back to the summary with everything as it was.
func _check_replay(main_scene: Node) -> void:
	var post_game: Control = main_scene.get("post_game_screen") as Control
	var watch: Button = post_game.get("watch_button") as Button
	_expect(watch != null and watch.visible and not watch.disabled, "the post-game screen offers Watch it again")
	if watch == null:
		return
	var climber: Node3D = _locator.get_service("PlayerController") as Node3D
	var at_rest: Vector3 = climber.global_position
	var game_camera: Camera3D = root.get_viewport().get_camera_3d()
	watch.pressed.emit()
	await _wait(SETTLE)
	var screen: Control = main_scene.get("replay_screen") as Control
	var stage: Node3D = main_scene.get("replay_stage") as Node3D
	var replays: Node = _locator.get_service("ReplayPlayer")
	_expect(screen != null and screen.visible and not post_game.visible, "Watch it again opens the replay in place of the summary")
	if screen == null or stage == null:
		return
	var replay_camera: Camera3D = stage.get("camera") as Camera3D
	_expect(replay_camera != null and replay_camera.current and root.get_viewport().get_camera_3d() == replay_camera,
		"seen through the replay's own camera")
	_expect(replays.is_playing() and replays.get_duration() > 1.0, "and playing (%.1f s of the run)" % replays.get_duration())
	_expect_state("POST_GAME", "opening the replay")
	_shot("10c_replay.png")

	# From the start of the day: the climber is back where the run began
	replays.pause()
	replays.seek(replays.get_start())
	await _wait(3)
	var terrain: Object = _locator.get_service("TerrainService")
	_expect(climber.global_position.distance_to(terrain.start_position) < 6.0 and climber.global_position.distance_to(at_rest) > 10.0,
		"wound back to the start, the climber is at the summit again")
	_shot("10d_replay_start.png")

	# Each camera
	var names: Array[String] = []
	for i in range(3):
		names.append((screen.get("camera_button") as Button).text)
		if i > 0:
			_shot("10e_replay_camera_%d.png" % i)
		_press(screen, "camera_button")
		await _wait(SETTLE)
	_expect(names[0] != names[1] and names[1] != names[2] and names[0] != names[2], "the camera button goes round three cameras %s" % [names])
	_expect((screen.get("camera_button") as Button).text == names[0], "and back to the first")

	# Speed, and the day's moments
	_press(screen, "speed_button")
	_expect(is_equal_approx(replays.playback_speed, 2.0) and (screen.get("speed_button") as Button).text.contains("2"), "the speed button doubles the speed")
	_press(screen, "speed_button")
	_press(screen, "speed_button")
	_press(screen, "speed_button")
	_press(screen, "speed_button")
	_expect(is_equal_approx(replays.playback_speed, 1.0), "and comes round to normal speed")
	(screen.get("list_button") as Button).button_pressed = true
	await _wait(SETTLE)
	var list_panel: Control = screen.get("list_panel") as Control
	_expect(list_panel.visible and (screen.get("list_box") as Node).get_child_count() >= 1, "Moments opens the list of the day's moments")
	_shot("10f_replay_moments.png")
	(screen.get("list_button") as Button).button_pressed = false

	# Play to the end
	replays.seek(replays.get_end() - 1.0)
	replays.play()
	var waited := 0
	while replays.is_playing() and waited < 600:
		await process_frame
		waited += 1
	_expect(not replays.is_playing() and absf(replays.current_timestamp - replays.get_end()) < 0.05, "played out, it stops at the end of the run")

	_press(screen, "close_button")
	await _wait(SETTLE)
	_expect(not screen.visible and post_game.visible, "Close returns to the summary")
	_expect(root.get_viewport().get_camera_3d() == game_camera, "with the game's camera back")
	_expect(climber.global_position.distance_to(at_rest) < 0.05, "and the climber where the run left them")
	_expect_state("POST_GAME", "closing the replay")


## A run that ended in a fatal event is replayed under the rules for one
## (SPEC-SHEET 11): normal speed, one fixed camera, the fatal moments once as
## one take with nothing else on the screen, and then the path on the map.
func _check_fatal_replay(main_scene: Node) -> void:
	var post_game: Control = main_scene.get("post_game_screen") as Control
	_press(post_game, "watch_button")
	await _wait(SETTLE)
	var screen: Control = main_scene.get("replay_screen") as Control
	var replays: Node = _locator.get_service("ReplayPlayer")
	_expect(screen != null and screen.visible, "the fatal run can be watched again")
	if screen == null or not screen.visible:
		return
	_expect(bool(replays.is_fatal_run), "and the replay knows what kind of run it was")
	_expect(not (screen.get("speed_button") as Button).visible and not (screen.get("camera_button") as Button).visible,
		"it offers no change of speed and no change of camera")
	replays.seek(replays.get_end())
	_expect(replays.current_timestamp <= float(replays.fatal_start) + 0.01, "and cannot be wound past the moment control was lost")
	_shot("13b_fatal_replay.png")

	# Played on from there: the one take, alone on the screen
	replays.play()
	var waited := 0
	while not bool(replays.in_fatal_section) and replays.is_playing() and waited < 1200:
		await process_frame
		waited += 1
	_expect(bool(replays.in_fatal_section), "played on, it enters the fatal moments")
	await _wait(SETTLE)
	_expect(not (screen.get("_bar") as Control).visible and not (screen.get("_top") as Control).visible,
		"shown with nothing else on the screen")
	replays.pause()
	_expect(replays.is_playing(), "and without a pause")
	_shot("13c_fatal_replay_take.png")
	waited = 0
	while replays.is_playing() and waited < 3600:
		await process_frame
		waited += 1
	await _wait(SETTLE)
	_expect(not replays.is_playing() and bool(replays.has_fatal_been_replayed()), "the take ends with the recording")
	var map_button: Button = screen.get("map_button") as Button
	_expect(map_button.visible and (screen.get("note_label") as Label).text.contains("map"), "and the replay points to the map for the rest of the day")
	_shot("13d_fatal_replay_after.png")

	# Not a second time
	replays.play()
	waited = 0
	while replays.is_playing() and waited < 1200:
		await process_frame
		waited += 1
	_expect(not bool(replays.in_fatal_section) and replays.current_timestamp <= float(replays.fatal_start) + 0.01,
		"played again, it stops where control was lost")

	map_button.pressed.emit()
	await _wait(SETTLE)
	var topo: Control = main_scene.get("topo_replay") as Control
	_expect(topo != null and topo.visible and not screen.visible, "Replay on the map opens the map replay")
	if topo != null and topo.visible:
		_press(topo, "close_button")
	await _wait(SETTLE)
	_expect(post_game.visible, "and from there Close returns to the summary")


func _shot(file_name: String) -> void:
	var image: Image = root.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		print("[ui_tour] no viewport image for %s (headless?)" % file_name)
		return
	var path := out_dir.path_join(file_name)
	if image.save_png(path) == OK:
		_shots.append(path)
		print("[ui_tour] saved %s" % path)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	print("[ui_tour] %d screenshot(s) in %s" % [_shots.size(), out_dir])
	if _failures.is_empty():
		print("[ui_tour] PASS")
		quit(0)
	else:
		print("[ui_tour] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
