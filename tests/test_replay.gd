extends SceneTree
## The replay on the mountain: a run just finished, watched again.
##
## Run from the project root:
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_replay.gd
## Exit code 0 on PASS, 1 on FAIL (prints "[test_replay] PASS" / "FAIL: ...").
##
## What it covers:
##   - the recording: on the run's own clock, with the climber, what was on
##     their feet and the film crew's drone camera in every frame
##   - a run that came home, watched again from the post-game screen: the
##     climber is where the recording says at every moment, the hour is the
##     hour of that moment, the replay can be paused, wound, sped up and
##     seen from three cameras, the day's moments and highlights can be
##     jumped to, and closing it puts the mountain, the sky and the climber
##     back and has changed nothing in the run
##   - highlights (SPEC-SHEET 17), on recordings made by hand: a glissade the
##     climber chose and stopped is one, and the axe at its end is not a close
##     call; a slip caught by the axe is; a short glissade, a tumble and a
##     slide nobody chose are not; the rope and the weather turning are;
##     getting home after trouble is; nothing near a fatal event is; each is
##     named for the place and what was done, in the order they happened
##   - a run that ended in a fatal event (SPEC-SHEET 11 and 17): normal speed
##     and one fixed camera, no winding into the fatal moments, which are
##     shown once as one continuous take with nothing on the screen, cannot
##     be paused or wound back, and are not shown a second time; no highlight
##     comes from the moments before control was lost
##   - a run that was set aside and continued is replayed whole
##   - a run that is over stays over: while its replay moves the climber about,
##     nothing takes them for a live one (no incident, no risk, no fatal
##     event, nothing added to the run's record); a run is watched for fatal
##     conditions from its first second, pausing does not wipe the time spent
##     dangerously cold, and a climber who got home that cold is not killed on
##     the summary screen
##
## The test keeps the run it sets aside, and the run timer's bests, in files
## of its own.
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time (see
## tests/smoke_goal.gd).

const MOUNTAIN := "knife_edge"
const TEST_SUSPEND := "user://suspended_run_test_replay.dat"
const TEST_TIMER_DATA := "user://speedrun_data_test_replay.json"

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _main: Node = null
var _failures: Array[String] = []
var _checks: int = 0
var _real_timer_path: String = ""
var _real_suspend_path: String = ""
## Things that must not happen to a run that is over, counted by name
var _stirred: Dictionary = {}


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
	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	await _wait(10)
	var settings: Object = _locator.get_service("GameSettings")
	if is_instance_valid(settings):
		settings.persist = false
	var timer: Node = _locator.get_service("SpeedrunTimer") as Node
	if timer != null:
		_real_timer_path = timer.data_path
		timer.data_path = TEST_TIMER_DATA
	var saves: Node = _locator.get_service("SaveManager") as Node
	if saves != null:
		_real_suspend_path = saves.suspend_path
		saves.suspend_path = TEST_SUSPEND
		saves.clear_suspended_run()

	# What a live climber sets off; a replayed one must not
	_event_bus.incident_recorded.connect(func(type: String, _context: Dictionary) -> void: _stir("incident " + type))
	_event_bus.decision_recorded.connect(func(type: String, _context: Dictionary) -> void: _stir("decision " + type))
	_event_bus.injury_occurred.connect(func(_injury: Object) -> void: _stir("injury"))
	_event_bus.fatal_event_started.connect(func(_phase: int) -> void: _stir("fatal event"))
	_event_bus.point_of_no_return_detected.connect(func() -> void: _stir("point of no return"))
	_event_bus.risk_level_changed.connect(func(_risk: float, _factors: Dictionary) -> void: _stir("risk level"))
	_event_bus.high_risk_zone_entered.connect(func(_kind: String, _severity: float) -> void: _stir("high risk zone"))
	_event_bus.slide_started.connect(func(_speed: float, _slope: float) -> void: _stir("slide"))
	_event_bus.player_movement_changed.connect(func(_old: int, _new: int) -> void: _stir("movement state"))
	_event_bus.player_position_updated.connect(func(_position: Vector3, _velocity: Vector3) -> void: _stir("position"))
	_event_bus.body_state_updated.connect(func(_body: Object) -> void: _stir("body state"))
	_event_bus.run_ended.connect(func(_run: Object, _outcome: int) -> void: _stir("run ended"))

	_test_highlight_rules()
	await _test_a_run_that_came_home()
	await _test_a_fatal_run()
	await _test_a_run_that_was_continued()
	await _test_a_run_that_is_over_stays_over()
	_finish("")


# =============================================================================
# WHAT IS A HIGHLIGHT
# =============================================================================

## The rules, on recordings made by hand: 200 seconds straight down a
## mountain 1000 m high, so that every place name is known.
func _test_highlight_rules() -> void:
	var chosen := {"type": "slide_initiated", "context": {"cause": "glissade", "uncontrolled": false}}
	var slipped := {"type": "slide_initiated", "context": {"cause": "slip", "uncontrolled": true}}
	var arrested := {"type": "self_arrest_success", "context": {}}
	var home := [200, "run_ended", {"outcome": "CLEAN_RETURN"}]

	# A glissade the climber sat down to and stopped with the axe
	var glissade := [
		[40, "decision", chosen], [40, "slide_started", {"speed": 1.5, "slope": 32.0}],
		[52, "incident", arrested], [52, "slide_ended", {"outcome": "CLEAN_STOP", "speed": 0.2}],
	]
	var found: Array = _highlights(glissade + [home])
	_expect(_titles(found) == ["Upper Face - Glissade"], "a long glissade stopped under control is a highlight, and only that %s" % [_titles(found)])
	_expect(found.size() == 1 and found[0].start_time <= 40.0 and found[0].end_time >= 52.0, "the whole of it, with a little before and after")

	found = _highlights([
		[40, "decision", chosen], [40, "slide_started", {}], [42, "incident", arrested], [42, "slide_ended", {"outcome": "CLEAN_STOP"}], home])
	_expect(found.is_empty(), "a glissade of two seconds is not %s" % [_titles(found)])

	found = _highlights([
		[40, "decision", chosen], [40, "slide_started", {}], [52, "slide_ended", {"outcome": "TUMBLE_STOP"}], home])
	_expect(_titles(found) == ["Run-Out - Safe Return"], "one that ended in a tumble is not; getting home after it is %s" % [_titles(found)])

	# A slip into a slide, caught with the axe
	found = _highlights([
		[100, "incident", {"type": "slide_from_slip", "context": {}}], [100, "decision", slipped], [100, "slide_started", {}],
		[106, "incident", arrested], [106, "slide_ended", {"outcome": "CLEAN_STOP"}], home])
	_expect(_titles(found) == ["Middle Slopes - Self-Arrest", "Run-Out - Safe Return"], "a slip caught with the axe is a highlight, and so is getting home after it %s" % [_titles(found)])
	_expect(found.size() == 2 and found[0].start_time <= 100.0 and found[0].end_time >= 106.0, "from the slip to the stop")

	found = _highlights([
		[100, "decision", slipped], [100, "slide_started", {}], [112, "slide_ended", {"outcome": "TERRAIN_CATCH"}], home])
	_expect(_titles(found) == ["Run-Out - Safe Return"], "a slide nobody chose is not, however it ended %s" % [_titles(found)])

	# The rope and the weather
	found = _highlights([
		[20, "rope_deployed", {"quality": "GOOD"}],
		[90, "weather_changed", {"from": "CLEAR", "to": "PARTLY_CLOUDY"}],
		[150, "weather_changed", {"from": "CLOUDY", "to": "STORM"}],
		[175, "weather_changed", {"from": "STORM", "to": "CLEARING"}], home])
	_expect(_titles(found) == ["Summit Slopes - Abseil", "Lower Slopes - Weather Turn", "Lower Slopes - Sky Clearing"],
		"the rope going out, the weather turning and the sky clearing are; a few clouds are not %s" % [_titles(found)])

	# Two things at once are one highlight
	found = _highlights([[60, "rope_deployed", {}], [63, "weather_changed", {"from": "CLOUDY", "to": "STORM"}], home])
	_expect(found.size() == 1 and found[0].start_time <= 56.5 and found[0].end_time >= 66.5, "two things at once are one highlight, covering both %s" % [_titles(found)])

	# A day that ended in a fatal event
	found = _highlights(glissade + [
		[185, "decision", slipped], [185, "slide_started", {}], [188, "incident", arrested], [188, "slide_ended", {"outcome": "CLEAN_STOP"}],
		[189, "weather_changed", {"from": "CLOUDY", "to": "STORM"}],
		[192, "fatal_event", {"phase": "MOMENT_OF_ERROR"}], [200, "run_ended", {"outcome": "FATALITY"}]], "FATALITY")
	_expect(_titles(found) == ["Upper Face - Glissade"], "on a day that ended in a fatal event, nothing from its last moments is a highlight %s" % [_titles(found)])
	var early := true
	for highlight in found:
		if highlight.end_time > 184.0:
			early = false
	_expect(early, "and no highlight runs into them")

	# When control was lost, by the recording's own account
	var abandoned: String = (load("res://src/core/data/run_context.gd") as Script).CAUSE_ABANDONED
	var late_turn := [185, "weather_changed", {"from": "CLOUDY", "to": "STORM"}]
	var fell_off := glissade + [late_turn, [200, "run_ended", {"outcome": "FATALITY", "cause": "Fell from the mountain"}]]
	var gave_up := glissade + [late_turn, [200, "run_ended", {"outcome": "FATALITY", "cause": abandoned}]]
	_expect(is_equal_approx(_recording(glissade + [[192, "fatal_event", {}]], "FATALITY").loss_time(), 192.0), "control was lost where the fatal event began")
	_expect(is_equal_approx(_recording(fell_off, "FATALITY").loss_time(), 190.0),
		"a fatality with no fatal event recorded lost it a little before the end (%.0f s)" % _recording(fell_off, "FATALITY").loss_time())
	_expect(_titles(_highlights(fell_off, "FATALITY")) == ["Upper Face - Glissade"], "and nothing from then is a highlight %s" % [_titles(_highlights(fell_off, "FATALITY"))])
	_expect(not is_finite(_recording(gave_up, "FATALITY").loss_time()) and not is_finite(_recording(glissade + [home]).loss_time()),
		"a run that came home, or was given up, lost it nowhere")
	_expect(_titles(_highlights(gave_up, "FATALITY")) == ["Upper Face - Glissade", "Run-Out - Weather Turn"], "(a run given up keeps its last highlight %s)" % [_titles(_highlights(gave_up, "FATALITY"))])

	# No title names the danger
	var all_titles: Array = []
	for events in [glissade + [home], [[100, "decision", slipped], [106, "incident", arrested], home],
			[[150, "weather_changed", {"from": "CLOUDY", "to": "STORM"}], [20, "rope_deployed", {}], home]]:
		all_titles.append_array(_titles(_highlights(events)))
	var gentle := not all_titles.is_empty()
	for title in all_titles:
		for word in ["death", "dead", "died", "fatal", "kill", "fall", "brutal", "crash"]:
			if str(title).to_lower().contains(word):
				gentle = false
	_expect(gentle, "every title names a place and what was done, never the danger %s" % [all_titles])


## The highlights of a recording made by hand
func _highlights(events: Array, outcome: String = "CLEAN_RETURN") -> Array:
	var generator: Node = _locator.get_service("HighlightGenerator") as Node
	return generator.generate_highlights(_recording(events, outcome), 1000.0, 0.0).duplicate()


## A recording made by hand: 200 s straight down from 1000 m to 0, with these
## events ([seconds, type, data]) and this outcome
func _recording(events: Array, outcome: String = "CLEAN_RETURN") -> Object:
	var script: Script = (_locator.get_service("RecordingService") as Node).get_script()
	var recording: Object = script.RecordingData.new()
	recording.outcome = int(_enums.ResolutionType[outcome])
	for second in range(201):
		var frame: Object = script.RecordedFrame.new()
		frame.timestamp = float(second)
		frame.player_position = Vector3(0.0, 1000.0 - 5.0 * second, 0.0)
		recording.frames.append(frame)
	for entry in events:
		var event: Object = script.RecordedEvent.new()
		event.timestamp = float(entry[0])
		event.event_type = str(entry[1])
		event.data = entry[2]
		recording.events.append(event)
	recording.end_time = 200.0
	return recording


func _titles(highlights: Array) -> Array:
	var titles: Array = []
	for highlight in highlights:
		titles.append(highlight.title)
	return titles


# =============================================================================
# A RUN THAT CAME HOME
# =============================================================================

func _test_a_run_that_came_home() -> void:
	var states: Dictionary = _enums.GameState
	if not await _start_descent():
		_finish("could not start a descent")
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var run: Object = _state_manager.current_run
	# (The fatality detector is made after a session's first run has entered
	# DESCENT, and used to follow the game's state: that run went unwatched
	# until its first pause.)
	await _seconds(0.5)
	_expect(bool((_locator.get_service("FatalityDetector") as Node).is_active), "a session's first run is watched for fatal conditions from the start")

	# A short day with something in it: a walk, the weather turning, a slip caught
	# (the two events far enough apart to be two highlights, not one)
	Input.action_press("move_forward")
	await _seconds(5.0)
	_event_bus.weather_changed.emit(int(_enums.WeatherState["CLOUDY"]), int(_enums.WeatherState["STORM"]))
	await _seconds(16.0)
	_event_bus.record_decision("slide_initiated", {"position": player.global_position, "cause": "slip", "uncontrolled": true})
	_event_bus.record_incident("self_arrest_success", {"position": player.global_position, "speed": 4.0})
	await _seconds(5.0)
	player.set_footwear(int(_enums.Footwear["BOOTS"]))
	await _seconds(3.0)
	Input.action_release("move_forward")
	await _seconds(0.5)
	var walked_to: Vector3 = player.global_position
	var played: float = run.real_time_elapsed

	# --- the recording ----------------------------------------------------------
	var recorder: Node = _locator.get_service("RecordingService") as Node
	var recording: Object = recorder.get_current_recording()
	_expect(recording != null and recording.run_id == run.run_id and recording.frames.size() > 200,
		"the descent is being recorded (%d frames)" % (recording.frames.size() if recording != null else 0))
	if recording == null or recording.frames.size() < 10:
		return
	var frames: Array = recording.frames
	var last: Object = frames[frames.size() - 1]
	_expect(frames[0].timestamp < 1.0 and absf(last.timestamp - played) < 0.2, "on the run's own clock (%.2f s to %.2f s; the run is at %.2f)" % [frames[0].timestamp, last.timestamp, played])
	var in_order := true
	for i in range(1, frames.size()):
		if frames[i].timestamp <= frames[i - 1].timestamp:
			in_order = false
	_expect(in_order, "its frames are in order, one to a moment")
	# (The state changes a moment before the climber is placed: a frame taken
	# then put the start of every replay at the map's origin.)
	var began: Vector3 = (_locator.get_service("TerrainService") as Object).start_position
	_expect(frames[0].player_position.distance_to(began) < 2.0,
		"and it begins where the run began (%.2f m from the start)" % frames[0].player_position.distance_to(began))
	_expect(last.player_position.distance_to(walked_to) < 0.6 and int(last.footwear) == int(_enums.Footwear["BOOTS"]) and int(frames[0].footwear) == int(_enums.Footwear["CRAMPONS"]),
		"each frame has where the climber was and what was on their feet")
	_expect(last.camera_fov > 10.0 and last.camera_position.distance_to(last.player_position) > 3.0 and last.camera_position.distance_to(last.player_position) < 120.0,
		"and where the film crew's drone was looking from (%.0f m off, lens %.0f)" % [last.camera_position.distance_to(last.player_position), last.camera_fov])
	_state_manager.toggle_pause()
	await _wait(20)
	var frames_paused: int = recording.frames.size()
	await _wait(20)
	_expect(recording.frames.size() == frames_paused, "nothing is recorded while the game is paused")
	_state_manager.toggle_pause()
	await _wait(5)
	# Nor while the climber is not out on the mountain: the state changes a
	# moment before Main places them, and until then they are hidden (where
	# the last run left them) or not there at all
	player.visible = false
	var frames_hidden: int = recording.frames.size()
	await _seconds(0.5)
	_expect(recording.frames.size() == frames_hidden, "nor before the climber is out on the mountain")
	player.visible = true
	await _wait(5)
	var compact: Dictionary = recording.to_save()
	var again: Object = recording.get_script().from_save(compact)
	_expect(again != null and again.frames.size() == recording.frames.size() and again.events.size() == recording.events.size()
		and again.frames[20].player_position.distance_to(frames[20].player_position) < 0.001 and is_equal_approx(again.frames[20].timestamp, frames[20].timestamp),
		"a recording survives being packed for a save file and unpacked")

	# --- home, and to the day's summary ------------------------------------------
	var terrain: Object = _locator.get_service("TerrainService")
	player.global_position = terrain.goal_position + Vector3(0, 1, 0)
	await _wait(40)
	_expect(int(_state_manager.current_state) == int(states["RESOLUTION"]), "the run comes home")
	_state_manager.transition_to(int(states["POST_GAME"]))
	await _wait(10)
	var post_game: Control = _main.get("post_game_screen")
	var watch: Button = post_game.get("watch_button") if post_game != null else null
	_expect(watch != null and watch.is_visible_in_tree() and not watch.disabled, "the summary offers to watch the run again")
	if watch == null:
		return
	var path_before: int = run.path_history.size()
	var distance_before: float = run.distance_traveled
	var time: Node = _locator.get_service("TimeService") as Node
	var weather: Node = _locator.get_service("WeatherService") as Node
	var clock_before: float = time.current_time
	var weather_before: int = int(weather.current_weather)
	var player_before: Transform3D = player.global_transform
	var camera_before: Camera3D = root.get_viewport().get_camera_3d()
	var record_before: Array = [run.incidents.size(), run.decisions.size()]
	var body_before: Dictionary = run.body_state.to_save()
	var mountain_before: int = (_main.call("_capture_mountain") as Dictionary).hash()

	# --- watching it ----------------------------------------------------------------
	_stirred.clear()
	watch.pressed.emit()
	await _wait(5)
	var screen: Control = _main.get("replay_screen")
	var stage: Node3D = _main.get("replay_stage")
	var replays: Node = _locator.get_service("ReplayPlayer") as Node
	_expect(screen != null and screen.visible and not post_game.visible and stage != null and stage.is_open, "Watch it again opens the replay on the mountain")
	if screen == null or stage == null or not stage.is_open:
		return
	_expect(root.get_viewport().get_camera_3d() == stage.camera and (_main.get("world") as Node3D).visible, "seen through the replay's own camera")
	_expect(player.process_mode == Node.PROCESS_MODE_DISABLED and (player.get_node("AnimationController") as Node).process_mode == Node.PROCESS_MODE_ALWAYS,
		"the climber is a puppet: nothing is simulated, only the limbs move")
	_expect(replays.is_playing() and not replays.is_fatal_run and replays.can_change_speed() and replays.can_change_camera() and replays.can_seek(),
		"a run that came home can be wound, sped up and seen from any camera")
	_expect(absf(replays.get_duration() - (run.real_time_elapsed - frames[0].timestamp)) < 0.5, "it is as long as the run was (%.1f s)" % replays.get_duration())

	# The climber is where the recording says, at the hour it says
	replays.pause()
	var probe_at: float = frames[150].timestamp
	replays.seek(probe_at)
	await _wait(2)
	_expect(player.global_position.distance_to(frames[150].player_position) < 0.05, "wound to a moment, the climber stands where they stood then (%.2f m off)" % player.global_position.distance_to(frames[150].player_position))
	_expect(absf(angle_difference(player.rotation.y, frames[150].player_rotation)) < 0.05, "facing the way they faced")
	var hour: float = run.start_conditions.time_of_day + probe_at * 10.0 / 3600.0
	_expect(absf(time.current_time - hour) < 0.01, "at the hour it was (%.3f)" % time.current_time)
	_expect(int(player.footwear) == int(frames[150].footwear), "with what they had on their feet")
	replays.seek(last.timestamp - 1.0)
	await _wait(2)
	_expect(int(player.footwear) == int(_enums.Footwear["BOOTS"]), "and later in the day, in the boots they changed into")
	# Shown a moment at the far end of the mountain, the camera is there at
	# once (not gliding across, through whatever is in between)
	var far: Object = recorder.get_script().RecordedFrame.new()
	far.timestamp = frames[150].timestamp
	far.player_position = terrain.goal_position + Vector3(0.0, 0.1, 0.0)
	stage.show_frame(far, far, 0.0)
	await _wait(2)
	_expect(player.global_position.distance_to(far.player_position) < 0.05 and stage.camera.global_position.distance_to(player.global_position) < 12.0,
		"wound to the far end of the mountain, the camera goes with the climber (%.1f m off)" % stage.camera.global_position.distance_to(player.global_position))

	# Playing: the clock runs at the speed asked for, and the climber with it
	replays.seek(frames[30].timestamp)
	replays.set_speed(1.0)
	replays.play()
	var from_time: float = replays.current_timestamp
	await _seconds(1.0)
	var at_one: float = replays.current_timestamp - from_time
	replays.cycle_speed()
	_expect(is_equal_approx(replays.playback_speed, 2.0), "the speed button goes to the next speed (%.1fx)" % replays.playback_speed)
	from_time = replays.current_timestamp
	await _seconds(1.0)
	var at_two: float = replays.current_timestamp - from_time
	_expect(at_one > 0.5 and at_two > at_one * 1.6 and at_two < at_one * 2.4, "at twice the speed the day goes by twice as fast (%.2f s, then %.2f s, in a second)" % [at_one, at_two])
	var shown_at: float = replays.current_timestamp
	var nearest: Object = frames[0]
	for frame in frames:
		if absf(frame.timestamp - shown_at) < absf(nearest.timestamp - shown_at):
			nearest = frame
	_expect(player.global_position.distance_to(nearest.player_position) < 0.6, "while it plays the climber follows the recording (%.2f m off)" % player.global_position.distance_to(nearest.player_position))
	replays.pause()
	_expect(not replays.is_playing(), "it can be paused")
	replays.set_speed(1.0)

	# Three cameras
	var modes: Dictionary = stage.CameraMode
	replays.set_camera_mode(int(modes["CHASE"]))
	await _wait(3)
	var behind: float = stage.camera.global_position.distance_to(player.global_position)
	_expect(behind > 3.0 and behind < 12.0, "one camera is behind the climber (%.1f m)" % behind)
	replays.cycle_camera()
	await _wait(3)
	_expect(int(stage.mode) == int(modes["DRONE"]) and stage.has_drone_view() and stage.camera.global_position.distance_to(nearest.camera_position) < 3.0,
		"one is the film crew's drone, where it flew on the day (%.1f m from its recorded place)" % stage.camera.global_position.distance_to(nearest.camera_position))
	replays.cycle_camera()
	await _wait(3)
	var across: float = stage.camera.global_position.distance_to(player.global_position)
	_expect(int(stage.mode) == int(modes["WIDE"]) and across > 25.0, "and one looks on from across the slope (%.0f m)" % across)
	var ground: float = terrain.get_height_at(stage.camera.global_position)
	_expect(stage.camera.global_position.y > ground + 1.0, "no camera is in the ground")
	replays.cycle_camera()
	_expect(int(stage.mode) == int(modes["CHASE"]), "and round again")
	var camera_button: Button = screen.get("camera_button")
	_expect(camera_button.visible and camera_button.text == "Behind the climber", "the screen says which camera it is (%s)" % camera_button.text)

	# Moments and highlights
	var entries: Array = screen.get("_entries")
	var titles: Array[String] = []
	var highlight_times: Array[float] = []
	for entry in entries:
		if entry[2]:
			titles.append(str(entry[1]))
			highlight_times.append(float(entry[0]))
	_expect(titles.size() == 2, "the day's highlights are listed (%s)" % str(titles))
	var named_well := titles.size() == 2
	for title in titles:
		if not (title.contains(" - ") and (title.contains("Weather Turn") or title.contains("Self-Arrest"))) or title.to_lower().contains("fall") or title.to_lower().contains("death"):
			named_well = false
	_expect(named_well, "each named for the place and what was done")
	_expect(highlight_times.size() == 2 and highlight_times[0] < highlight_times[1], "in the order they happened")
	if highlight_times.size() == 2:
		var list_box: VBoxContainer = screen.get("list_box")
		var first_highlight: Button = null
		for child in list_box.get_children():
			if child is Button and first_highlight == null and (child as Button).text.contains(" - "):
				first_highlight = child
		_expect(first_highlight != null, "and each is a button")
		if first_highlight != null:
			first_highlight.pressed.emit()
			await _wait(2)
			_expect(replays.is_playing() and absf(replays.current_timestamp - highlight_times[0]) < 0.5, "pressing one plays it from its start (%.1f s)" % replays.current_timestamp)
			var guard := 0
			while replays.is_playing() and guard < 60 * 40:
				await physics_frame
				guard += 1
			_expect(not replays.is_playing() and replays.current_timestamp < highlight_times[1], "and stops at its end (%.1f s)" % replays.current_timestamp)

	# The timeline winds it by hand
	var timeline: HSlider = screen.get("timeline")
	timeline.value = frames[60].timestamp
	await _wait(2)
	_expect(absf(replays.current_timestamp - frames[60].timestamp) < 0.1 and player.global_position.distance_to(frames[60].player_position) < 0.3,
		"dragging the timeline winds the replay")
	# Taken hold of while playing, the timeline stops the replay; let go, it goes on
	replays.play()
	timeline.drag_started.emit()
	_expect(not replays.is_playing(), "while the timeline is held the replay stands still")
	timeline.value = frames[90].timestamp
	timeline.drag_ended.emit(true)
	await _wait(2)
	_expect(replays.is_playing() and replays.current_timestamp >= frames[90].timestamp - 0.1 and replays.current_timestamp < frames[90].timestamp + 1.0,
		"and goes on from where it is let go")
	replays.pause()

	# To the end
	var completed: Array = []
	var on_completed := func() -> void: completed.append(true)
	replays.playback_completed.connect(on_completed)
	replays.seek(replays.get_end() - 0.6)
	replays.play()
	await _seconds(1.5)
	replays.playback_completed.disconnect(on_completed)
	_expect(completed.size() == 1 and not replays.is_playing() and absf(replays.current_timestamp - replays.get_end()) < 0.05, "it stops at the end of the run")
	replays.play()
	await _wait(2)
	_expect(replays.is_playing() and replays.current_timestamp < frames[0].timestamp + 1.0, "and Play from there starts it again")

	# --- on a gamepad: A on the button in focus, B to leave ---------------------
	_expect(root.gui_get_focus_owner() == screen.get("play_button"), "the Play button has the focus")
	await _press_pad(JOY_BUTTON_A)
	_expect(not replays.is_playing(), "A on a gamepad presses it")
	_expect((player.get_node("SurfaceEffects") as Node).process_mode == Node.PROCESS_MODE_ALWAYS, "(the snow a slide throws up is awake for the replay)")

	# --- closing it puts everything back -----------------------------------------
	await _press_pad(JOY_BUTTON_B)
	await _wait(5)
	_expect(not screen.visible and post_game.visible and not stage.is_open, "B (or Close) goes back to the summary")
	_expect(player.global_transform.origin.distance_to(player_before.origin) < 0.01 and player.process_mode == Node.PROCESS_MODE_DISABLED
		and (player.get_node("AnimationController") as Node).process_mode == Node.PROCESS_MODE_INHERIT
		and (player.get_node("SurfaceEffects") as Node).process_mode == Node.PROCESS_MODE_INHERIT, "the climber is back where the run ended")
	_expect(absf(time.current_time - clock_before) < 0.05 and not time.is_paused and int(weather.current_weather) == weather_before and weather.is_processing(),
		"the hour and the weather are the present's again (%.2f, was %.2f)" % [time.current_time, clock_before])
	_expect(root.get_viewport().get_camera_3d() == camera_before, "and so is the camera")
	_expect(run.path_history.size() == path_before and is_equal_approx(run.distance_traveled, distance_before), "watching changed nothing in the run")
	_expect(run.incidents.size() == record_before[0] and run.decisions.size() == record_before[1] and run.body_state.to_save().hash() == body_before.hash(),
		"nor in its record, nor in the climber's body")
	_expect((_main.call("_capture_mountain") as Dictionary).hash() == mountain_before, "nor on the mountain")
	_expect(_stirred.is_empty(), "and nothing took the replayed climber for a live one %s" % [_stirred])
	_state_manager.transition_to(int(states["MAIN_MENU"]))
	await _wait(10)
	_expect(not screen.visible and not stage.is_open, "nothing of the replay is left at the main menu")


# =============================================================================
# A RUN THAT ENDED IN A FATAL EVENT
# =============================================================================

func _test_a_fatal_run() -> void:
	var states: Dictionary = _enums.GameState
	if not await _start_descent():
		_finish("could not start the second descent")
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var run: Object = _state_manager.current_run
	# A second run in one sitting: its recording begins on this mountain's
	# summit, not where the last run left the climber
	var second: Object = (_locator.get_service("RecordingService") as Node).get_current_recording()
	var summit: Vector3 = (_locator.get_service("TerrainService") as Object).start_position
	_expect(second.frames.size() > 0 and second.frames[0].player_position.distance_to(summit) < 2.0,
		"the next run's recording begins where that run began")
	Input.action_press("move_forward")
	await _seconds(6.0)
	_event_bus.weather_changed.emit(int(_enums.WeatherState["CLOUDY"]), int(_enums.WeatherState["STORM"]))
	await _seconds(14.0)
	# Something that would be a highlight on another day, seconds before the end
	_event_bus.record_decision("slide_initiated", {"position": player.global_position, "cause": "slip", "uncontrolled": true})
	_event_bus.record_incident("self_arrest_success", {"position": player.global_position, "speed": 6.0})
	await _seconds(2.0)
	Input.action_release("move_forward")
	var lost_at: float = run.real_time_elapsed
	_event_bus.fatal_event_started.emit(int(_enums.FatalPhase["MOMENT_OF_ERROR"]))
	await _seconds(4.0)
	_event_bus.fatal_event_completed.emit()
	_state_manager.complete_run(int(_enums.ResolutionType["FATALITY"]), "test")
	await _wait(10)
	_state_manager.transition_to(int(states["POST_GAME"]))
	await _wait(10)

	var post_game: Control = _main.get("post_game_screen")
	var watch: Button = post_game.get("watch_button")
	_expect(not watch.disabled, "a run that did not come home can be watched too")
	_stirred.clear()
	watch.pressed.emit()
	await _wait(5)
	var screen: Control = _main.get("replay_screen")
	var stage: Node3D = _main.get("replay_stage")
	var replays: Node = _locator.get_service("ReplayPlayer") as Node
	if not screen.visible or not stage.is_open:
		_expect(false, "the fatal run's replay opens")
		return
	var modes: Dictionary = stage.CameraMode
	var end: float = replays.get_end()
	_expect(replays.is_fatal_run and absf(replays.fatal_start - lost_at) < 0.3 and end > replays.fatal_start + 2.0,
		"the replay knows where control was lost (%.1f s of %.1f)" % [replays.fatal_start, end])

	# Normal speed, one camera
	replays.cycle_speed()
	replays.set_speed(4.0)
	_expect(is_equal_approx(replays.playback_speed, 1.0) and not replays.can_change_speed(), "it runs at normal speed only")
	replays.cycle_camera()
	replays.set_camera_mode(int(modes["CHASE"]))
	_expect(int(stage.mode) == int(modes["DRONE"]) and not replays.can_change_camera(), "from one camera: the film crew's drone")
	_expect(not (screen.get("speed_button") as Button).visible and not (screen.get("camera_button") as Button).visible, "and the screen offers neither")

	# The day before the loss can be wound; the loss cannot be wound into
	replays.pause()
	replays.seek(replays.get_start() + 3.0)
	_expect(absf(replays.current_timestamp - (replays.get_start() + 3.0)) < 0.1, "the day before it can be wound to and fro")
	replays.seek(end)
	_expect(replays.current_timestamp <= replays.fatal_start + 0.001, "but not past the moment control was lost (%.1f s)" % replays.current_timestamp)
	(screen.get("timeline") as HSlider).value = end
	await _wait(2)
	_expect(replays.current_timestamp <= replays.fatal_start + 0.001, "not with the timeline either")
	var listed_after := false
	for entry in screen.get("_entries"):
		if float(entry[0]) > replays.fatal_start - 8.0 and entry[2]:
			listed_after = true
	_expect(not listed_after, "no highlight comes from the moments before control was lost")
	var weather_listed := false
	for entry in screen.get("_entries"):
		if entry[2] and str(entry[1]).contains("Weather Turn"):
			weather_listed = true
	_expect(weather_listed, "the day's earlier highlight is still one")

	# The fatal moments: once, one take, nothing on the screen
	var bar: Control = screen.get("_bar")
	replays.seek(replays.fatal_start - 0.5)
	replays.play()
	await _seconds(1.2)
	_expect(replays.in_fatal_section and replays.is_playing(), "played into, the fatal moments are shown")
	_expect(not bar.visible and not (screen.get("_top") as Control).visible and not (screen.get("list_panel") as Control).visible, "with nothing on the screen but the mountain")
	replays.pause()
	replays.toggle()
	_expect(replays.is_playing(), "they cannot be paused")
	var held: float = replays.current_timestamp
	replays.seek(replays.get_start())
	replays.play_range(replays.get_start(), replays.get_start() + 2.0)
	_expect(replays.current_timestamp >= held and replays.in_fatal_section, "or wound back")
	replays.set_speed(0.5)
	replays.set_camera_mode(int(modes["WIDE"]))
	_expect(is_equal_approx(replays.playback_speed, 1.0) and int(stage.mode) == int(modes["DRONE"]), "or slowed, or re-framed")
	var guard := 0
	while replays.is_playing() and guard < 60 * 30:
		await physics_frame
		guard += 1
	_expect(not replays.is_playing() and not replays.in_fatal_section and replays.has_fatal_been_replayed(), "they play to the end of the run, once")
	_expect(bar.visible and (screen.get("map_button") as Button).visible and str((screen.get("note_label") as Label).text).contains("map"),
		"then the screen offers the day's path on the map")

	# A second time, the replay stops where control was lost
	var stopped: Array = []
	var on_stopped := func() -> void: stopped.append(true)
	replays.fatal_boundary_reached.connect(on_stopped)
	replays.seek(replays.fatal_start - 0.5)
	replays.play()
	await _seconds(1.5)
	replays.fatal_boundary_reached.disconnect(on_stopped)
	_expect(stopped.size() == 1 and not replays.is_playing() and not replays.in_fatal_section and absf(replays.current_timestamp - replays.fatal_start) < 0.05,
		"played again, it stops where control was lost")
	(screen.get("close_button") as Button).pressed.emit()
	await _wait(5)
	watch.pressed.emit()
	await _wait(5)
	replays.seek(replays.fatal_start - 0.3)
	replays.play()
	await _seconds(1.0)
	_expect(not replays.in_fatal_section and not replays.is_playing(), "and closing and opening the replay does not bring them back")

	# "Replay on the map" from there
	(screen.get("map_button") as Button).pressed.emit()
	await _wait(10)
	var map_replay: Control = _main.get("topo_replay")
	_expect(not screen.visible and not stage.is_open and map_replay != null and map_replay.visible, "the map button goes to the map replay")
	_expect(_stirred.is_empty(), "nothing took the replayed climber for a live one, the fatal moments included %s" % [_stirred])
	_state_manager.transition_to(int(states["MAIN_MENU"]))
	await _wait(10)


# =============================================================================
# A RUN THAT WAS SET ASIDE AND CONTINUED
# =============================================================================

func _test_a_run_that_was_continued() -> void:
	var states: Dictionary = _enums.GameState
	if not await _start_descent():
		_finish("could not start the third descent")
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var recorder: Node = _locator.get_service("RecordingService") as Node
	Input.action_press("move_forward")
	await _seconds(5.0)
	Input.action_release("move_forward")
	await _seconds(0.5)
	var frames_before: int = recorder.get_current_recording().frames.size()
	var first_place: Vector3 = recorder.get_current_recording().frames[0].player_position
	var run_id: String = _state_manager.current_run.run_id
	_state_manager.toggle_pause()
	await _wait(10)
	((_main.get("pause_menu") as Node).get("save_quit_button") as Button).pressed.emit()
	await _wait(20)
	_expect(int(_state_manager.current_state) == int(states["MAIN_MENU"]), "the run is set aside")
	((_main.get("main_menu") as Node).get("continue_button") as Button).pressed.emit()
	await _wait(60)
	if int(_state_manager.current_state) != int(states["DESCENT"]):
		_expect(false, "the run is picked up again")
		return
	var recording: Object = recorder.get_current_recording()
	_expect(recording.run_id == run_id and recording.frames.size() >= frames_before and recording.frames[0].player_position.distance_to(first_place) < 0.01,
		"picked up again, the recording has the first part of the day in it (%d frames, were %d)" % [recording.frames.size(), frames_before])
	player.posture.micro_slip_probability_scale = 0.0
	Input.action_press("move_forward")
	await _seconds(3.0)
	Input.action_release("move_forward")
	await _seconds(0.5)
	var run: Object = _state_manager.current_run
	var terrain: Object = _locator.get_service("TerrainService")
	player.global_position = terrain.goal_position + Vector3(0, 1, 0)
	await _wait(40)
	_state_manager.transition_to(int(states["POST_GAME"]))
	await _wait(10)
	((_main.get("post_game_screen") as Node).get("watch_button") as Button).pressed.emit()
	await _wait(5)
	var replays: Node = _locator.get_service("ReplayPlayer") as Node
	var screen: Control = _main.get("replay_screen")
	_expect(screen.visible and replays.get_start() < 1.0 and absf(replays.get_end() - run.real_time_elapsed) < 1.0 and recording.frames.size() > frames_before + 60,
		"and the replay is of the whole day, both sides of the break (%.1f s to %.1f s)" % [replays.get_start(), replays.get_end()])
	replays.pause()
	replays.seek(replays.get_start())
	await _wait(2)
	_expect(player.global_position.distance_to(first_place) < 0.05, "from its first step")
	(screen.get("close_button") as Button).pressed.emit()
	await _wait(5)
	_state_manager.transition_to(int(states["MAIN_MENU"]))
	await _wait(10)


# =============================================================================
# A RUN THAT IS OVER STAYS OVER
# =============================================================================

## The fatal rules watch a run that is still going, and only that. (They
## followed the game's state instead: every return to DESCENT wiped the time
## spent dangerously cold, so a pause or a look at the map reset the clock;
## and the watcher stayed on until the main menu, so a climber who got home
## dangerously cold was killed on the summary screen two minutes later, or
## while watching the replay.)
func _test_a_run_that_is_over_stays_over() -> void:
	var states: Dictionary = _enums.GameState
	if not await _start_descent():
		_finish("could not start the fourth descent")
		return
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var run: Object = _state_manager.current_run
	var detector: Node = _locator.get_service("FatalityDetector") as Node
	var fatal: Node = _locator.get_service("FatalEventManager") as Node
	var risk: Node = _locator.get_service("RiskDetectionService") as Node
	var allowed: float = detector.cold_fatal_duration
	detector.cold_fatal_duration = 6.0
	await _seconds(0.5)
	_expect(bool(detector.is_active) and risk.process_mode != Node.PROCESS_MODE_DISABLED, "a run that is going is watched")

	# Dangerously cold for a while, a pause in the middle
	run.body_state.cold_exposure = 0.85
	await _seconds(1.5)
	var cold_time: float = detector.cold_danger_time
	_expect(cold_time > 1.0, "the time spent dangerously cold is counted (%.1f s)" % cold_time)
	_state_manager.toggle_pause()
	await _wait(10)
	_expect(not bool(detector.is_active) or is_equal_approx(detector.cold_danger_time, cold_time), "not while the game is paused")
	_state_manager.toggle_pause()
	await _wait(3)
	_expect(detector.cold_danger_time >= cold_time, "and a pause does not wipe it (%.1f s)" % detector.cold_danger_time)

	# Home, that cold, and the summary left open for longer than the cold allows
	var terrain: Object = _locator.get_service("TerrainService")
	run.body_state.cold_exposure = 0.85
	player.global_position = terrain.goal_position + Vector3(0, 1, 0)
	await _wait(40)
	_expect(int(_state_manager.current_state) == int(states["RESOLUTION"]) and run.is_complete, "the climber gets home, dangerously cold")
	var outcome: int = int(run.outcome)
	_state_manager.transition_to(int(states["POST_GAME"]))
	await _wait(10)
	_stirred.clear()
	await _seconds(detector.cold_fatal_duration + 1.5)
	_expect(not bool(detector.is_active) and not bool(fatal.is_fatal_active) and not _stirred.has("fatal event"),
		"and is not killed on the summary screen %s" % [_stirred])
	fatal.call("_trigger_fatal", int(fatal.FatalTrigger["EXPOSURE"]), player.global_position)
	await _wait(5)
	_expect(not bool(fatal.is_fatal_active) and not _stirred.has("fatal event") and int(run.outcome) == outcome, "a run that is over cannot end again")
	_expect(risk.process_mode == Node.PROCESS_MODE_DISABLED, "the risk of the mountain sleeps until the next run")
	_expect(_stirred.is_empty(), "nothing stirs on the summary screen %s" % [_stirred])
	detector.cold_fatal_duration = allowed
	_state_manager.transition_to(int(states["MAIN_MENU"]))
	await _wait(10)


# =============================================================================
# HELPERS
# =============================================================================

## Menu to a descent on a steady mountain: no slips, weather changes or
## avalanches by chance
func _start_descent() -> bool:
	var states: Dictionary = _enums.GameState
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	mountain_db.select_mountain(MOUNTAIN, true)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(2)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(2)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(10)
	var planning: Control = _main.get("planning_screen")
	planning.set_day("steady", "settled")
	var waited := 0
	while not planning.route_valid and waited < 600:
		await process_frame
		waited += 1
	planning.confirm_button.pressed.emit()
	await _wait(40)
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	if int(_state_manager.current_state) != int(states["DESCENT"]) or player == null:
		return false
	player.posture.micro_slip_probability_scale = 0.0
	var weather: Node = _locator.get_service("WeatherService") as Node
	weather.base_change_probability = 0.0
	weather.weather_windows.clear()
	var avalanches: Object = _locator.get_service("AvalancheSystem")
	if is_instance_valid(avalanches):
		avalanches.active = false
	return true


## Press and let go of a gamepad button, the way the window would deliver it
func _press_pad(button: int) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = 0
		event.button_index = button as JoyButton
		event.pressed = pressed
		root.push_input(event)
		await _wait(2)


func _stir(what: String) -> void:
	_stirred[what] = int(_stirred.get(what, 0)) + 1


func _seconds(seconds: float) -> void:
	for i in range(int(ceil(seconds * 60.0))):
		await physics_frame


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_replay] ok: %s" % what)
	else:
		_failures.append(what)
		print("[test_replay] FAILED: %s" % what)


func _finish(fatal: String) -> void:
	if not fatal.is_empty():
		_failures.append(fatal)
	Input.action_release("move_forward")
	var timer: Node = _locator.get_service("SpeedrunTimer") as Node if _locator != null else null
	if timer != null and not _real_timer_path.is_empty():
		timer.data_path = _real_timer_path
		if FileAccess.file_exists(TEST_TIMER_DATA):
			DirAccess.remove_absolute(TEST_TIMER_DATA)
	var saves: Node = _locator.get_service("SaveManager") as Node if _locator != null else null
	if saves != null and not _real_suspend_path.is_empty():
		saves.clear_suspended_run()
		saves.suspend_path = _real_suspend_path
	if _failures.is_empty():
		print("[test_replay] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_replay] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
