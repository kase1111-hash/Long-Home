extends SceneTree
## Audio test: the sound library, the mix, and that what happens on the
## mountain is heard.
##
## Run from the project root:
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_audio.gd
## Exit code 0 on PASS, 1 on FAIL (prints "[test_audio] PASS" / "FAIL: ...").
##
## What it covers:
##   - every sound file loads, loops loop, and the generated stand-ins work
##     when there are no files
##   - the buses and their effects exist
##   - the menu has a quiet wind and its buttons click
##   - on the mountain: wind layers by wind strength (every strength and every
##     weather maps to something), breath, one footstep sound per step and the
##     right one for the footwear, nothing stuck after a pause
##   - a real crampon change, a real glissade and a real self-arrest are heard
##   - avalanche, burial, crevasse, rope, probe, obstacle and map events each
##     ask for their sound, and the world is muffled while buried
##   - a fatal event silences the climber (no impact, no cry)
##   - nothing asked for a sound the library does not have
##
## The Dummy audio driver mixes like a real one, so bus levels are real even
## though nothing reaches a speaker.
##
## The run is scripted, so the mountain's own chance events (slips, weather
## windows, avalanches, lulls in the wind) are switched off for it: see
## _steady_the_mountain().
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time (see
## tests/smoke_goal.gd).

const MOUNTAIN := "knife_edge"
const SEARCH_RADIUS := 400.0

## Sounds the game cannot do without, and the stand-ins must cover
const CORE_SOUNDS: Array[String] = [
	"wind_low_loop", "wind_mid_loop", "wind_gust", "breath_calm_in", "breath_calm_out",
	"breath_hard_in", "breath_hard_out", "footstep_snow_firm", "footstep_rock", "slide_snow_loop",
]

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _event_bus: Node = null
var _library: Object = null
var _service: Object = null
var _failures: Array[String] = []
var _checks: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	seed(20261111)
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_event_bus = root.get_node_or_null("/root/EventBus")
	if _state_manager == null or _enums == null or _locator == null or _event_bus == null:
		_finish("autoloads missing; run with --path <project root>")
		return

	var started := Time.get_ticks_msec()
	var main_scene: Node = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main_scene)
	await _wait(5)
	print("[test_audio] boot took %d ms" % (Time.get_ticks_msec() - started))

	_library = _locator.get_service("SoundLibrary")
	_service = _locator.get_service("AudioService")
	_expect(is_instance_valid(_library) and is_instance_valid(_service), "the audio system came up")
	if not is_instance_valid(_library) or not is_instance_valid(_service):
		_finish("no audio system")
		return

	# The checks read levels at set moments: the wind must not take one of its
	# random lulls in the middle of one
	_locator.get_service("AmbientAudioManager").silence_moment_chance = 0.0

	_test_library()
	_test_buses()
	await _test_menu(main_scene)
	if not await _start_descent():
		_finish("could not start a descent")
		return
	await _test_descent_ambience()
	await _test_wind_and_weather()
	await _test_footsteps_in_crampons()
	await _test_pause()
	await _test_crampons_off()
	await _test_glissade()
	await _test_hazards()
	await _test_rope_and_gear()
	await _test_map()
	await _test_fatal()

	var missing: PackedStringArray = _library.get_missing()
	_expect(missing.is_empty(), "nothing asked for a sound the library does not have (%s)" % ", ".join(missing))
	_finish("")


# =============================================================================
# THE LIBRARY AND THE BUSES
# =============================================================================

func _test_library() -> void:
	var summary: Dictionary = _library.get_summary()
	print("[test_audio] library: %d sounds, %d files" % [summary["sounds"], summary["files"]])
	_expect(not _library.using_placeholders, "sound files were found (not the generated stand-ins)")
	_expect(int(summary["sounds"]) >= 100, "the library holds the whole sound set (%d sounds)" % summary["sounds"])

	var loops := 0
	var wrong: Array[String] = []
	for id in _library.get_ids():
		var is_loop: bool = str(id).ends_with("_loop")
		for index in range(_library.variant_count(id)):
			var stream: AudioStream = _library.get_variant(id, index)
			var wav := stream as AudioStreamWAV
			if wav == null:
				continue
			var looping := wav.loop_mode != AudioStreamWAV.LOOP_DISABLED
			if looping != is_loop:
				wrong.append(str(id))
			if is_loop:
				loops += 1
				if wav.loop_end <= wav.loop_begin or wav.get_length() < 1.0:
					wrong.append(str(id) + " (loop points)")
	_expect(wrong.is_empty(), "loops loop and one-shots do not (%d loops; wrong: %s)" % [loops, ", ".join(wrong)])
	for id in CORE_SOUNDS:
		_expect(_library.has_sound(id), "the library has '%s'" % id)
	_expect(_library.variant_count("footstep_snow_firm") >= 3, "footsteps come in several variants")

	var library_script: GDScript = load("res://src/systems/audio/sound_library.gd") as GDScript
	_expect(library_script.id_of("footstep_snow_firm_03.wav") == "footstep_snow_firm", "a file's id drops its number")
	_expect(library_script.id_of("wind_low_loop_01.wav") == "wind_low_loop", "a loop keeps _loop in its id")
	_expect(library_script.id_of("my_recording.ogg") == "my_recording", "a file without a number is its own id")

	# A variant is never played twice running
	var repeats := 0
	var last: AudioStream = null
	for i in range(40):
		var stream: AudioStream = _library.get_stream("footstep_snow_firm")
		if stream == last:
			repeats += 1
		last = stream
	_expect(repeats == 0, "the same variant is not picked twice running")

	# No files at all: rough stand-ins, so the game is never silent
	var spare: Node = library_script.new()
	spare.load_all("res://no_such_folder")
	_expect(spare.using_placeholders, "with no sound files the library generates stand-ins")
	var covered := true
	for id in CORE_SOUNDS:
		covered = covered and spare.has_sound(id)
	_expect(covered, "the stand-ins cover wind, breath, footsteps and a slide")
	spare.free()
	_library.clear_requests()


func _test_buses() -> void:
	for bus in ["Ambient", "AmbientLeft", "AmbientRight", "Player", "Effects", "UI"]:
		_expect(AudioServer.get_bus_index(bus) >= 0, "bus %s exists" % bus)
	var ambient := AudioServer.get_bus_index("Ambient")
	var effects := AudioServer.get_bus_index("Effects")
	var player_bus := AudioServer.get_bus_index("Player")
	_expect(AudioServer.get_bus_effect(ambient, 0) is AudioEffectLowPassFilter, "Ambient has its muffle filter")
	_expect(AudioServer.get_bus_effect(effects, 0) is AudioEffectLowPassFilter
		and AudioServer.get_bus_effect(effects, 1) is AudioEffectReverb, "Effects has its filter and its reverb")
	_expect(AudioServer.get_bus_effect(player_bus, 0) is AudioEffectReverb, "Player has its reverb")
	_expect(not AudioServer.is_bus_effect_enabled(ambient, 0) and not AudioServer.is_bus_effect_enabled(effects, 1),
		"the muffle and the reverb are off in open air")
	_expect(AudioServer.get_bus_send(AudioServer.get_bus_index("AmbientLeft")) == &"Ambient",
		"the two halves of the wind feed the Ambient bus")


# =============================================================================
# MENU
# =============================================================================

func _test_menu(main_scene: Node) -> void:
	var states: Dictionary = _enums.GameState
	_expect(int(_state_manager.current_state) == int(states["MAIN_MENU"]), "boot lands on the main menu")
	var ambient: Object = _locator.get_service("AmbientAudioManager")
	await _seconds(1.5)
	_expect(ambient.is_active and ambient.presence < 0.7, "the menu has ambience, kept low (presence %.2f)" % ambient.presence)
	_expect(ambient.get_layer_gain("low") > 0.01, "a quiet wind plays behind the menu")
	_expect(_library.get_request_count("breath_calm_in") == 0, "nobody is breathing in the menu")

	# A button anywhere in the tree clicks without its screen asking
	var menu: Node = main_scene.get("main_menu")
	var button: BaseButton = _find_button(menu)
	_expect(button != null, "the main menu has a button")
	if button != null:
		_library.clear_requests()
		button.pressed.emit()
		await _wait(2)
		var clicks: int = _library.get_request_count("ui_select") + _library.get_request_count("ui_confirm") \
			+ _library.get_request_count("ui_back") + _library.get_request_count("ui_toggle")
		_expect(clicks == 1, "pressing a menu button plays one click (%d)" % clicks)
		button.mouse_entered.emit()
		await _wait(2)
		_expect(_library.get_request_count("ui_hover") == 1, "moving onto a button ticks")
	# The click above pressed the real button: come back to the main menu
	_state_manager.transition_to(int(states["MAIN_MENU"]))
	await _wait(3)


func _find_button(node: Node) -> BaseButton:
	if node == null:
		return null
	if node is BaseButton and not (node as BaseButton).disabled:
		return node as BaseButton
	for child in node.get_children():
		var found := _find_button(child)
		if found != null:
			return found
	return null


# =============================================================================
# ON THE MOUNTAIN
# =============================================================================

func _start_descent() -> bool:
	var states: Dictionary = _enums.GameState
	var mountain_db: Object = _locator.get_service("MountainDatabase")
	if is_instance_valid(mountain_db):
		mountain_db.select_mountain(MOUNTAIN)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(1)
	var conditions: Resource = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	conditions.mountain_id = MOUNTAIN
	_library.clear_requests()
	_state_manager.start_run(MOUNTAIN, conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	await _wait(30)
	if int(_state_manager.current_state) != int(states["DESCENT"]) \
			or not is_instance_valid(_locator.get_service("PlayerController")):
		return false
	_steady_the_mountain()
	return true


## From here on the test says what happens, so the mountain must not act on
## its own. Left alone it does: in boots on a 34 degree slope the climber can
## slip before the glissade is asked for, a weather window can change the wind
## between two readings of it, and an avalanche can release. seed() does not
## pin these down: the weather draws from the same generator once per drawn
## frame, and how many frames are drawn differs from run to run.
func _steady_the_mountain() -> void:
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	# No slips by chance (the sound of a slip is asked for by hand further on)
	player.posture.micro_slip_probability_scale = 0.0
	# No weather of its own: the test sets the wind and the weather
	var weather: Node = _locator.get_service("WeatherService") as Node
	if weather != null:
		weather.set_process(false)
		weather.base_change_probability = 0.0
	# No avalanches of its own: the test sends the avalanche's signals
	var avalanches: Object = _locator.get_service("AvalancheSystem")
	if is_instance_valid(avalanches):
		avalanches.active = false


func _test_descent_ambience() -> void:
	var ambient: Object = _locator.get_service("AmbientAudioManager")
	var player_audio: Object = _locator.get_service("PlayerAudioManager")
	await _seconds(3.0)
	_expect(ambient.is_active and ambient.presence > 0.99, "on the mountain the ambience is at full presence")
	_expect(ambient.get_layer_gain("low") > 0.05 and ambient.get_layer_gain("mid_left") > 0.01
		and ambient.get_layer_gain("mid_right") > 0.01, "the wind's body and both of its sides are playing")
	var peak := AudioServer.get_bus_peak_volume_left_db(AudioServer.get_bus_index("Ambient"), 0)
	_expect(peak > -60.0, "the Ambient bus carries signal (peak %.1f dB)" % peak)
	_expect(player_audio.is_enabled, "the climber's audio is on")

	await _seconds(4.0)
	var breaths: int = _library.get_request_count("breath_calm_in") + _library.get_request_count("breath_hard_in")
	var out_breaths: int = _library.get_request_count("breath_calm_out") + _library.get_request_count("breath_hard_out")
	_expect(breaths >= 1 and out_breaths >= 1, "the climber breathes in and out (%d in, %d out in 7 s)" % [breaths, out_breaths])
	_expect(breaths <= 6, "and not faster than a resting climber would (%d breaths in 7 s)" % breaths)

	var terrain: Object = _locator.get_service("TerrainService")
	var flags: AudioStreamPlayer3D = ambient._summit_flags.player
	_expect(flags.stream != null and flags.global_position.distance_to(terrain.start_position) < 5.0,
		"the prayer flags are heard from the summit cairn")
	_expect(flags.playing, "and they are flapping")


func _test_wind_and_weather() -> void:
	var ambient: Object = _locator.get_service("AmbientAudioManager")
	var winds: Dictionary = _enums.WindStrength
	var previous := -1.0
	var rising := true
	for name in ["CALM", "LIGHT", "MODERATE", "STRONG", "GALE", "SEVERE"]:
		_event_bus.wind_changed.emit(int(winds[name]), Vector3.RIGHT)
		var heard: float = ambient.wind_intensity
		rising = rising and heard > previous
		previous = heard
	_expect(rising, "every step up in wind strength is louder than the last (a gale is not quiet)")
	_expect(winds.size() == 6, "all six wind strengths are covered")

	var weathers: Dictionary = _enums.WeatherState
	var mapped := true
	for name in weathers.keys():
		ambient.weather_intensity = -1.0
		_event_bus.weather_changed.emit(int(weathers["CLEAR"]), int(weathers[name]))
		mapped = mapped and ambient.weather_intensity >= 0.0
	_expect(mapped, "all %d kinds of weather set the storminess" % weathers.size())
	_event_bus.weather_changed.emit(int(weathers["CLEAR"]), int(weathers["STORM"]))
	var storm: float = ambient.weather_intensity
	_event_bus.weather_changed.emit(int(weathers["STORM"]), int(weathers["CLEARING"]))
	_expect(ambient.weather_intensity < storm, "a clearing sky is calmer than the storm before it")

	# A gale howls and blows spindrift; calm air does neither
	_event_bus.weather_changed.emit(int(weathers["CLEAR"]), int(weathers["STORM"]))
	_event_bus.wind_changed.emit(int(winds["GALE"]), Vector3.RIGHT)
	await _seconds(7.0)
	var gale_wind: float = ambient.get_wind_gain()
	var gale_howl: float = ambient.get_layer_gain("howl_left") + ambient.get_layer_gain("howl_right")
	var gale_spindrift: float = ambient.get_layer_gain("spindrift")
	var gale_peak := AudioServer.get_bus_peak_volume_left_db(AudioServer.get_bus_index("Master"), 0)
	_expect(gale_howl > 0.2, "a gale howls (howl gain %.2f)" % gale_howl)
	_expect(gale_spindrift > 0.1, "and drives spindrift across the snow (gain %.2f)" % gale_spindrift)
	_expect(_library.get_request_count("wind_gust") >= 1, "gusts come through")
	_expect(gale_peak < -1.0, "the storm mix leaves headroom (master peak %.1f dB)" % gale_peak)

	_event_bus.weather_changed.emit(int(weathers["STORM"]), int(weathers["CLEAR"]))
	_event_bus.wind_changed.emit(int(winds["CALM"]), Vector3.RIGHT)
	await _seconds(12.0)
	var calm_howl: float = ambient.get_layer_gain("howl_left") + ambient.get_layer_gain("howl_right")
	_expect(ambient.get_wind_gain() < gale_wind * 0.35, "calm air is much quieter than the gale (%.2f against %.2f)" % [
		ambient.get_wind_gain(), gale_wind])
	_expect(calm_howl < 0.02 and ambient.get_layer_gain("spindrift") < 0.02, "and neither howls nor lifts the snow")
	_event_bus.wind_changed.emit(int(winds["MODERATE"]), Vector3.RIGHT)


func _test_footsteps_in_crampons() -> void:
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var player_audio: Object = _locator.get_service("PlayerAudioManager")
	var steps_system: Node = player.get_node_or_null("FootstepSystem")
	_expect(steps_system != null, "the climber has a FootstepSystem")
	if steps_system == null:
		return
	var counts := {"steps": 0, "sounds": 0}
	var on_step := func(_surface: int, _foot: StringName) -> void: counts["steps"] += 1
	var on_sound := func(_surface: int) -> void: counts["sounds"] += 1
	steps_system.footstep_played.connect(on_step)
	player_audio.footstep_played.connect(on_sound)

	_expect(player.footwear == int(_enums.Footwear["CRAMPONS"]), "the run starts in crampons")
	_library.clear_requests()
	Input.action_press("move_forward")
	await _seconds(5.0)
	Input.action_release("move_forward")
	await _seconds(0.5)
	steps_system.footstep_played.disconnect(on_step)
	player_audio.footstep_played.disconnect(on_sound)

	var surface_names: Array = _enums.SurfaceType.keys()
	print("[test_audio] walked %d steps on %s: %s" % [counts["steps"],
		surface_names[player.current_cell.surface_type] if player.current_cell else "?",
		_requested("footstep_") + _requested("crampon_")])
	_expect(counts["steps"] >= 3, "walking for 5 s takes steps (%d)" % counts["steps"])
	_expect(counts["sounds"] == counts["steps"], "each step on snow is heard once, not twice (%d sounds for %d steps)" % [
		counts["sounds"], counts["steps"]])
	_expect(_library.get_request_count("crampon_snow") >= 1, "crampons on firm snow sound like crampons")
	_expect(_library.get_request_count("footstep_snow_firm") == 0, "and not like bare boots")


func _test_pause() -> void:
	var ambient: Object = _locator.get_service("AmbientAudioManager")
	var winds: Dictionary = _enums.WindStrength
	_event_bus.wind_changed.emit(int(winds["STRONG"]), Vector3.RIGHT)
	await _seconds(1.0)
	var before: float = ambient.wind_intensity
	_state_manager.toggle_pause()
	await _wait(20)
	_expect(paused, "the game pauses")
	var silent := AudioServer.get_bus_peak_volume_left_db(AudioServer.get_bus_index("Ambient"), 0)
	_expect(silent < -90.0, "the mountain is silent while paused (%.0f dB)" % silent)
	_state_manager.toggle_pause()
	await _seconds(1.5)
	_expect(not paused, "and resumes")
	_expect(is_equal_approx(ambient.wind_intensity, before), "the wind is as strong after the pause as before it (%.2f, was %.2f)" % [
		ambient.wind_intensity, before])
	_expect(ambient.get_layer_gain("low") > 0.05, "and it is heard again")
	_event_bus.wind_changed.emit(int(winds["MODERATE"]), Vector3.RIGHT)


func _test_crampons_off() -> void:
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	_library.clear_requests()
	await _tap("crampons_toggle")
	await _seconds(0.3)
	_expect(player.gear_action == &"crampons", "F starts taking the crampons off")
	_expect(_library.get_request_count("crampon_clank") >= 1, "the crampons are heard coming off the boots")
	await _seconds(player.gear_action_duration + 0.6)
	_expect(player.footwear == int(_enums.Footwear["BOOTS"]), "crampons off")

	_library.clear_requests()
	Input.action_press("move_forward")
	await _seconds(3.0)
	Input.action_release("move_forward")
	_expect(_library.get_request_count("footstep_snow_firm") >= 1, "in boots the same snow sounds like boots (%s)" % _requested("footstep_"))
	_expect(_library.get_request_count("crampon_snow") == 0, "with no crampons in it")


func _test_glissade() -> void:
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	var slides: Object = _locator.get_service("SlideSystem")
	var player_audio: Object = _locator.get_service("PlayerAudioManager")
	var gear_audio: Node = _service.gear_audio

	var firm: int = _enums.SurfaceType["SNOW_FIRM"]
	var cells: Array = terrain.find_cells(player.global_position, SEARCH_RADIUS,
		func(cell: Object) -> bool:
			return cell.slope_angle >= 31.0 and cell.slope_angle <= 35.0 \
				and int(cell.surface_type) == firm and cell.distance_to_cliff > 80.0)
	# A long run with nothing in the way: no flattening out, no tree or boulder
	var best: Object = null
	for cell in cells:
		var clear := true
		for step in range(1, 12):
			var below: Vector3 = cell.position + cell.slope_direction * (step * 5.0)
			if step < 6 and terrain.get_slope_at(below) < 26.0:
				clear = false
			if terrain.scatter != null and not terrain.scatter.get_objects_near(below, 5.0).is_empty():
				clear = false
			if not clear:
				break
		if clear:
			best = cell
			break
	_expect(best != null, "found a clear slope to glissade (%d candidates)" % cells.size())
	if best == null:
		return
	var spot: Vector3 = best.position
	spot.y = terrain.get_height_at(spot) + 0.3
	player.global_position = spot
	player.velocity = Vector3.ZERO
	await _seconds(0.5)
	player.look_at(player.global_position + best.slope_direction, Vector3.UP)

	_library.clear_requests()
	await _tap("slide_initiate")
	await _seconds(0.3)
	_expect(slides.is_sliding, "Space on the slope starts a glissade")
	if not slides.is_sliding:
		return
	_expect(_library.get_request_count("slide_start") == 1, "sitting down and letting go is heard")
	_expect(_library.get_request_count("breath_gasp_in") >= 1, "with a breath snatched in")

	await _seconds(2.5)
	var speed: float = player.velocity.length()
	_expect(player_audio.get_loop_gain("slide_snow") > 0.2, "the slide on snow is heard (gain %.2f at %.1f m/s)" % [
		player_audio.get_loop_gain("slide_snow"), speed])
	_expect(player_audio.get_loop_gain("slide_ice") < 0.01, "as snow, not as ice")
	_expect(player_audio.get_loop_gain("air_rush") > 0.02, "and the air starts to rush (gain %.2f)" % player_audio.get_loop_gain("air_rush"))

	# Heels and spike: the axe drags
	Input.action_press("move_back")
	await _seconds(1.0)
	var braking: float = (gear_audio._loops["axe_drag"] as RefCounted).gain
	_expect(braking > 0.05, "braking drags the axe (gain %.2f)" % braking)

	# Self-arrest, still braking: above the speed firm snow holds a pick at, the
	# axe can be torn out again, and that is a roll of the dice
	var pick_in := {"speed": -1.0}
	var on_engaged := func() -> void: pick_in["speed"] = player.velocity.length()
	slides.self_arrest_engaged.connect(on_engaged)
	var tapped_at: float = player.velocity.length()
	await _tap("slide_initiate")
	var waited := 0.0
	while waited < 12.0 and slides.is_sliding:
		await physics_frame
		waited += 1.0 / 60.0
	Input.action_release("move_back")
	slides.self_arrest_engaged.disconnect(on_engaged)
	print("[test_audio] self-arrest asked for at %.1f m/s, pick in at %.1f m/s" % [tapped_at, pick_in["speed"]])
	_expect(not slides.is_sliding, "the arrest stops the slide (%.1f s)" % waited)
	var traction: GDScript = load("res://src/entities/player/traction_model.gd") as GDScript
	var holds_to: float = traction.arrest_hold_speed(firm) * lerpf(0.75, 1.0, player.get_ice_axe_effectiveness())
	_expect(pick_in["speed"] >= 0.0 and pick_in["speed"] <= holds_to,
		"with the pick going in below the speed that tears an axe out (%.1f m/s, holds to %.1f)" % [pick_in["speed"], holds_to])
	_expect(_library.get_request_count("axe_bite") == 1, "the pick is heard going in")
	_expect(_library.get_request_count("arrest_stop") == 1, "and the slide is heard ending")
	await _seconds(2.0)
	_expect(player_audio.get_loop_gain("slide_snow") < 0.01, "the slide sound has stopped with the slide")
	_expect(_library.get_request_count("reaction_relief") >= 1, "and the climber lets a breath go")


# =============================================================================
# EVENTS
# =============================================================================

func _test_hazards() -> void:
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var avalanches: Object = _locator.get_service("AvalancheSystem")
	var crevasses: Object = _locator.get_service("CrevasseSystem")
	var hazard: Node = _service.hazard_audio
	var player_audio: Object = _locator.get_service("PlayerAudioManager")
	_expect(is_instance_valid(avalanches) and is_instance_valid(crevasses), "the hazard systems exist")
	if not is_instance_valid(avalanches) or not is_instance_valid(crevasses):
		return

	# From here to the end the events are sent by hand. Stand the climber on
	# the flat of the summit first, so that nothing physical follows from them:
	# a ripped anchor throws the climber off, and on the glissade slope that
	# would be a tumble down it for the rest of the test
	var terrain: Object = _locator.get_service("TerrainService")
	var top: Vector3 = terrain.start_position
	top.y = terrain.get_height_at(top) + 0.3
	player.global_position = top
	player.velocity = Vector3.ZERO
	await _seconds(1.5)
	_expect(int(player.current_state) == int(_enums.PlayerMovementState["STANDING"]),
		"back on the summit, standing (state %s)" % _enums.PlayerMovementState.keys()[player.current_state])

	_library.clear_requests()
	avalanches.warning_sign.emit("whumpf")
	avalanches.warning_sign.emit("cracks")
	await _wait(2)
	_expect(_library.get_request_count("whumpf") == 1, "a whumpf is heard")
	_expect(_library.get_request_count("snow_crack") == 1, "shooting cracks are heard")

	# A slab breaking close above
	var flow_script: GDScript = load("res://src/systems/avalanche/avalanche_flow.gd") as GDScript
	var here: Vector3 = player.global_position
	var near: Object = flow_script.new()
	near.id = 9001
	near.kind = int(flow_script.Kind.SLAB)
	near.size = 3
	near.origin = here + Vector3(30.0, 20.0, 0.0)
	near.add_parcel(near.origin, 4.0, Vector3(-12.0, -6.0, 0.0))
	_library.clear_requests()
	avalanches.avalanche_released.emit(near)
	await _seconds(1.5)
	_expect(_library.get_request_count("slab_release") == 1, "a slab releasing nearby cracks")
	_expect(_library.get_request_count("avalanche_distant") == 0, "and is not mistaken for a distant one")
	_expect(hazard.get_summary()["roars"] == 1, "its roar follows the debris")
	var roar: Dictionary = hazard._roars[9001]
	var roar_voice: AudioStreamPlayer3D = (roar["fader"] as RefCounted).player
	_expect(roar_voice.playing and roar_voice.global_position.distance_to(near.origin) < 1.0,
		"from where the debris is")
	near.finished = true
	avalanches.avalanche_stopped.emit(near)
	await _seconds(1.0)
	_expect((roar["fader"] as RefCounted).gain < 0.7 and roar_voice.playing, "the roar dies away when the avalanche stops")
	await _seconds(6.0)
	_expect(hazard.get_summary()["roars"] == 0, "and is gone a few seconds later")
	_expect(_library.get_request_count("debris_settle") == 1, "and the debris is heard setting")

	# One a long way off, and a serac
	var far: Object = flow_script.new()
	far.id = 9002
	far.kind = int(flow_script.Kind.SLAB)
	far.size = 2
	far.natural = true
	far.origin = here + Vector3(600.0, 150.0, 0.0)
	far.finished = true
	var ice: Object = flow_script.new()
	ice.id = 9003
	ice.kind = int(flow_script.Kind.ICE)
	ice.size = 1
	ice.origin = here + Vector3(0.0, 80.0, 250.0)
	ice.finished = true
	_library.clear_requests()
	avalanches.avalanche_released.emit(far)
	avalanches.avalanche_released.emit(ice)
	await _seconds(3.0)
	_expect(_library.get_request_count("avalanche_distant") == 1, "a far-off avalanche is a distant roar")
	_expect(_library.get_request_count("serac_fall") == 1, "a serac falls with its own crack")
	_expect(hazard.get_summary()["roars"] == 0, "finished flows leave nothing playing")

	# Caught, buried, out
	_library.clear_requests()
	avalanches.climber_caught.emit(near)
	await _seconds(1.2)
	_expect(_service.get_muffle() > 0.3, "caught in the flow, the world is muffled (%.2f)" % _service.get_muffle())
	_expect((hazard._inside as RefCounted).gain > 0.3, "and the flow is heard from inside")
	_expect(AudioServer.is_bus_effect_enabled(AudioServer.get_bus_index("Ambient"), 0), "through the Ambient low-pass")
	avalanches.climber_buried.emit(0.9)
	await _seconds(1.5)
	_expect(_service.get_muffle() > 0.9, "buried with the head under, almost nothing gets through (%.2f)" % _service.get_muffle())
	_expect(player_audio.tension > 0.8, "and the heart is loud (tension %.2f)" % player_audio.tension)
	_expect(_library.get_request_count("heartbeat") >= 1, "the heartbeat is heard")
	_expect((hazard._inside as RefCounted).level == 0.0, "the flow itself has stopped")
	avalanches.climber_freed.emit()
	await _seconds(1.5)
	_expect(_service.get_muffle() < 0.05, "dug out, the world comes back (%.2f)" % _service.get_muffle())
	_expect(not AudioServer.is_bus_effect_enabled(AudioServer.get_bus_index("Ambient"), 0), "and the low-pass is off")
	_expect(_library.get_request_count("reaction_relief") >= 1, "with a breath of relief")

	# Crevasse
	_library.clear_requests()
	crevasses.crevasse_fall.emit(null)
	crevasses.probed.emit(true)
	crevasses.probed.emit(false)
	await _wait(2)
	_expect(_library.get_request_count("bridge_collapse") == 1, "a snow bridge collapsing is heard")
	_expect(_library.get_request_count("probe_hollow") == 1 and _library.get_request_count("probe_firm") == 1,
		"the probe says what it found: hollow, or firm")

	# Meeting things
	_library.clear_requests()
	_event_bus.incident_recorded.emit("obstacle_impact", {"object": "tree", "speed": 8.0})
	_event_bus.incident_recorded.emit("injury", {"severity": 0.5})
	_event_bus.micro_slip_occurred.emit(0.7, here)
	await _wait(2)
	_expect(_library.get_request_count("impact_tree") == 1, "hitting a tree sounds like a tree")
	_expect(_library.get_request_count("reaction_pain") == 1, "an injury is a hiss of pain")
	_expect(_library.get_request_count("slip_snow") + _library.get_request_count("slip_ice")
		+ _library.get_request_count("slip_rock") == 1, "a slip is heard as a skid on what is underfoot")
	_library.clear_requests()
	_event_bus.incident_recorded.emit("obstacle_impact", {"object": "boulder", "speed": 8.0})
	_event_bus.incident_recorded.emit("injury", {"severity": 0.5})
	await _wait(2)
	_expect(_library.get_request_count("impact_rock") == 1, "hitting a boulder sounds like rock")
	_expect(_library.get_request_count("reaction_pain") == 0, "two hurts at once are one hiss, not a chorus")


func _test_rope_and_gear() -> void:
	var deployment: Object = _locator.get_service("RopeDeploymentSystem")
	var rappel: Object = _locator.get_service("RappelController")
	var rope: Object = _locator.get_service("RopeService")
	_expect(is_instance_valid(deployment) and is_instance_valid(rappel) and is_instance_valid(rope),
		"the rope systems exist")
	if not is_instance_valid(deployment) or not is_instance_valid(rappel) or not is_instance_valid(rope):
		return
	var deploy_states: Dictionary = deployment.DeploymentState
	var outcomes: Dictionary = rappel.RappelOutcome

	_library.clear_requests()
	_event_bus.rope_deployment_started.emit(int(_enums.AnchorQuality["GOOD"]))
	await _seconds(0.8)
	_expect(_library.get_request_count("rope_uncoil") == 1, "getting the rope out is heard")
	deployment.state_changed.emit(int(deploy_states["PLACING"]), int(deploy_states["TESTING"]))
	deployment.state_changed.emit(int(deploy_states["TESTING"]), int(deploy_states["READY"]))
	await _seconds(1.3)
	_expect(_library.get_request_count("rope_tug") == 1, "testing the anchor is two tugs on the rope")
	_expect(_library.get_request_count("rope_throw") == 1, "the ends are thrown")
	_expect(_library.get_request_count("carabiner_clip") == 1, "and the device is clipped in")

	_library.clear_requests()
	rappel.rope_jam_occurred.emit()
	rappel.rope_jam_cleared.emit()
	rappel.rope_end_reached.emit()
	rappel.anchor_stress_warning.emit(0.8)
	rappel.anchor_stress_warning.emit(0.8)
	await _seconds(0.5)
	_expect(_library.get_request_count("rope_jam") == 1, "a snagged rope is heard")
	_expect(_library.get_request_count("rope_flick") == 1, "and flicked free")
	_expect(_library.get_request_count("rope_knot") == 1, "the knots at the end arrive in the device")
	_expect(_library.get_request_count("rope_creak") >= 1 and _library.get_request_count("rope_creak") <= 2,
		"a loaded anchor creaks, but not on every tick")

	_library.clear_requests()
	rappel.rappel_ended.emit(int(outcomes["ANCHOR_FAILURE"]))
	rope.recovery_complete.emit(true, null)
	_event_bus.decision_recorded.emit("airbag_deployed", {})
	await _wait(2)
	_expect(_library.get_request_count("anchor_fail") == 1, "an anchor ripping is heard")
	_expect(_library.get_request_count("rope_fall") == 1, "a pulled rope comes down")
	_expect(_library.get_request_count("airbag_deploy") == 1, "the airbag bangs open")


func _test_map() -> void:
	_library.clear_requests()
	_service.play_map_open()
	_event_bus.map_opened.emit()
	await _wait(3)
	_expect(_library.get_request_count("map_unfold") == 1, "opening the map unfolds it once, not twice")
	_service.play_map_close()
	_event_bus.map_closed.emit()
	await _wait(3)
	_expect(_library.get_request_count("map_fold") == 1, "and closing it folds it once")


func _test_fatal() -> void:
	var player_audio: Object = _locator.get_service("PlayerAudioManager")
	var ambient: Object = _locator.get_service("AmbientAudioManager")
	var phases: Dictionary = _enums.FatalPhase
	# A gust is wind, and wind goes on: keep the next one clear of the count below
	ambient._next_gust = 30.0
	_event_bus.fatal_event_started.emit(int(phases["MOMENT_OF_ERROR"]))
	_event_bus.fatal_phase_changed.emit(int(phases["MOMENT_OF_ERROR"]), int(phases["LOSS_OF_CONTROL"]))
	await _wait(3)
	_expect(ambient.in_fatal_sequence, "the fatal sequence takes over the wind")
	_expect(not player_audio.is_enabled, "the climber's audio is cut, not faded")
	_expect(_service.get_active_voice_count() == 0, "and every other sound stops")

	_library.clear_requests()
	_event_bus.incident_recorded.emit("obstacle_impact", {"object": "boulder", "speed": 20.0})
	_event_bus.incident_recorded.emit("fall_injury", {"severity": 1.0})
	await _wait(3)
	var heard: int = _library.get_request_count("impact_rock") + _library.get_request_count("reaction_pain") \
		+ _library.get_request_count("impact_snow")
	_expect(heard == 0, "no impact and no cry are played during a fatal event")
	await _seconds(3.0)
	_expect(ambient.get_layer_gain("low") > 0.1, "only the wind is left")
	_event_bus.fatal_event_completed.emit()
	await _wait(2)
	_expect(not ambient.in_fatal_sequence, "and it lets go when the sequence ends")


# =============================================================================
# HELPERS
# =============================================================================

## The requested ids that start with prefix, as "id xN, id xN"
func _requested(prefix: String) -> String:
	var parts: Array[String] = []
	for id in _library.get_requested_ids():
		if str(id).begins_with(prefix):
			parts.append("%s x%d" % [id, _library.get_request_count(id)])
	return ", ".join(parts) + (" " if not parts.is_empty() else "")


func _tap(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await physics_frame
	Input.action_release(action)


func _seconds(seconds: float) -> void:
	for i in range(int(ceil(seconds * 60.0))):
		await physics_frame


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_audio] ok: %s" % what)
	else:
		print("[test_audio] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[test_audio] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_audio] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
