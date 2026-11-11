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
## The test never writes to the settings of whoever runs it: it turns the
## settings service's saving off, and where it tests saving it points the
## service at a file of its own.
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time (see
## tests/smoke_goal.gd).

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _main: Node = null
var _failures: Array[String] = []
var _checks: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	if _state_manager == null or _enums == null or _locator == null:
		_finish("autoloads missing; run with --path <project root>")
		return

	_test_key_moments()

	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	await _wait(5)
	await _test_lifetime_record()
	await _test_settings()
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
# HELPERS
# =============================================================================

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
	if _failures.is_empty():
		print("[test_front_end] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_front_end] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
