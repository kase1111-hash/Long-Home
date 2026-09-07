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
## resolution, post-game, then a second mountain ending in a real fatal event,
## and a third run completed and retried. Exit code 0 on PASS, 1 on FAIL.
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

	# 1. Main menu
	_expect_state("MAIN_MENU", "boot")
	_shot("01_main_menu.png")
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
	if loadout_screen != null and loadout_screen.has_method("_on_start_pressed"):
		loadout_screen._on_start_pressed()
	await _wait(SETTLE)

	# 4. Planning: the default summit-to-base line must be startable
	_expect_state("PLANNING", "loadout Start")
	await _wait(SETTLE)
	_shot("04_planning.png")
	var planning_screen: Node = main_scene.get("planning_screen")
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
	_press(main_scene.get("post_game_screen"), "return_button")
	await _wait(SETTLE)
	_expect_state("MAIN_MENU", "post-game Return")
	var parked: Node3D = _locator.get_service("PlayerController") as Node3D
	_expect(parked == null or not parked.visible, "player parked (hidden) after the run")
	_shot("11_main_menu_again.png")

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
