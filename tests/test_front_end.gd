extends SceneTree
## Front-end test: the screens around a descent and what they are fed.
##
## Run from the project root:
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_front_end.gd
## Exit code 0 on PASS, 1 on FAIL (prints "[test_front_end] PASS" / "FAIL: ...").
##
## What it covers:
##   - key moments: which recorded decisions and incidents are worth a line in
##     the logbook and on the map replay, and how the line reads (RunMoments)
##   - the lifetime record: achievements survive a save and a load, and the
##     main menu's Logbook builds from the save
##   - settings: each sound level reaches its bus, values are kept in range,
##     a bad settings file cannot put the game in a bad state, they survive a
##     restart, and the settings screen's controls read and write them
##
##   - the day chosen at the hut: the climbs and weather windows are trades
##     (no option is simply better), the planning screen's pickers set the
##     day, the run starts at that hour, in that shape and in that weather,
##     and the day's weather moves on from it a step at a time, worse on a
##     less settled day and on a mountain whose weather turns fast
##   - Save and Quit, and Continue: a run can be set aside only standing and
##     in control; it is written to disk without being recorded as a result;
##     Continue puts back the mountain, the clock, the weather and its day,
##     the body, the pack, what is on the feet, where the climber stood and
##     the day's record so far, and the save is used up; a file this version
##     cannot read is refused; closing the window on a descent keeps it
##   - the run timer: off unless asked for; it shows the run's own clock (so a
##     run set aside and picked up again is timed in one piece) on the HUD and
##     the resolution screen; only a route brought home can be a best, kept
##     per mountain and per way round it
##   - the film crew's drone: it takes off beside the climber and stays with
##     them (walking, moved far away, in a storm), B switches the screen to
##     its camera and back, and a fatal sequence is watched through it, in
##     one take, from a distance, with nothing else on the screen
##
## The test never writes to the settings of whoever runs it: it turns the
## settings service's saving off, and where it tests saving it points the
## service at a file of its own. The same goes for the run it sets aside.
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time (see
## tests/smoke_goal.gd).

const MOUNTAIN := "knife_edge"

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _main: Node = null
var _failures: Array[String] = []
var _checks: int = 0

## The run timer's own file and bests, put back when the test ends
var _real_timer_path: String = ""
var _real_timer_bests: Dictionary = {}
var _real_timer_golds: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_event_bus = root.get_node_or_null("/root/EventBus")
	if _state_manager == null or _enums == null or _locator == null or _event_bus == null:
		_finish("autoloads missing; run with --path <project root>")
		return

	_test_key_moments()

	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	await _wait(5)
	await _test_lifetime_record()
	await _test_settings()
	_test_day_options()
	_test_run_timer_rules()
	if not await _plan_the_day_and_start():
		_finish("could not start a descent")
		return
	if not await _test_save_and_continue():
		_finish("the run that was set aside did not come back")
		return
	await _test_drone()
	_finish("")


# =============================================================================
# KEY MOMENTS
# =============================================================================

func _test_key_moments() -> void:
	var moments: GDScript = load("res://src/ui/analysis/run_moments.gd") as GDScript
	var kinds: Dictionary = moments.Kind

	_expect(moments.describe("start_slide", {}, false) == "Started sliding", "a slide is a key moment")
	_expect(moments.describe("start_downclimb", {"slope": 41.6}, false) == "Began downclimbing (42°)",
		"a downclimb says how steep it was")
	_expect(moments.describe("obstacle_impact", {"object": "boulder"}, true) == "Hit a boulder"
		and moments.describe("obstacle_impact", {"object": "tree"}, true) == "Hit a tree",
		"a collision says what was hit")
	_expect(moments.describe("micro_slip", {}, true) == "", "the slips that happen all day are not listed")
	_expect(moments.describe("fall", {"severity": "TUMBLE"}, true) == "",
		"the risk system's jolt is not reported as a fall (the climber did not fall)")
	_expect(moments.describe("fall_from_slip", {}, true) == "Slipped and fell", "a real fall is")
	_expect(moments.describe("tension_shot", {}, false) == "" and moments.describe("cut", {}, false) == "",
		"the camera director's own decisions say nothing to the climber")
	_expect(moments.describe("something_new", {}, true) == "Something New",
		"an incident nobody wrote a line for is still listed")
	_expect(moments.describe("something_new", {}, false) == "", "a decision nobody wrote a line for is not")
	_expect(moments.describe("probe", {"hollow": false}, false) == ""
		and moments.describe("probe", {"hollow": true}, false) == "Probed a hidden crevasse",
		"probing is a moment only when it finds something")

	_expect(int(moments.kind_of("terminal_slide", true)) == int(kinds["FATAL"])
		and int(moments.kind_of("start_slide", false)) == int(kinds["SLIDE"])
		and int(moments.kind_of("deploy_rope", false)) == int(kinds["ROPE"])
		and int(moments.kind_of("whumpf", false)) == int(kinds["HAZARD"])
		and int(moments.kind_of("hard_landing", true)) == int(kinds["HURT"])
		and int(moments.kind_of("summit_reached", false)) == int(kinds["DECISION"]),
		"moments are sorted into kinds for the map's colours")

	_expect(moments.elapsed(1.25) == "1:15" and moments.elapsed(0.0) == "0:00" and moments.elapsed(0.999) == "1:00",
		"time into the run reads as hours and minutes")

	# A run's record, out of order and with noise in it
	var run: Object = (load("res://src/core/data/run_context.gd") as GDScript).new()
	var conditions: Object = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	conditions.time_of_day = 23.5
	run.start_conditions = conditions
	run.decisions.append({"type": "deploy_rope", "game_time": 0.75, "position": Vector3(3, 0, 0), "details": {}})
	run.decisions.append({"type": "start_slide", "game_time": 0.25, "position": Vector3(1, 0, 0), "details": {}})
	run.decisions.append({"type": "tension_shot", "game_time": 0.3, "position": Vector3.ZERO, "details": "a string"})
	run.incidents.append({"type": "micro_slip", "game_time": 0.1, "position": Vector3.ZERO, "details": {}})
	run.incidents.append({"type": "hard_landing", "game_time": 0.5, "position": Vector3(2, 0, 0), "details": {}})
	var listed: Array = moments.collect(run)
	var order: Array[String] = []
	for moment in listed:
		order.append(str(moment["type"]))
	_expect(order == ["start_slide", "hard_landing", "deploy_rope"],
		"a run's moments come out in the order they happened, without the noise (%s)" % ", ".join(order))
	_expect(listed.size() == 3 and listed[1]["is_incident"] and not listed[0]["is_incident"]
		and listed[2]["position"] == Vector3(3, 0, 0) and listed[1]["text"] == "Hard landing",
		"each with where it happened and its line")
	_expect(moments.clock(run, 0.25) == "23:45" and moments.clock(run, 0.75) == "00:15",
		"the time of day of a moment carries past midnight (%s, %s)" % [moments.clock(run, 0.25), moments.clock(run, 0.75)])
	_expect(moments.collect(null).is_empty(), "no run, no moments")


# =============================================================================
# THE LIFETIME RECORD
# =============================================================================

func _test_lifetime_record() -> void:
	var save: Object = _locator.get_service("SaveManager")
	_expect(is_instance_valid(save), "the save manager is up")
	if not is_instance_valid(save):
		return

	# Achievements used to be forgotten when the game closed
	var tracker_script: GDScript = load("res://src/systems/save/progression_tracker.gd") as GDScript
	var earned: Object = tracker_script.new()
	earned._unlock_achievement("first_descent")
	earned._add_skill_experience("route_reading", 250.0)
	var restored: Object = tracker_script.from_dict(JSON.parse_string(JSON.stringify(earned.to_dict())))
	_expect(restored.get_achievement("first_descent").is_unlocked and not restored.get_achievement("clean_descent").is_unlocked,
		"an achievement survives being written out and read back")
	_expect(restored.get_skill_level("route_reading") == earned.get_skill_level("route_reading")
		and earned.get_skill_level("route_reading") >= 1, "and so does a skill's level (%d)" % restored.get_skill_level("route_reading"))

	_expect(save.save_all(), "saving writes every part of the save")
	var written: Variant = JSON.parse_string(FileAccess.get_file_as_string(save.PROGRESSION_PATH)) \
		if FileAccess.file_exists(save.PROGRESSION_PATH) else null
	_expect(written is Dictionary and (written as Dictionary).has("achievements"),
		"including the achievements (%s)" % save.PROGRESSION_PATH)
	var before: int = save.get_progression().get_achievement_progress()["unlocked"]
	save.load_all()
	_expect(save.get_progression().get_achievement_progress()["unlocked"] == before,
		"and loading brings back as many as were saved (%d)" % before)

	# The main menu's Logbook
	var menu: Node = _main.get("main_menu")
	_expect(menu != null and menu.get("logbook_button") != null, "the main menu has a Logbook button")
	if menu == null or menu.get("logbook_button") == null:
		return
	(menu.get("logbook_button") as Button).pressed.emit()
	await _wait(5)
	var logbook: Control = _main.get("stats_display") as Control
	_expect(logbook != null and logbook.visible, "which opens the lifetime record")
	if logbook == null:
		return
	var found := true
	for panel_name in ["LifetimeStatistics", "RecentRuns", "Achievements"]:
		var panel: Node = logbook.find_child(panel_name, true, false)
		found = found and panel != null and panel.find_child("Content", true, false) != null \
			and panel.find_child("Content", true, false).get_child_count() > 2
	_expect(found, "with statistics, recent runs and achievements filled in")
	var close: Button = logbook.find_child("CloseButton", true, false) as Button
	_expect(close != null, "and a Close button")
	if close != null:
		close.pressed.emit()
	await _wait(2)
	_expect(not logbook.visible, "that closes it")


# =============================================================================
# SETTINGS
# =============================================================================

const TEST_SETTINGS := "user://settings_test_front_end.json"

func _bus_db(bus: String) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))


func _test_settings() -> void:
	var settings: Node = _locator.get_service("GameSettings") as Node
	_expect(settings != null, "the settings service is up")
	if settings == null:
		return
	# Whatever the person running this has set stays as it is on disk
	settings.persist = false
	settings.reset()
	await _wait(3)

	var defaults: Dictionary = settings.DEFAULTS
	var all_default := true
	for key in defaults.keys():
		all_default = all_default and settings.get_value(key) == defaults[key]
	_expect(all_default and defaults.size() >= 12, "a reset puts all %d settings at their defaults" % defaults.size())
	_expect(is_equal_approx(_bus_db("Master"), 0.0) and is_equal_approx(_bus_db("Ambient"), 0.0)
		and is_equal_approx(_bus_db("Player"), 0.0) and is_equal_approx(_bus_db("UI"), 0.0),
		"at the defaults nothing is turned down")

	# Sound levels reach the buses (half a slider is a quarter of the level)
	settings.set_value("volume_master", 0.5)
	settings.set_value("volume_ambient", 0.5)
	settings.set_value("volume_climber", 0.25)
	settings.set_value("volume_effects", 0.75)
	settings.set_value("volume_interface", 0.0)
	await _wait(3)
	_expect(absf(_bus_db("Master") + 12.04) < 0.1, "Everything at 50%% turns the Master bus down 12 dB (%.1f)" % _bus_db("Master"))
	_expect(absf(_bus_db("Ambient") + 12.04) < 0.1, "wind and weather at 50%% does the same to the Ambient bus (%.1f)" % _bus_db("Ambient"))
	_expect(absf(_bus_db("Player") + 24.08) < 0.1, "the climber at 25%% is 24 dB down (%.1f)" % _bus_db("Player"))
	_expect(absf(_bus_db("Effects") + 5.0) < 0.1, "movement and gear at 75%% is 5 dB down (%.1f)" % _bus_db("Effects"))
	_expect(_bus_db("UI") <= -79.9, "menus at 0%% are off (%.0f dB)" % _bus_db("UI"))
	var audio: Object = _locator.get_service("AudioService")
	audio.set_risk_dampen(1.0)
	await _wait(3)
	_expect(_bus_db("Ambient") < -12.5, "the mix still works on top of the player's level (Ambient %.1f dB on risky ground)" % _bus_db("Ambient"))
	audio.set_risk_dampen(0.0)

	# Display and camera
	settings.set_value("antialiasing", 0)
	settings.set_value("render_scale", 0.75)
	_expect(int(root.msaa_3d) == 0 and is_equal_approx(root.scaling_3d_scale, 0.75),
		"anti-aliasing and the 3D resolution reach the viewport")

	# Kept in range, and the wrong kind of value is refused
	settings.set_value("render_scale", 5.0)
	settings.set_value("mouse_sensitivity", -3.0)
	settings.set_value("antialiasing", 99)
	_expect(is_equal_approx(settings.get_value("render_scale"), 1.0) and is_equal_approx(settings.get_value("mouse_sensitivity"), 0.25)
		and settings.get_value("antialiasing") == 3, "numbers are kept inside their range")
	settings.set_value("invert_y", "yes")
	settings.set_value("camera_sway", "a lot")
	_expect(settings.get_value("invert_y") == false and is_equal_approx(settings.get_value("camera_sway"), 1.0),
		"a value of the wrong kind leaves the setting at its default")
	settings.set_value("no_such_setting", 1)
	_expect(settings.get_value("no_such_setting") == null, "a setting that does not exist is refused")

	# They survive a restart (into a file of the test's own)
	settings.settings_path = TEST_SETTINGS
	settings.persist = true
	settings.set_value("camera_sway", 0.3)
	settings.set_value("invert_y", true)
	_expect(settings.save_settings() and FileAccess.file_exists(TEST_SETTINGS), "settings are written to disk")
	var again: Node = (load("res://src/systems/settings/game_settings.gd") as GDScript).new()
	again.settings_path = TEST_SETTINGS
	again.load_settings()
	_expect(is_equal_approx(again.get_value("camera_sway"), 0.3) and again.get_value("invert_y") == true
		and is_equal_approx(again.get_value("volume_ambient"), 0.5) and again.get_value("antialiasing") == 3,
		"and read back as they were written")

	# A file from another version, or edited by hand
	var junk := FileAccess.open(TEST_SETTINGS, FileAccess.WRITE)
	junk.store_string('{"volume_master": "loud", "render_scale": 0.1, "antialiasing": 2.0, "fullscreen": 1, "bogus": 7}')
	junk.close()
	again.load_settings()
	_expect(is_equal_approx(again.get_value("volume_master"), 1.0) and is_equal_approx(again.get_value("render_scale"), 0.5)
		and again.get_value("antialiasing") == 2 and again.get_value("fullscreen") == true and again.get_value("bogus") == null,
		"a settings file with nonsense in it is read as far as it makes sense")
	junk = FileAccess.open(TEST_SETTINGS, FileAccess.WRITE)
	junk.store_string("not json at all {")
	junk.close()
	again.load_settings()
	_expect(is_equal_approx(again.get_value("volume_master"), 1.0), "and one that is not readable at all gives the defaults")
	again.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SETTINGS))
	settings.persist = false
	settings.settings_path = settings.SETTINGS_PATH
	settings.reset()

	# The screen
	var menu: Node = _main.get("main_menu")
	(menu.get("settings_button") as Button).pressed.emit()
	await _wait(3)
	var screen: Control = _main.get("settings_screen") as Control
	_expect(screen != null and screen.visible, "the main menu's Settings opens the settings screen")
	if screen == null:
		return
	var controls: Dictionary = screen.get("_controls")
	_expect(controls.size() == defaults.size(), "it has a control for every setting (%d of %d)" % [controls.size(), defaults.size()])
	var reset: Button = screen.get("reset_button")
	_expect(reset.disabled, "with nothing changed there is nothing to reset")
	(controls["volume_ambient"] as HSlider).value = 0.4
	await _wait(2)
	_expect(is_equal_approx(settings.get_value("volume_ambient"), 0.4), "moving a slider changes the setting")
	_expect(not reset.disabled and reset.text == "Reset sound to defaults", "and the page can now be reset (%s)" % reset.text)
	settings.set_value("volume_climber", 0.6)
	_expect(is_equal_approx((controls["volume_climber"] as HSlider).value, 0.6), "a setting changed elsewhere moves its slider")
	reset.pressed.emit()
	await _wait(2)
	_expect(is_equal_approx(settings.get_value("volume_ambient"), 1.0) and is_equal_approx(settings.get_value("volume_climber"), 1.0)
		and is_equal_approx((controls["volume_ambient"] as HSlider).value, 1.0), "Reset puts the page back")
	(controls["invert_y"] as CheckButton).button_pressed = true
	(controls["antialiasing"] as OptionButton).select(1)
	(controls["antialiasing"] as OptionButton).item_selected.emit(1)
	_expect(settings.get_value("invert_y") == true and settings.get_value("antialiasing") == 1,
		"switches and choices write their settings too")
	var keys: GridContainer = screen.find_child("Keys", true, false) as GridContainer
	var shown: Array[String] = []
	if keys != null:
		for label in keys.get_children():
			shown.append((label as Label).text)
	_expect("W" in shown and "Space" in shown and "Move forward" in shown, "the Controls page lists the keys (%d entries)" % (shown.size() / 2))
	(screen.get("back_button") as Button).pressed.emit()
	await _wait(2)
	_expect(not screen.visible, "Back closes the screen")
	settings.reset()


# =============================================================================
# ON THE MOUNTAIN
# =============================================================================

## The day's choices as data: each climb and weather window is a trade, and
## the conditions built from them say what the tables say
func _test_day_options() -> void:
	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var climbs: Array = conditions_script.CLIMBS
	var windows: Array = conditions_script.WEATHER_WINDOWS
	_expect(climbs.size() >= 3 and windows.size() >= 3, "there are climbs and weather windows to choose from (%d, %d)" % [climbs.size(), windows.size()])

	# No climb is simply better: the earlier on top, the more it cost
	var climbs_trade := true
	for i in range(1, climbs.size()):
		var earlier: Dictionary = climbs[i - 1]
		var later: Dictionary = climbs[i]
		if not (float(earlier["time_of_day"]) < float(later["time_of_day"]) \
				and float(earlier["fatigue"]) > float(later["fatigue"]) \
				and float(earlier["hydration"]) < float(later["hydration"])):
			climbs_trade = false
	_expect(climbs_trade, "every hour saved on the climb is paid for in fatigue and water")

	# A harder window is less settled and counts for more
	var windows_trade := true
	for i in range(1, windows.size()):
		var easier: Dictionary = windows[i - 1]
		var harder: Dictionary = windows[i]
		if not (float(easier["stability"]) > float(harder["stability"]) and float(easier["score"]) < float(harder["score"])):
			windows_trade = false
	_expect(windows_trade, "a less settled weather window counts for more in the logbook")
	_expect(is_equal_approx(float(windows[0]["score"]), 1.0), "a settled day is the yardstick (x%.2f)" % float(windows[0]["score"]))

	var day: Object = conditions_script.create_for_day("fast", "front")
	var fast: Dictionary = conditions_script.climb_option("fast")
	var front: Dictionary = conditions_script.weather_option("front")
	_expect(day.climb_id == "fast" and day.weather_id == "front", "a day remembers the climb and the window it was built from")
	_expect(is_equal_approx(day.time_of_day, float(fast["time_of_day"])) and is_equal_approx(day.body_state.fatigue, float(fast["fatigue"])) \
		and is_equal_approx(day.body_state.hydration, float(fast["hydration"])), "the climb sets the hour on top and the state of the body")
	_expect(is_equal_approx(day.daylight_remaining, day.calculate_sunset() - day.time_of_day),
		"daylight left runs from the hour on top to sunset (%.1f h)" % day.daylight_remaining)
	_expect(int(day.weather) == int(front["weather"]) and int(day.wind_strength) == int(front["wind"]) \
		and is_equal_approx(day.weather_stability, float(front["stability"])), "the window sets the sky, the wind and how settled it is")
	_expect(is_equal_approx(day.get_weather_score_factor(), float(front["score"])), "and what the day counts for (x%.2f)" % day.get_weather_score_factor())

	var unknown: Object = conditions_script.create_for_day("no such climb", "no such window")
	_expect(unknown.climb_id == conditions_script.DEFAULT_CLIMB and unknown.weather_id == conditions_script.DEFAULT_WEATHER,
		"an unknown choice falls back to the default day")
	var copy: Object = day.duplicate_conditions()
	_expect(copy.climb_id == "fast" and copy.weather_id == "front", "a copy of the conditions keeps the day")

	# A full route has the climb still to do
	day.apply_route_mode(int(_enums.RouteMode["FULL_ROUTE"]))
	_expect(day.climb_id == "" and is_equal_approx(day.time_of_day, 5.0) and day.body_state.fatigue < 0.1,
		"a full route leaves base camp rested at 05:00 whatever climb was picked")
	_expect(day.weather_id == "front", "and keeps its weather window")

	# Conditions built by hand (tests, tools) are no day in particular
	var plain: Object = conditions_script.create_moderate()
	_expect(plain.climb_id == "" and plain.weather_id == "" and is_equal_approx(plain.get_weather_score_factor(), 1.0),
		"conditions built by hand carry no day and no weather bonus")


const TEST_TIMER_DATA := "user://speedrun_data_test_front_end.json"

## The run timer's rules, on a mountain of the test's own and in a file of
## the test's own (nobody's real bests are touched): only a route brought
## home can be a best, kept per mountain and per way round it
func _test_run_timer_rules() -> void:
	var timer: Node = _locator.get_service("SpeedrunTimer") as Node
	_expect(timer != null, "the run timer service is up")
	if timer == null:
		return
	_expect(timer.format_clock(754.9) == "12:34" and timer.format_clock(3723.0) == "1:02:03" and timer.format_clock(-5.0) == "0:00",
		"times read as a clock (%s, %s)" % [timer.format_clock(754.9), timer.format_clock(3723.0)])

	# From here to the end of the test the timer keeps its bests in a file of
	# the test's own (the descents further down note splits and best segments)
	_real_timer_path = timer.data_path
	_real_timer_bests = timer.personal_bests.duplicate(true)
	_real_timer_golds = timer.gold_splits.duplicate(true)
	timer.data_path = TEST_TIMER_DATA
	timer.personal_bests = {}
	timer.gold_splits = {}
	var peak := "a_peak_of_the_tests_own"
	var outcomes: Dictionary = _enums.ResolutionType
	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var context_script: GDScript = load("res://src/core/data/run_context.gd") as GDScript
	# halfway: seconds on the clock at the halfway split (0: the run notes none)
	var finish := func(seconds: float, outcome: String, full: bool, halfway: float = 0.0) -> void:
		var conditions: Object = conditions_script.create_moderate()
		if full:
			conditions.apply_route_mode(int(_enums.RouteMode["FULL_ROUTE"]))
		var run: Object = context_script.create_new_run(peak, conditions)
		timer._on_run_started(run)
		if halfway > 0.0:
			timer.elapsed_time = halfway
			timer.record_split("down_50")
		run.real_time_elapsed = seconds
		timer._on_run_ended(run, int(outcomes[outcome]))

	_expect(timer.get_personal_best(peak, false) < 0.0, "a mountain never come home from has no fastest return")
	finish.call(95.0, "FATALITY", false)
	_expect(timer.get_personal_best(peak, false) < 0.0 and not timer.last_was_best, "dying quickly is not a fast return")
	finish.call(600.0, "CLEAN_RETURN", false)
	_expect(is_equal_approx(timer.get_personal_best(peak, false), 600.0) and timer.last_was_best, "the first route brought home is the fastest so far")
	finish.call(720.0, "INJURED_RETURN", false)
	_expect(is_equal_approx(timer.get_personal_best(peak, false), 600.0) and not timer.last_was_best and is_equal_approx(timer.last_time, 720.0),
		"a slower return leaves it standing")
	finish.call(200.0, "RESCUE", false)
	_expect(is_equal_approx(timer.get_personal_best(peak, false), 600.0), "being carried down is not a return")
	finish.call(540.0, "INJURED_RETURN", false)
	_expect(is_equal_approx(timer.get_personal_best(peak, false), 540.0) and timer.last_was_best, "a faster one, even hurt, replaces it")
	finish.call(1500.0, "CLEAN_RETURN", true)
	_expect(is_equal_approx(timer.get_personal_best(peak, true), 1500.0) and is_equal_approx(timer.get_personal_best(peak, false), 540.0),
		"the full route keeps a best of its own")

	# Splits: each is compared with the same split of the best run so far
	_expect(timer.format_delta(-14.2) == "-0:14" and timer.format_delta(65.0) == "+1:05", "a difference reads with its sign (%s, %s)" % [timer.format_delta(-14.2), timer.format_delta(65.0)])
	finish.call(500.0, "CLEAN_RETURN", false, 260.0)
	var first_splits: Array = timer.get_current_splits()
	_expect(first_splits.size() == 1 and first_splits[0].id == "down_50" and first_splits[0].name == "Halfway down" \
		and is_equal_approx(first_splits[0].time, 260.0) and not first_splits[0].has_comparison,
		"the first run to note a split has nothing to compare it with")
	_expect(timer.get_pb_splits(peak, false).size() == 1, "the best run keeps its splits")
	finish.call(520.0, "CLEAN_RETURN", false, 245.0)
	var later_splits: Array = timer.get_current_splits()
	_expect(later_splits.size() == 1 and later_splits[0].has_comparison and is_equal_approx(later_splits[0].comparison, -15.0) and later_splits[0].is_gold,
		"a later run is told how its split compares, and when a stretch was its fastest (%s)" % timer.format_delta(later_splits[0].comparison if later_splits.size() == 1 else 0.0))
	_expect(is_equal_approx(timer.get_personal_best(peak, false), 500.0) and is_equal_approx(float(timer.get_pb_splits(peak, false)[0]["time"]), 260.0),
		"a faster split in a slower run does not change the best run")
	var twice: Object = context_script.create_new_run(peak, conditions_script.create_moderate())
	timer._on_run_started(twice)
	timer.elapsed_time = 100.0
	timer.record_split("down_25")
	timer.elapsed_time = 130.0
	timer.record_split("down_25")
	_expect(timer.get_current_splits().size() == 1 and is_equal_approx(timer.get_current_splits()[0].time, 100.0), "a mark is noted once, the first time it is passed")
	timer._on_run_ended(twice, int(outcomes["FATALITY"]))

	# Kept on disk, in the test's own file; the old layout's entries are not read
	var kept_bests: Dictionary = timer.personal_bests.duplicate(true)
	timer.personal_bests = {"%s:ANY_PERCENT" % peak: {"final_time": 12.0}}
	_expect(timer.get_personal_best(peak, false) < 0.0, "a best filed the old way (any ended run counted) is not believed")
	timer.personal_bests = {}
	timer._load_data()
	_expect(is_equal_approx(timer.get_personal_best(peak, false), 500.0) and timer.personal_bests.size() == kept_bests.size(), "bests are read back from disk")
	timer.reset_timer()


## The worst weather (rung of WeatherService.WEATHER_LADDER) in the first
## hours of a generated day, averaged over many days drawn from fixed seeds
func _mean_worst_weather(weather: Node, option: Dictionary, volatility: float, hours: float = 6.0, days: int = 150) -> float:
	var total := 0.0
	for d in range(days):
		seed(4000 + d)
		weather.generate_weather_windows(10.0, int(option["weather"]), int(option["wind"]), float(option["stability"]), volatility, 0.5)
		var worst := 0
		var at := 0.0
		while at <= hours:
			for window in weather.weather_windows:
				if window.is_active(fposmod(10.0 + at, 24.0)):
					worst = maxi(worst, int(weather.weather_rung(window.weather)))
					break
			at += 0.25
		total += worst
	return total / days


## Choose the day on the planning screen the way a player does, confirm the
## plan, and check the mountain is the one that was chosen
func _plan_the_day_and_start() -> bool:
	var states: Dictionary = _enums.GameState
	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	if is_instance_valid(mountain_db):
		mountain_db.select_mountain(MOUNTAIN)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(10)

	var planning: Control = _main.get("planning_screen")
	_expect(planning != null and planning.visible, "the planning screen is up")
	if planning == null:
		return false
	var climb_picker: OptionButton = planning.get("climb_picker")
	var weather_picker: OptionButton = planning.get("weather_picker")
	_expect(climb_picker != null and weather_picker != null, "the plan has a picker for the climb and one for the weather")
	if climb_picker == null or weather_picker == null:
		return false
	_expect(climb_picker.item_count == conditions_script.CLIMBS.size() and weather_picker.item_count == conditions_script.WEATHER_WINDOWS.size(),
		"the pickers list every climb and every window (%d, %d)" % [climb_picker.item_count, weather_picker.item_count])
	_expect(planning.climb_id == conditions_script.DEFAULT_CLIMB and planning.weather_id == conditions_script.DEFAULT_WEATHER,
		"a first visit starts on the default day (%s, %s)" % [planning.climb_id, planning.weather_id])
	_expect(not climb_picker.disabled, "a descent chooses how the climb went")
	var day_label: Label = planning.route_info_panel.get_node_or_null("DayPlanLabel")
	var steady_plan := day_label.text if day_label != null else ""
	_expect(steady_plan.contains("Start 12:00"), "the day plan starts at noon after a steady climb (%s)" % steady_plan.replace("\n", " / "))

	# Pick the slow climb and the settled window, as the pickers do it
	var slow := -1
	for i in range(conditions_script.CLIMBS.size()):
		if conditions_script.CLIMBS[i]["id"] == "slow":
			slow = i
	var changes: Array = []
	planning.day_changed.connect(func(climb: String, window: String) -> void: changes.append([climb, window]))
	climb_picker.select(slow)
	climb_picker.item_selected.emit(slow)
	weather_picker.select(0)
	weather_picker.item_selected.emit(0)
	await _wait(2)
	_expect(planning.climb_id == "slow" and planning.weather_id == "settled", "picking changes the day (%s, %s)" % [planning.climb_id, planning.weather_id])
	_expect(changes.size() == 2 and changes[1] == ["slow", "settled"], "and the screen says so (%s)" % str(changes))
	var slow_plan := day_label.text if day_label != null else ""
	_expect(slow_plan.contains("Start 14:30") and slow_plan != steady_plan, "the day plan follows the climb (%s)" % slow_plan.replace("\n", " / "))
	var climb_note: Label = planning.get("climb_note")
	var weather_note: Label = planning.get("weather_note")
	_expect(climb_note != null and climb_note.text.contains("daylight"), "the climb's line says what it leaves of the day (%s)" % (climb_note.text if climb_note != null else ""))
	_expect(weather_note != null and weather_note.text.contains("Clear") and not weather_note.text.contains("logbook"),
		"a settled window promises no bonus (%s)" % (weather_note.text if weather_note != null else ""))
	planning.set_day("slow", "storm")
	_expect(weather_note != null and weather_note.text.contains("x1.30"), "a storm day says what it counts for (%s)" % (weather_note.text if weather_note != null else ""))
	_expect(weather_picker.selected == conditions_script.WEATHER_WINDOWS.size() - 1, "the picker follows a day set from code")
	planning.set_day("slow", "settled")

	# The day survives leaving the screen and coming back
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(2)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(10)
	_expect(planning.climb_id == "slow" and planning.weather_id == "settled" and climb_picker.selected == slow,
		"the chosen day is still there after a look at the pack")

	# Confirm: the run is that day
	var waited := 0
	while not planning.route_valid and waited < 600:
		await process_frame
		waited += 1
	_expect(planning.route_valid, "the direct line is a plan that can be confirmed")
	planning.confirm_button.pressed.emit()
	await _wait(30)
	if int(_state_manager.current_state) != int(states["DESCENT"]) \
			or not is_instance_valid(_locator.get_service("PlayerController")):
		return false
	var run: Object = _state_manager.current_run
	var chosen_climb: Dictionary = conditions_script.climb_option("slow")
	var chosen_window: Dictionary = conditions_script.weather_option("settled")
	_expect(run.start_conditions.climb_id == "slow" and run.start_conditions.weather_id == "settled", "the run carries the chosen day")
	_expect(is_equal_approx(run.start_conditions.time_of_day, float(chosen_climb["time_of_day"])), "it starts at the hour the climb put you on top")
	_expect(absf(run.body_state.fatigue - float(chosen_climb["fatigue"])) < 0.05 and absf(run.body_state.hydration - float(chosen_climb["hydration"])) < 0.05,
		"in the shape the climb left you (fatigue %.2f, water %.2f)" % [run.body_state.fatigue, run.body_state.hydration])
	_expect(run.start_conditions.avalanche != null, "with today's snowpack")
	var time: Node = _locator.get_service("TimeService") as Node
	_expect(time != null and absf(time.current_time - float(chosen_climb["time_of_day"])) < 0.2, "the clock on the mountain agrees (%.2f)" % (time.current_time if time != null else -1.0))

	# The mountain's weather is the window that was chosen, not a draw
	var weather: Node = _locator.get_service("WeatherService") as Node
	_expect(weather != null, "the weather service is up")
	if weather != null:
		_expect(int(weather.current_weather) == int(chosen_window["weather"]) and not weather.is_transitioning,
			"the descent starts in the weather chosen (%s)" % str(_enums.WeatherState.keys()[weather.current_weather]))
		_expect(int(weather.current_wind_strength) == int(chosen_window["wind"]), "and in its wind (%s)" % str(_enums.WindStrength.keys()[weather.current_wind_strength]))
		var windows: Array = weather.weather_windows
		_expect(windows.size() >= 12 and int(windows[0].weather) == int(chosen_window["weather"]) and int(windows[0].wind_strength) == int(chosen_window["wind"]),
			"the day's first window is that weather (%d windows)" % windows.size())
		var steps_ok := true
		var hours := 0.0
		for i in range(windows.size()):
			hours += fposmod(windows[i].end_time - windows[i].start_time, 24.0)
			if i > 0:
				if absi(int(weather.weather_rung(windows[i].weather)) - int(weather.weather_rung(windows[i - 1].weather))) > 1:
					steps_ok = false
				if absi(int(windows[i].wind_strength) - int(windows[i - 1].wind_strength)) > 1:
					steps_ok = false
		_expect(steps_ok, "weather and wind move a step at a time from window to window")
		_expect(absf(hours - 24.0) < 0.01, "the windows cover the day (%.2f h)" % hours)

		# How settled the day is decides how it goes, and the mountain bends it
		var means: Array[float] = []
		for option in conditions_script.WEATHER_WINDOWS:
			means.append(_mean_worst_weather(weather, option, 0.3))
		var ordered := true
		for i in range(1, means.size()):
			if means[i] <= means[i - 1] + 0.3:
				ordered = false
		_expect(ordered, "a less settled window turns out worse (worst weather in six hours, rungs: %s)" % str(means))
		_expect(means[0] < 1.0, "a settled day mostly stays clear or nearly (%.2f)" % means[0])
		var calm_mountain := _mean_worst_weather(weather, conditions_script.weather_option("changeable"), 0.1)
		var wild_mountain := _mean_worst_weather(weather, conditions_script.weather_option("changeable"), 0.9)
		_expect(wild_mountain > calm_mountain + 0.2, "the same window goes worse on a mountain whose weather turns fast (%.2f > %.2f)" % [wild_mountain, calm_mountain])
		var ladder: Array = weather.WEATHER_LADDER
		_expect(int(weather.step_weather(ladder[0], -1)) == int(ladder[0]) and int(weather.step_weather(ladder[ladder.size() - 1], 1)) == int(ladder[ladder.size() - 1]),
			"the weather cannot get better than clear or worse than a whiteout")
		_expect(int(weather.step_weather(int(_enums.WeatherState["STORM"]), -1)) == int(_enums.WeatherState["SNOW"]), "a storm eases to snowfall")
		# Put the day the run is on back
		seed(4000)
		weather.reset_for_run(int(chosen_window["weather"]))
		weather.generate_weather_windows(run.start_conditions.time_of_day, int(chosen_window["weather"]), int(chosen_window["wind"]), float(chosen_window["stability"]))
		randomize()
	_steady_the_mountain()
	return true


## The test says what happens from here; the mountain's own dice are put away
## (see _steady_the_mountain() in tests/test_audio.gd for why seed() is not
## enough)
func _steady_the_mountain() -> void:
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	player.posture.micro_slip_probability_scale = 0.0
	var weather: Node = _locator.get_service("WeatherService") as Node
	if weather != null:
		weather.base_change_probability = 0.0
		weather.weather_windows.clear()
	var avalanches: Object = _locator.get_service("AvalancheSystem")
	if is_instance_valid(avalanches):
		avalanches.active = false


# =============================================================================
# SAVE AND QUIT, CONTINUE
# =============================================================================

const TEST_SUSPEND := "user://suspended_run_test_front_end.dat"

## Set the run aside from the pause menu and pick it up again from the main
## menu. Returns false when the run did not come back (nothing to go on with).
func _test_save_and_continue() -> bool:
	var states: Dictionary = _enums.GameState
	var saves: Node = _locator.get_service("SaveManager") as Node
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var weather: Node = _locator.get_service("WeatherService") as Node
	var time: Node = _locator.get_service("TimeService") as Node
	var ropes: Node = _locator.get_service("RopeService") as Node
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	_expect(saves != null, "the save manager is up")
	if saves == null:
		return false
	# A file of the test's own: whoever runs this keeps their own saved run
	var real_path: String = saves.suspend_path
	saves.suspend_path = TEST_SUSPEND
	saves.clear_suspended_run()
	_expect(not saves.has_suspended_run(), "there is no run set aside to begin with")

	# --- a day with some history in it ---------------------------------------
	var run: Object = _state_manager.current_run
	Input.action_press("move_forward")
	await _seconds(4.0)
	Input.action_release("move_forward")
	await _seconds(0.5)
	run.body_state.fatigue = 0.37
	run.body_state.hydration = 0.61
	run.body_state.cold_exposure = 0.12
	var sprain: Resource = (load("res://src/core/data/injury.gd") as GDScript).new(
		int(_enums.InjuryType["SPRAIN"]), 0.3, int(_enums.BodyPart["LEFT_LEG"]), 14.6)
	run.body_state.add_injury(sprain)
	run.gear_state.damage_item(int(_enums.GearType["ROPE"]), 0.25)
	player.set_footwear(int(_enums.Footwear["BOOTS"]))
	_event_bus.record_incident("micro_slip", {"position": player.global_position, "slope": 12.0})
	var weathers: Dictionary = _enums.WeatherState
	var winds: Dictionary = _enums.WindStrength
	seed(77)
	weather.generate_weather_windows(time.current_time, int(weathers["CLOUDY"]), int(winds["MODERATE"]), 0.3, 0.3, 0.5)
	randomize()
	weather.wind_direction = Vector3(0.6, 0.0, -0.8)
	weather.target_wind_direction = weather.wind_direction
	await _seconds(0.5)

	# --- the run timer, for those who ask for it --------------------------------
	var settings: Object = _locator.get_service("GameSettings")
	var timer: Node = _locator.get_service("SpeedrunTimer") as Node
	var hud_now: Node = _main.get("descent_hud")
	var timer_caption: Label = hud_now.find_child("TimerCaption", true, false) if hud_now != null else null
	var timer_value: Label = hud_now.find_child("TimerValue", true, false) if hud_now != null else null
	_expect(settings != null and timer != null and timer_caption != null and timer_value != null, "the HUD has a place for the run timer")
	if timer_caption != null and timer_value != null and settings != null and timer != null:
		hud_now.refresh()
		_expect(not timer_caption.visible and not timer_value.visible, "which stays out of sight unless it is asked for")
		settings.set_value("show_timer", true)
		hud_now.refresh()
		var shown: String = timer_value.text
		_expect(timer_caption.visible and timer_value.visible and shown.begins_with(timer.format_clock(run.real_time_elapsed)),
			"asked for, it shows the time played so far (%s after %.1f s)" % [shown, run.real_time_elapsed])
		_expect(run.real_time_elapsed > 4.0 and absf(timer.get_elapsed_time() - run.real_time_elapsed) < 0.5,
			"and it is the run's own clock (%.1f s, run %.1f s)" % [timer.get_elapsed_time(), run.real_time_elapsed])

		# Splits: marks at shares of the height between the summit and base camp
		var split_caption: Label = hud_now.find_child("SplitCaption", true, false)
		var split_value: Label = hud_now.find_child("SplitValue", true, false)
		var heights: Object = _locator.get_service("TerrainService")
		var top: float = heights.start_position.y
		var bottom: float = heights.goal_position.y
		_expect(timer.get_current_splits().is_empty() and split_caption != null and not split_caption.visible,
			"near the summit no split has been noted and the HUD shows none")
		timer._check_marks(Vector3(0.0, top - 0.3 * (top - bottom), 0.0))
		var noted: Array = timer.get_current_splits()
		_expect(noted.size() == 1 and noted[0].id == "down_25" and absf(noted[0].time - run.real_time_elapsed) < 0.5,
			"a quarter of the way down is noted with the time on the clock")
		timer._check_marks(Vector3(0.0, top - 0.8 * (top - bottom), 0.0))
		timer._check_marks(Vector3(0.0, top - 0.1 * (top - bottom), 0.0))
		noted = timer.get_current_splits()
		_expect(noted.size() == 3 and noted[2].id == "down_75", "the marks are noted in order, once each, whatever comes after (%d)" % noted.size())
		hud_now.refresh()
		_expect(split_caption.visible and split_value != null and split_value.text.begins_with("75%"), "the HUD shows the last split (%s)" % (split_value.text if split_value != null else ""))
		_expect((run.get_meta("timer_splits", []) as Array).size() == 3, "and the run carries its splits")

	# --- when it can and cannot be saved -------------------------------------
	_expect(_main.get_suspend_block_reason() == "", "standing on the mountain, the run can be saved (%s)" % _main.get_suspend_block_reason())
	player.gear_action = &"crampons"
	_expect(_main.get_suspend_block_reason() != "", "not while crampons are going on")
	player.gear_action = &""
	ropes.rope_in_use = true
	_expect(_main.get_suspend_block_reason().contains("rope"), "not with the rope out (%s)" % _main.get_suspend_block_reason())
	ropes.rope_in_use = false
	var movement: Dictionary = _enums.PlayerMovementState
	var was_state: int = player.current_state
	player.current_state = int(movement["SLIDING"])
	_expect(_main.get_suspend_block_reason() != "", "not in a slide")
	player.current_state = was_state

	# --- closing the window on a descent keeps it, if nobody else's is there ----
	_main.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_expect(saves.has_suspended_run() and int(_state_manager.current_state) == int(states["DESCENT"]),
		"closing the window on a descent writes it for Continue")
	var kept: Dictionary = saves.load_suspended_run()
	_expect(str((kept.get("run", {}) as Dictionary).get("run_id", "")) == run.run_id, "and it is this run")
	var other_run: Dictionary = run.to_save()
	other_run["run_id"] = "a_run_set_aside_earlier"
	saves.save_suspended_run({"run": other_run})
	_expect(not _main.save_run_on_close() and str((saves.load_suspended_run()["run"] as Dictionary).get("run_id", "")) == "a_run_set_aside_earlier",
		"but never in place of a run already set aside")
	saves.clear_suspended_run()
	player.gear_action = &"crampons"
	_expect(not _main.save_run_on_close() and not saves.has_suspended_run(), "and not where Save and Quit would be refused")
	player.gear_action = &""

	# --- what is about to be saved --------------------------------------------
	_state_manager.toggle_pause()
	await _wait(10)
	_expect(int(_state_manager.current_state) == int(states["PAUSED"]), "the descent is paused")
	var pause_menu: Control = _main.get("pause_menu")
	var save_quit: Button = pause_menu.get("save_quit_button") if pause_menu != null else null
	_expect(save_quit != null and save_quit.is_visible_in_tree() and not save_quit.disabled, "the pause menu offers Save and Quit")
	if save_quit == null:
		saves.suspend_path = real_path
		return false
	var profile: Object = saves.get_profile()
	var runs_before: int = profile.total_runs
	var before := {
		"run_id": run.run_id,
		"position": player.global_position,
		"yaw": player.rotation.y,
		"clock": float(time.current_time),
		"elapsed": float(run.game_time_elapsed),
		"distance": float(run.distance_traveled),
		"path": run.path_history.size(),
		"first": run.path_history[0] if run.path_history.size() > 0 else Vector3.ZERO,
		"decisions": run.decisions.size(),
		"incidents": run.incidents.size(),
		"rope": float(run.gear_state.get_item(int(_enums.GearType["ROPE"])).condition_value),
		"items": run.gear_state.items.size(),
		"windows": weather.weather_windows.size(),
		"window_2": int(weather.weather_windows[2].weather),
		"planned": (run.get_meta("planned_route", PackedVector3Array()) as PackedVector3Array).size(),
		"avalanche_seed": int(run.start_conditions.avalanche.seed),
		"avalanche_headline": str(run.start_conditions.avalanche.headline),
		"start_elevation": float(run.start_elevation),
	}
	_expect(before["path"] > 3 and before["distance"] > 2.0, "the day has a record so far (%d samples, %.0f m)" % [before["path"], before["distance"]])

	# --- Save and Quit ----------------------------------------------------------
	var suspended: Array = []
	var on_suspended := func(set_aside: Object) -> void: suspended.append(set_aside)
	_event_bus.run_suspended.connect(on_suspended)
	var ended: Array = []
	var on_ended := func(_finished: Object, _outcome: int) -> void: ended.append(true)
	_event_bus.run_ended.connect(on_ended)
	save_quit.pressed.emit()
	await _wait(20)
	_event_bus.run_suspended.disconnect(on_suspended)
	_expect(int(_state_manager.current_state) == int(states["MAIN_MENU"]), "Save and Quit goes to the main menu")
	_expect(not paused, "and the game is no longer paused")
	_expect(_state_manager.current_run == null and suspended.size() == 1, "the run is set aside, not ended")
	_expect(ended.is_empty() and profile.total_runs == runs_before, "nothing is recorded: it has no outcome yet")
	_expect(FileAccess.file_exists(TEST_SUSPEND) and saves.has_suspended_run(), "the run is on disk")
	var menu: Control = _main.get("main_menu")
	var continue_button: Button = menu.get("continue_button") if menu != null else null
	_expect(menu != null and menu.visible and continue_button != null and continue_button.visible,
		"the main menu offers Continue")
	_expect(continue_button != null and continue_button.text.contains("Knife Edge"), "and says which mountain (%s)" % (continue_button.text if continue_button != null else ""))
	_expect(not player.visible and not (_main.get("world") as Node3D).visible, "the mountain is put away")

	# --- everything the save should put back is knocked out of place -----------
	weather.reset_for_run(int(weathers["CLEAR"]))
	weather.weather_windows.clear()
	weather._set_wind_strength(int(winds["CALM"]))
	time.current_time = 3.0
	mountain_db.select_mountain("north_face", true)

	# --- Continue ----------------------------------------------------------------
	continue_button.pressed.emit()
	await _wait(60)
	_event_bus.run_ended.disconnect(on_ended)
	if int(_state_manager.current_state) != int(states["DESCENT"]) or _state_manager.current_run == null:
		saves.suspend_path = real_path
		return false
	var back: Object = _state_manager.current_run
	_expect(back != run and back.run_id == before["run_id"], "Continue brings the same run back")
	_expect(back.mountain_id == MOUNTAIN and mountain_db.get_selected_mountain().id == MOUNTAIN, "on its mountain")
	var terrain: Object = _locator.get_service("TerrainService")
	_expect(terrain.current_mountain == MOUNTAIN, "with that mountain's terrain loaded")
	var moved: float = player.global_position.distance_to(before["position"])
	_expect(moved < 1.5, "the climber stands where they stood (%.2f m off)" % moved)
	_expect(absf(angle_difference(player.rotation.y, before["yaw"])) < 0.05, "facing the way they faced")
	_expect(player.visible and int(player.footwear) == int(_enums.Footwear["BOOTS"]), "with the same things on their feet")
	_expect(absf(time.current_time - before["clock"]) < 0.1, "the clock is where it was (%.2f, was %.2f)" % [time.current_time, before["clock"]])
	_expect(back.game_time_elapsed >= before["elapsed"] and back.game_time_elapsed < before["elapsed"] + 0.1,
		"the day's elapsed time carries on (%.3f h, was %.3f)" % [back.game_time_elapsed, before["elapsed"]])
	_expect(absf(back.body_state.fatigue - 0.37) < 0.03 and absf(back.body_state.hydration - 0.61) < 0.03 and absf(back.body_state.cold_exposure - 0.12) < 0.03,
		"the body is as it was (fatigue %.2f, water %.2f, cold %.2f)" % [back.body_state.fatigue, back.body_state.hydration, back.body_state.cold_exposure])
	_expect(back.body_state.injuries.size() == 1 and int(back.body_state.injuries[0].type) == int(_enums.InjuryType["SPRAIN"]) \
		and int(back.body_state.injuries[0].location) == int(_enums.BodyPart["LEFT_LEG"]) and absf(back.body_state.injuries[0].severity - 0.3) < 0.001,
		"the sprained leg is still sprained")
	_expect(player.body_state == back.body_state and player.gear_state == back.gear_state, "the climber carries the run's body and pack")
	var rope: Object = back.gear_state.get_item(int(_enums.GearType["ROPE"]))
	_expect(back.gear_state.items.size() == before["items"] and rope != null and absf(rope.condition_value - before["rope"]) < 0.001,
		"the pack is as it was, worn rope and all (%d items, rope %.2f)" % [back.gear_state.items.size(), rope.condition_value if rope != null else -1.0])
	_expect(int(weather.current_weather) == int(weathers["CLOUDY"]) and int(weather.current_wind_strength) == int(winds["MODERATE"]),
		"the weather is the weather that was (%s, %s)" % [weathers.keys()[weather.current_weather], winds.keys()[weather.current_wind_strength]])
	_expect(weather.weather_windows.size() == before["windows"] and int(weather.weather_windows[2].weather) == before["window_2"],
		"and the rest of its day is the same day (%d windows)" % weather.weather_windows.size())
	_expect(weather.wind_direction.distance_to(Vector3(0.6, 0.0, -0.8)) < 0.2, "the wind blows from where it blew")
	_expect(back.path_history.size() >= before["path"] and back.path_history[0].distance_to(before["first"]) < 0.01,
		"the path walked so far is kept (%d samples)" % back.path_history.size())
	_expect(back.path_timestamps.size() == back.path_history.size() and back.path_modes.size() == back.path_history.size(), "with its times and how each stretch was travelled")
	_expect(back.distance_traveled >= before["distance"] and back.distance_traveled < before["distance"] + 5.0,
		"and the distance (%.1f m, was %.1f)" % [back.distance_traveled, before["distance"]])
	_expect(back.decisions.size() == before["decisions"] and back.incidents.size() == before["incidents"],
		"the day's decisions and incidents are the ones made (%d, %d)" % [back.decisions.size(), back.incidents.size()])
	_expect((back.get_meta("planned_route", PackedVector3Array()) as PackedVector3Array).size() == before["planned"] and before["planned"] >= 2, "the planned line is still the plan")
	_expect(back.start_conditions.climb_id == "slow" and back.start_conditions.weather_id == "settled", "the day chosen at the hut is remembered")
	_expect(back.start_conditions.avalanche != null and int(back.start_conditions.avalanche.seed) == before["avalanche_seed"] \
		and str(back.start_conditions.avalanche.headline) == before["avalanche_headline"], "and it is the same day's snowpack")
	_expect(is_equal_approx(back.start_elevation, before["start_elevation"]), "progress is still measured from the summit")
	_expect(not FileAccess.file_exists(TEST_SUSPEND) and not saves.has_suspended_run(), "the save is used up: there is no going back to it")
	if timer != null:
		_expect(back.real_time_elapsed >= run.real_time_elapsed and absf(timer.get_elapsed_time() - back.real_time_elapsed) < 0.5,
			"the run timer goes on from where it was (%.1f s, was %.1f)" % [timer.get_elapsed_time(), run.real_time_elapsed])
		var kept_splits: Array = timer.get_current_splits()
		var before_splits: Array = run.get_meta("timer_splits", [])
		_expect(kept_splits.size() == 3 and before_splits.size() == 3 and is_equal_approx(kept_splits[0].time, float(before_splits[0]["time"])) \
			and kept_splits[2].id == "down_75", "with the splits it had already noted, at the times they were noted")
	var hud: Node = _main.get("descent_hud")
	_expect(hud != null and (_main.get("world") as Node3D).visible, "the mountain and the HUD are back")
	_expect(root.get_viewport().get_camera_3d() == player.camera_pivot.camera, "seen through the climber's own camera")

	# It plays on: the climber can walk, and the record grows
	Input.action_press("move_forward")
	await _seconds(2.0)
	Input.action_release("move_forward")
	_expect(player.global_position.distance_to(before["position"]) > 1.0 and back.path_history.size() > before["path"],
		"the descent carries on from there")

	# --- files that are not a run this version can read ------------------------
	var other := FileAccess.open(TEST_SUSPEND, FileAccess.WRITE)
	other.store_var({"version": 999, "run": back.to_save()}, false)
	other.close()
	_expect(not saves.has_suspended_run() and saves.load_suspended_run().is_empty(), "a save from another version is not read")
	var junk := FileAccess.open(TEST_SUSPEND, FileAccess.WRITE)
	junk.store_string("this is not a saved run at all")
	junk.close()
	_expect(not saves.has_suspended_run(), "nor is a file that is not a save")
	_expect(not saves.save_suspended_run({"nothing": true}) , "and something that is not a run is not written")
	saves.clear_suspended_run()

	# One place for a run set aside: the pause menu says when saving would
	# replace another, and the menu offers nothing it could not continue
	_expect(_main._suspend_replaces_note() == "", "with nothing set aside, saving replaces nothing")
	saves.save_suspended_run({"run": back.to_save()})
	_expect(_main._suspend_replaces_note().contains("Knife Edge"), "with a run set aside, the pause menu says saving replaces it (%s)" % _main._suspend_replaces_note())
	var elsewhere: Dictionary = back.to_save()
	elsewhere["mountain_id"] = "a_mountain_that_is_not_in_this_version"
	saves.save_suspended_run({"run": elsewhere})
	menu.refresh()
	_expect(not continue_button.visible, "a run on a mountain this version does not have is not offered")
	saves.clear_suspended_run()
	_expect(not FileAccess.file_exists(TEST_SUSPEND), "the test's own save file is gone")
	saves.suspend_path = real_path

	# A run with nothing in it comes back empty-handed rather than broken
	var context_script: GDScript = load("res://src/core/data/run_context.gd") as GDScript
	_expect(context_script.from_save({}) == null and context_script.from_save({"mountain_id": MOUNTAIN}) == null, "data that is not a run gives no run")
	var bare: Object = context_script.from_save({"mountain_id": MOUNTAIN, "start_conditions": {}})
	_expect(bare != null and bare.body_state != null and bare.gear_state != null and not bare.is_complete,
		"a run saved with almost nothing still has a body and a pack")

	# The dice go away again for what follows
	_steady_the_mountain()
	return true


# =============================================================================
# THE FILM CREW'S DRONE
# =============================================================================

func _test_drone() -> void:
	var drones: Node = _locator.get_service("DroneService") as Node
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	var weather: Node = _locator.get_service("WeatherService") as Node
	_expect(drones != null and drones.drone != null and drones.drone.is_active, "the film crew's drone is in the air for the descent")
	if drones == null or drones.drone == null:
		return
	var drone: Node3D = drones.drone
	var winds: Dictionary = _enums.WindStrength
	weather._set_wind_strength(int(winds["MODERATE"]))
	await _seconds(2.0)

	# It used to be created at the world's origin, kilometres under the
	# summit, and to spend the whole descent flying up toward the climber
	var apart := drone.global_position.distance_to(player.global_position)
	var clear: float = drone.global_position.y - terrain.get_height_at(drone.global_position)
	_expect(apart < 60.0, "it takes off beside the climber (%.0f m away)" % apart)
	_expect(clear > 1.5, "clear of the ground (%.1f m up)" % clear)
	var climber_camera: Camera3D = player.camera_pivot.camera
	_expect(root.get_viewport().get_camera_3d() == climber_camera and not drones.is_drone_view(),
		"the descent starts in the climber's own view")

	Input.action_press("move_forward")
	await _seconds(8.0)
	Input.action_release("move_forward")
	apart = drone.global_position.distance_to(player.global_position)
	_expect(apart < 60.0 and drone.controller.is_following, "it keeps station while the climber walks (%.0f m)" % apart)

	# Moved a long way at once (a new run, a test): flown back, not left behind
	# (short of base camp: arriving there would end the run)
	var away: Vector3 = terrain.goal_position + (terrain.start_position - terrain.goal_position).normalized() * 80.0
	away.y = terrain.get_height_at(away) + 0.3
	_expect(away.distance_to(player.global_position) > 300.0, "there is ground a long way from the summit")
	player.global_position = away
	player.velocity = Vector3.ZERO
	await _seconds(1.5)
	apart = drone.global_position.distance_to(player.global_position)
	_expect(apart < 60.0, "moved across the mountain, the climber has the drone with them again (%.0f m)" % apart)
	var top: Vector3 = terrain.start_position
	top.y = terrain.get_height_at(top) + 0.3
	player.global_position = top
	player.velocity = Vector3.ZERO
	await _seconds(1.5)

	# A storm throws it about but does not take it away
	weather._set_wind_strength(int(winds["SEVERE"]))
	await _seconds(8.0)
	apart = drone.global_position.distance_to(player.global_position)
	_expect(apart < 80.0, "in a severe wind it is still with the climber (%.0f m, wind %.0f m/s)" % [apart, weather.wind_speed])
	weather._set_wind_strength(int(winds["MODERATE"]))
	_expect(int(_state_manager.current_state) == int(_enums.GameState["DESCENT"]), "the descent is still on")

	# B: the screen shows the drone's camera, and back
	var hud: Node = _main.get("descent_hud")
	var tag: Control = hud.find_child("ViewTag", true, false) as Control if hud != null else null
	await _tap("drone_view")
	await _wait(2)
	_expect(drones.is_drone_view() and root.get_viewport().get_camera_3d() == drones.drone_camera,
		"B puts the drone's camera on the screen")
	_expect(tag != null and tag.visible, "and the HUD says whose camera it is")
	await _tap("drone_view")
	await _wait(2)
	_expect(not drones.is_drone_view() and root.get_viewport().get_camera_3d() == climber_camera and tag != null and not tag.visible,
		"B again gives the climber's own view back")

	# A fatal sequence is watched through the drone, in one take
	var phases: Dictionary = _enums.FatalPhase
	_event_bus.fatal_event_started.emit(int(phases["MOMENT_OF_ERROR"]))
	await _wait(3)
	_expect(drones.fatal_view and root.get_viewport().get_camera_3d() == drones.drone_camera,
		"a fatal event cuts to the drone's camera")
	await _tap("drone_view")
	await _wait(2)
	_expect(root.get_viewport().get_camera_3d() == drones.drone_camera, "which B does not cut away from")
	_expect(not drone.controller.is_following and drone.let_subject_go, "the drone stops keeping station on the climber")
	var run_panel: Control = hud.find_child("RunPanel", true, false) as Control
	_expect(run_panel != null and run_panel.modulate.a < 0.01 and tag.modulate.a < 0.01, "and the screen is cleared of text")
	var before: Vector3 = drone.global_position
	player.global_position += Vector3(0.0, -400.0, 0.0)
	await _seconds(2.0)
	_expect(drone.global_position.distance_to(before) < 40.0,
		"the drone does not follow the climber into the void (moved %.0f m as they dropped 400)" % drone.global_position.distance_to(before))

	# Sent somewhere over the climber, it goes to the side instead
	player.global_position = top
	player.velocity = Vector3.ZERO
	await _wait(2)
	drone.controller.set_target_position(player.global_position + Vector3(1.0, 30.0, 0.0), 0.5)
	var sent: Vector3 = drone.controller.target_position if drone.controller.pending_move.is_empty() else drone.controller.pending_move["position"]
	var aside := Vector2(sent.x - player.global_position.x, sent.z - player.global_position.z).length()
	_expect(aside > 20.0, "and is never sent to hover over them (%.0f m to the side at %.0f m up)" % [aside, sent.y - player.global_position.y])

	# The run ends the way a fatal one does, and the player goes home
	var timer: Node = _locator.get_service("SpeedrunTimer") as Node
	var best_before: float = timer.get_personal_best(MOUNTAIN, false) if timer != null else -1.0
	_event_bus.fatal_event_completed.emit()
	_state_manager.complete_run(int(_enums.ResolutionType["FATALITY"]), "test")
	await _wait(5)
	if timer != null:
		_expect(not timer.last_was_best and is_equal_approx(timer.get_personal_best(MOUNTAIN, false), best_before),
			"a run that ended on the mountain is nobody's fastest return")
	var resolution: Node = _main.get("resolution_screen")
	var played_shown := false
	if resolution != null:
		for label in resolution.stats_container.find_children("*", "Label", true, false):
			if (label as Label).text == "Played:":
				played_shown = true
	_expect(played_shown, "with the timer asked for, the resolution screen says how long was played")
	var splits_shown := 0
	if resolution != null:
		for label in resolution.stats_container.find_children("*", "Label", true, false):
			if (label as Label).text in ["Quarter way down:", "Halfway down:", "Three quarters down:"]:
				splits_shown += 1
	_expect(splits_shown == 3, "and the splits on the way (%d)" % splits_shown)
	var timer_settings: Object = _locator.get_service("GameSettings")
	if timer_settings != null:
		timer_settings.set_value("show_timer", false)
	_state_manager.transition_to(int(_enums.GameState["POST_GAME"]))
	await _wait(5)
	_state_manager.transition_to(int(_enums.GameState["MAIN_MENU"]))
	await _wait(5)
	_expect(int(_state_manager.current_state) == int(_enums.GameState["MAIN_MENU"]), "the run is over and the menu is up")
	_expect(not drones.is_drone_view() and not drones.fatal_view and not drone.let_subject_go,
		"back at the menu, the next run will start in the climber's own view")
	var menu: Control = _main.get("main_menu")
	var saves: Node = _locator.get_service("SaveManager") as Node
	if menu != null and saves != null and not saves.has_suspended_run():
		_expect(not (menu.get("continue_button") as Button).visible, "with no run set aside, the menu offers no Continue")


# =============================================================================
# HELPERS
# =============================================================================

func _seconds(seconds: float) -> void:
	for i in range(int(ceil(seconds * 60.0))):
		await physics_frame


## Press and release an action as an input event, the way a key arrives.
## Pushed into the viewport: without a window (headless) nothing delivers
## Input.parse_input_event() to the scene.
func _tap(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event)
	await physics_frame
	await physics_frame
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	root.push_input(release)


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame



func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_front_end] ok: %s" % what)
	else:
		print("[test_front_end] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	# The run timer goes back to the file and the bests of whoever runs this
	var timer: Node = _locator.get_service("SpeedrunTimer") as Node if _locator != null else null
	if timer != null and not _real_timer_path.is_empty():
		timer.data_path = _real_timer_path
		timer.personal_bests = _real_timer_bests
		timer.gold_splits = _real_timer_golds
		if FileAccess.file_exists(TEST_TIMER_DATA):
			DirAccess.remove_absolute(TEST_TIMER_DATA)
	if _failures.is_empty():
		print("[test_front_end] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_front_end] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
