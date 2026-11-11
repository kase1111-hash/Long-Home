extends SceneTree
## Continue across a restart: a run saved in one launch of the game is picked
## up in the next.
##
## tests/test_front_end.gd sets a run aside and picks it up in the same
## launch, where the mountain, the climber and every system are already
## there. This is the case the feature is for: the game was closed in between.
##
## Run from the project root, twice, in this order:
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_continue.gd -- --phase=save
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_continue.gd -- --phase=continue
## Each exits 0 on PASS and 1 on FAIL (prints "[test_continue] PASS" / "FAIL: ...").
## Add --full-route to both to save part-way up a full route (base camp to
## the summit and back) instead of on a descent.
##
## The first starts a descent of the North Face the way a player does (a hard
## climb, a front coming in), gets part of the way into the day, saves from
## the pause menu and quits. The second finds Continue on the main menu and
## checks that it brings back that run: the mountain, where the climber
## stood, the clock, the weather and the rest of its day, the body, the pack
## and the day's record so far.
##
## The mountain itself comes back as it was left: in the first launch an
## avalanche runs and a snow bridge falls into its crevasse; in the second
## the bed, the debris, the crown and the open slot are still there.
##
## Both use a save file of the test's own (user://suspended_run_test_continue.dat):
## a run the person running this has set aside is not touched. What the
## first launch saw is handed to the second in user://test_continue_expect.dat;
## both files are removed at the end.
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time (see
## tests/smoke_goal.gd).

const MOUNTAIN := "north_face"
const TEST_SUSPEND := "user://suspended_run_test_continue.dat"
const EXPECT_PATH := "user://test_continue_expect.dat"

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _main: Node = null
var _failures: Array[String] = []
var _checks: int = 0
var _phase: String = ""
var _full_route: bool = false


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with("--phase="):
			_phase = str(arg).trim_prefix("--phase=")
		elif str(arg) == "--full-route":
			_full_route = true
	call_deferred("_run")


func _run() -> void:
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	if _state_manager == null or _enums == null or _locator == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	if _phase != "save" and _phase != "continue":
		_finish("say which launch this is: -- --phase=save, then -- --phase=continue")
		return

	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	await _wait(10)
	var settings: Object = _locator.get_service("GameSettings")
	if is_instance_valid(settings):
		settings.persist = false
	var saves: Node = _locator.get_service("SaveManager") as Node
	if saves == null:
		_finish("no save manager")
		return
	saves.suspend_path = TEST_SUSPEND

	if _phase == "save":
		await _save_phase(saves)
	else:
		await _continue_phase(saves)


# =============================================================================
# FIRST LAUNCH: into the day, then Save and Quit
# =============================================================================

func _save_phase(saves: Node) -> void:
	var states: Dictionary = _enums.GameState
	saves.clear_suspended_run()
	if FileAccess.file_exists(EXPECT_PATH):
		DirAccess.remove_absolute(EXPECT_PATH)

	# A day on which slopes can release (High danger), so one can be set off
	var bulletin: Object = _locator.get_service("AvalancheService")
	bulletin.set_today(MOUNTAIN, bulletin.generate_with_danger(MOUNTAIN, 4, 11))

	# Menu, mountain, pack and plan, as a player goes through them
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	mountain_db.select_mountain(MOUNTAIN, true)
	if _full_route:
		# The developer's way in: the full route without finishing the game first
		mountain_db.full_route_override = true
		mountain_db.set_route_mode(int(_enums.RouteMode["FULL_ROUTE"]))
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(2)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(2)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(10)
	var planning: Control = _main.get("planning_screen")
	if planning == null:
		_finish("no planning screen")
		return
	planning.set_day("fast", "front")
	var waited := 0
	while not planning.route_valid and waited < 600:
		await process_frame
		waited += 1
	planning.confirm_button.pressed.emit()
	await _wait(40)
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	if int(_state_manager.current_state) != int(states["DESCENT"]) or player == null:
		_finish("the descent did not start")
		return

	# The dice are put away; what happens next is what the test does (the
	# snow can still run, but nothing sets it off by chance)
	player.posture.micro_slip_probability_scale = 0.0
	var weather: Node = _locator.get_service("WeatherService") as Node
	weather.base_change_probability = 0.0
	var avalanches: Object = _locator.get_service("AvalancheSystem")
	if is_instance_valid(avalanches):
		avalanches.trigger_scale = 0.0
		avalanches.natural_scale = 0.0

	# Part of the way into the day: some ground covered, a body and a pack
	# that are no longer the ones the day started with
	var run: Object = _state_manager.current_run
	Input.action_press("move_forward")
	await _seconds(6.0)
	Input.action_release("move_forward")
	await _seconds(0.5)
	run.body_state.fatigue = 0.58
	run.body_state.hydration = 0.44
	run.body_state.cold_exposure = 0.21
	var strain: Resource = (load("res://src/core/data/injury.gd") as GDScript).new(
		int(_enums.InjuryType["STRAIN"]), 0.2, int(_enums.BodyPart["RIGHT_ARM"]), run.current_time)
	run.body_state.add_injury(strain)
	run.gear_state.damage_item(int(_enums.GearType["CRAMPONS"]), 0.35)
	player.set_footwear(int(_enums.Footwear["BOOTS"]))
	await _seconds(0.5)
	# --- the mountain changes: an avalanche runs, a snow bridge falls ---------
	var terrain: Object = _locator.get_service("TerrainService")
	var mountain_expect := {}
	_expect(is_instance_valid(avalanches) and avalanches.active and avalanches.field != null, "the day's snowpack is on the mountain")
	if is_instance_valid(avalanches) and avalanches.active and avalanches.field != null:
		var recents: int = avalanches._settled.size()
		var flow: Object = null
		var tries := 0
		while flow == null and tries < 30:
			tries += 1
			var start_cell: int = avalanches.field.pick_start(avalanches._rng, 0.6)
			if start_cell >= 0:
				flow = avalanches.release(start_cell, true)
		_expect(flow != null, "a slope releases")
		_expect(_main.get_suspend_block_reason() != "", "the run cannot be saved while the snow is moving")
		var waited_frames := 0
		while not avalanches.flows.is_empty() and waited_frames < 60 * 180:
			await physics_frame
			waited_frames += 1
		_expect(avalanches.flows.is_empty() and avalanches._settled.size() == recents + 1,
			"the avalanche comes to rest (after %d frames; %d on the mountain with the earlier ones)" % [waited_frames, avalanches._settled.size()])
		mountain_expect["settled"] = avalanches._settled.size()

	var glacier: Object = terrain.glacier
	_expect(glacier != null and glacier.count_bridged() > 0, "the mountain has a glacier with snow bridges")
	if glacier != null:
		for slot in glacier.crevasses:
			if not slot.bridged or slot.width < 1.4 or slot.points.size() < 2:
				continue
			var centre: Vector2 = slot.points[0].lerp(slot.points[1], 0.5)
			if centre.distance_to(Vector2(player.global_position.x, player.global_position.z)) < 30.0:
				continue
			var lip: float = terrain.get_height_at(Vector3(centre.x, 0.0, centre.y))
			terrain.carve_crevasse_section(slot, centre, minf(6.0, slot.depth))
			slot.probed = true
			var crevasses: Object = _locator.get_service("CrevasseSystem")
			crevasses._leave_probe_hole(centre + Vector2(1.5, 0.0))
			var floor_height: float = terrain.get_height_at(Vector3(centre.x, 0.0, centre.y))
			_expect(not slot.is_bridged_at(centre) and floor_height < lip - 2.0, "a snow bridge falls into its crevasse (%.1f m down)" % (lip - floor_height))
			mountain_expect["crevasse_id"] = slot.id
			mountain_expect["crevasse_centre"] = centre
			mountain_expect["crevasse_floor"] = floor_height
			mountain_expect["probe_holes"] = (crevasses.to_save()["probe_holes"] as PackedVector2Array).size()
			break
	_expect(mountain_expect.has("crevasse_id"), "a bridge was found to break")

	# What the ground looks like now, where it changed most
	var changes: Dictionary = terrain.get_changes()
	var heights: Dictionary = changes["heights"]
	var keys: Array = heights.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return absf(heights[a]) > absf(heights[b]))
	var samples: Array = []
	for i in range(mini(12, keys.size())):
		var at: Vector2 = terrain.vertex_position(keys[i])
		samples.append([at, terrain.get_height_at(Vector3(at.x, 0.0, at.y))])
	var debris_cells: Array = []
	for key in (changes["debris"] as Dictionary).keys().slice(0, 6):
		var at: Vector2 = terrain.vertex_position(key)
		debris_cells.append([at, terrain.get_cell_at(Vector3(at.x, 0.0, at.y)).debris_depth])
	var bed_cells: Array = []
	for key in (changes["beds"] as Array).slice(0, 6):
		bed_cells.append(terrain.vertex_position(key))
	mountain_expect["changed"] = heights.size()
	mountain_expect["samples"] = samples
	mountain_expect["debris_cells"] = debris_cells
	mountain_expect["bed_cells"] = bed_cells
	_expect(heights.size() > 50 and not debris_cells.is_empty(), "the avalanche and the crevasse changed the ground (%d vertices, debris on %d)" % [heights.size(), (changes["debris"] as Dictionary).size()])
	await _seconds(0.5)
	_expect(_main.get_suspend_block_reason() == "", "the run can be saved where the climber stands (%s)" % _main.get_suspend_block_reason())

	_state_manager.toggle_pause()
	await _wait(10)
	var pause_menu: Control = _main.get("pause_menu")
	var save_quit: Button = pause_menu.get("save_quit_button") if pause_menu != null else null
	_expect(save_quit != null and not save_quit.disabled, "the pause menu offers Save and Quit")
	if save_quit == null:
		_finish("no Save and Quit")
		return

	var time: Node = _locator.get_service("TimeService") as Node
	var windows: Array = []
	for window in weather.weather_windows:
		windows.append([int(window.weather), int(window.wind_strength)])
	_expect(run.is_full_route() == _full_route, "the run is %s" % ("a full route, on the way up" if _full_route else "a descent"))
	var expect := {
		"full_route": _full_route,
		"climb_id": str(run.start_conditions.climb_id),
		"start_hour": float(run.start_conditions.time_of_day),
		"planned_ascent": (run.get_meta("planned_ascent", PackedVector3Array()) as PackedVector3Array).size(),
		"run_id": run.run_id,
		"position": player.global_position,
		"yaw": player.rotation.y,
		"clock": float(time.current_time),
		"elapsed": float(run.game_time_elapsed),
		"distance": float(run.distance_traveled),
		"path": run.path_history.size(),
		"decisions": run.decisions.size(),
		"incidents": run.incidents.size(),
		"weather": int(weather.target_weather if weather.is_transitioning else weather.current_weather),
		"wind": int(weather.current_wind_strength),
		"windows": windows,
		"items": run.gear_state.items.size(),
		"crampons": float(run.gear_state.get_item(int(_enums.GearType["CRAMPONS"])).condition_value),
		"avalanche_seed": int(run.start_conditions.avalanche.seed),
		"avalanche_headline": str(run.start_conditions.avalanche.headline),
		"start_elevation": float(run.start_elevation),
		"planned": (run.get_meta("planned_route", PackedVector3Array()) as PackedVector3Array).size(),
		"mountain": mountain_expect,
		# (the body goes on tiring, resting and cooling while the avalanche runs)
		"fatigue": float(run.body_state.fatigue),
		"hydration": float(run.body_state.hydration),
		"cold": float(run.body_state.cold_exposure),
	}
	_expect(expect["path"] > 3 and expect["distance"] > 3.0, "the day has a record so far (%d samples, %.0f m)" % [expect["path"], expect["distance"]])

	save_quit.pressed.emit()
	await _wait(20)
	_expect(int(_state_manager.current_state) == int(states["MAIN_MENU"]), "Save and Quit goes to the main menu")
	_expect(_state_manager.current_run == null, "the run is set aside")
	_expect(saves.has_suspended_run(), "and is on disk")
	var file := FileAccess.open(EXPECT_PATH, FileAccess.WRITE)
	if file == null:
		_finish("could not write what the next launch should find")
		return
	file.store_var(expect, false)
	file.close()
	# The game is closed here, with the run on disk
	_finish("")


# =============================================================================
# SECOND LAUNCH: Continue
# =============================================================================

func _continue_phase(saves: Node) -> void:
	var states: Dictionary = _enums.GameState
	if not FileAccess.file_exists(EXPECT_PATH):
		_finish("nothing to continue: run this with -- --phase=save first")
		return
	var file := FileAccess.open(EXPECT_PATH, FileAccess.READ)
	var expect: Dictionary = file.get_var(false)
	file.close()

	_expect(int(_state_manager.current_state) == int(states["MAIN_MENU"]), "the game opens on the main menu")
	_expect(_locator.get_service("PlayerController") == null and _locator.get_service("TerrainService") == null,
		"with no mountain and no climber yet (a fresh launch)")
	var menu: Control = _main.get("main_menu")
	menu.refresh()
	var continue_button: Button = menu.get("continue_button")
	_expect(continue_button.visible and continue_button.text.contains("North Face"), "the main menu offers to continue the North Face (%s)" % continue_button.text)

	continue_button.pressed.emit()
	await _wait(80)
	var run: Object = _state_manager.current_run
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	if int(_state_manager.current_state) != int(states["DESCENT"]) or run == null or player == null:
		_cleanup(saves)
		_finish("Continue did not bring the run back (state %d)" % int(_state_manager.current_state))
		return

	_expect(run.run_id == expect["run_id"] and run.mountain_id == MOUNTAIN, "Continue brings that run back (%s)" % run.mountain_id)
	var terrain: Object = _locator.get_service("TerrainService")
	_expect(terrain != null and terrain.current_mountain == MOUNTAIN, "on its mountain")
	var off: float = player.global_position.distance_to(expect["position"])
	_expect(off < 1.5, "the climber stands where they stood (%.2f m off)" % off)
	var ground: float = terrain.get_height_at(player.global_position)
	_expect(player.global_position.y > ground - 0.2 and player.global_position.y < ground + 2.5, "on the ground (%.2f m above it)" % (player.global_position.y - ground))
	_expect(absf(angle_difference(player.rotation.y, expect["yaw"])) < 0.05, "facing the way they faced")
	_expect(int(player.footwear) == int(_enums.Footwear["BOOTS"]), "in their boots, as they were")
	var time: Node = _locator.get_service("TimeService") as Node
	_expect(absf(time.current_time - expect["clock"]) < 0.15, "the clock is where it was (%.2f, was %.2f)" % [time.current_time, expect["clock"]])
	_expect(run.game_time_elapsed >= expect["elapsed"] and run.game_time_elapsed < expect["elapsed"] + 0.15,
		"the day's elapsed time carries on (%.3f h, was %.3f)" % [run.game_time_elapsed, expect["elapsed"]])
	var weather: Node = _locator.get_service("WeatherService") as Node
	_expect(int(weather.current_weather) == expect["weather"] and int(weather.current_wind_strength) == expect["wind"],
		"the weather is the weather that was (%s, %s)" % [_enums.WeatherState.keys()[weather.current_weather], _enums.WindStrength.keys()[weather.current_wind_strength]])
	var windows: Array = []
	for window in weather.weather_windows:
		windows.append([int(window.weather), int(window.wind_strength)])
	_expect(windows == expect["windows"], "and the rest of its day is the same day (%d windows)" % windows.size())
	_expect(absf(run.body_state.fatigue - float(expect["fatigue"])) < 0.04 and absf(run.body_state.hydration - float(expect["hydration"])) < 0.04 \
		and absf(run.body_state.cold_exposure - float(expect["cold"])) < 0.04,
		"the body is as it was (fatigue %.2f, water %.2f, cold %.2f; were %.2f, %.2f, %.2f)" % [run.body_state.fatigue, run.body_state.hydration,
			run.body_state.cold_exposure, float(expect["fatigue"]), float(expect["hydration"]), float(expect["cold"])])
	_expect(run.body_state.injuries.size() == 1 and int(run.body_state.injuries[0].type) == int(_enums.InjuryType["STRAIN"]), "the strained arm is still strained")
	var body_service: Node = _locator.get_service("BodyConditionService") as Node
	_expect(body_service != null and body_service.body_state == run.body_state and player.body_state == run.body_state,
		"and it is that body the mountain goes on wearing down")
	var crampons: Object = run.gear_state.get_item(int(_enums.GearType["CRAMPONS"]))
	_expect(run.gear_state.items.size() == expect["items"] and crampons != null and absf(crampons.condition_value - expect["crampons"]) < 0.001,
		"the pack is as it was, worn crampons and all (%d items)" % run.gear_state.items.size())
	_expect(run.path_history.size() >= expect["path"] and run.distance_traveled >= expect["distance"] and run.distance_traveled < expect["distance"] + 5.0,
		"the path and the distance so far are kept (%d samples, %.0f m)" % [run.path_history.size(), run.distance_traveled])
	_expect(run.decisions.size() == expect["decisions"] and run.incidents.size() == expect["incidents"],
		"the day's decisions and incidents are the ones made (%d, %d)" % [run.decisions.size(), run.incidents.size()])
	_expect(run.start_conditions.climb_id == expect["climb_id"] and run.start_conditions.weather_id == "front" \
		and is_equal_approx(run.start_conditions.time_of_day, expect["start_hour"]),
		"the day chosen at the hut is remembered (%s, %s, from %.1f h)" % [run.start_conditions.climb_id, run.start_conditions.weather_id, run.start_conditions.time_of_day])
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	_expect(run.is_full_route() == bool(expect["full_route"]) and (int(mountain_db.get_route_mode()) == int(_enums.RouteMode["FULL_ROUTE"])) == bool(expect["full_route"]),
		"and whether it is a descent or the full route")
	if bool(expect["full_route"]):
		_expect(int(run.phase) == int(_enums.RunPhase["ASCENT"]) and not run.summit_reached, "it is still on the way up")
		_expect((run.get_meta("planned_ascent", PackedVector3Array()) as PackedVector3Array).size() == expect["planned_ascent"] and expect["planned_ascent"] >= 2,
			"with the way up that was planned")
		var hud: Node = _main.get("descent_hud")
		if hud != null:
			hud.refresh()
			var caption: Label = hud.find_child("BasecampCaption", true, false)
			_expect(caption != null and caption.text == "Summit", "and the HUD points to the summit")
	_expect(run.start_conditions.avalanche != null and int(run.start_conditions.avalanche.seed) == expect["avalanche_seed"] \
		and str(run.start_conditions.avalanche.headline) == expect["avalanche_headline"], "and it is the same day's snowpack")
	var avalanches: Object = _locator.get_service("AvalancheSystem")
	_expect(is_instance_valid(avalanches) and avalanches.conditions == run.start_conditions.avalanche, "which is the snowpack on the mountain")
	_expect(is_equal_approx(run.start_elevation, expect["start_elevation"]), "progress is still measured from the summit")

	# --- the mountain as it was left ---------------------------------------------
	var left: Dictionary = expect.get("mountain", {})
	var worst := 0.0
	for sample in left.get("samples", []):
		var at: Vector2 = sample[0]
		worst = maxf(worst, absf(terrain.get_height_at(Vector3(at.x, 0.0, at.y)) - float(sample[1])))
	_expect(not (left.get("samples", []) as Array).is_empty() and worst < 0.02,
		"the ground is where the avalanche and the crevasse left it (worst of %d places %.3f m off)" % [(left.get("samples", []) as Array).size(), worst])
	_expect((terrain.get_changes()["heights"] as Dictionary).size() == int(left.get("changed", -1)) and terrain.modified,
		"all of it (%d vertices)" % (terrain.get_changes()["heights"] as Dictionary).size())
	var debris_ok := not (left.get("debris_cells", []) as Array).is_empty()
	for entry in left.get("debris_cells", []):
		var at: Vector2 = entry[0]
		var cell: Object = terrain.get_cell_at(Vector3(at.x, 0.0, at.y))
		if cell == null or absf(cell.debris_depth - float(entry[1])) > 0.01 or int(cell.surface_type) != int(_enums.SurfaceType["SNOW_PACKED"]) and cell.debris_depth >= 0.05:
			debris_ok = false
	_expect(debris_ok, "the debris is debris: as deep as it was, and set hard")
	var beds_ok := true
	for at in left.get("bed_cells", []):
		var cell: Object = terrain.get_cell_at(Vector3(at.x, 0.0, at.y))
		if cell == null or not cell.avalanche_bed:
			beds_ok = false
	_expect(beds_ok, "the bed the slab slid off is still a bed")
	_expect(avalanches._settled.size() == int(left.get("settled", -1)) and avalanches._visuals.size() == avalanches._settled.size(),
		"every avalanche that had run is there to be read, and none was added (%d)" % avalanches._settled.size())
	if left.has("crevasse_id"):
		var slot: Object = null
		for candidate in terrain.glacier.crevasses:
			if candidate.id == left["crevasse_id"]:
				slot = candidate
		var centre: Vector2 = left["crevasse_centre"]
		_expect(slot != null and not slot.is_bridged_at(centre) and slot.probed and slot.collapsed.size() == 1,
			"the bridge that fell is still gone")
		_expect(absf(terrain.get_height_at(Vector3(centre.x, 0.0, centre.y)) - float(left["crevasse_floor"])) < 0.02,
			"and its crevasse is as deep as it was")
		var crevasse_system: Object = _locator.get_service("CrevasseSystem")
		_expect((crevasse_system.to_save()["probe_holes"] as PackedVector2Array).size() == int(left.get("probe_holes", -1)), "the probe hole beside it is still there")
	_expect((run.get_meta("planned_route", PackedVector3Array()) as PackedVector3Array).size() == expect["planned"], "the planned line is still the plan")
	_expect(not saves.has_suspended_run(), "the save is used up")
	_expect(root.get_viewport().get_camera_3d() == player.camera_pivot.camera, "the view is the climber's own")
	_expect(_main.get("descent_hud") != null and (_main.get("world") as Node3D).visible, "the mountain and the HUD are there")

	# It plays on
	player.posture.micro_slip_probability_scale = 0.0
	Input.action_press("move_forward")
	await _seconds(3.0)
	Input.action_release("move_forward")
	# (uphill and tired on a full route, so not far)
	_expect(player.global_position.distance_to(expect["position"]) > 0.5 and run.path_history.size() > expect["path"],
		"the day carries on from there (%.1f m further)" % player.global_position.distance_to(expect["position"]))

	_cleanup(saves)
	_finish("")


func _cleanup(saves: Node) -> void:
	saves.clear_suspended_run()
	if FileAccess.file_exists(EXPECT_PATH):
		DirAccess.remove_absolute(EXPECT_PATH)


# =============================================================================
# HELPERS
# =============================================================================

func _seconds(seconds: float) -> void:
	for i in range(int(ceil(seconds * 60.0))):
		await physics_frame


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_continue] ok: %s" % what)
	else:
		_failures.append(what)
		print("[test_continue] FAILED: %s" % what)


func _finish(fatal: String) -> void:
	if not fatal.is_empty():
		_failures.append(fatal)
	Input.action_release("move_forward")
	if _failures.is_empty():
		print("[test_continue] PASS (%s: %d checks)" % [_phase, _checks])
		quit(0)
	else:
		print("[test_continue] FAIL (%s): %d problem(s): %s" % [_phase, _failures.size(), "; ".join(_failures)])
		quit(1)
