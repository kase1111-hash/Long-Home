class_name GearAudioManager
extends Node
## Manages gear interaction audio
## Handles rope, anchors, ice axe, crampons, bindings, probe and shovel
##
## Design Philosophy:
## - Gear sounds are grounded and realistic
## - Metal on rock/ice is distinctive
## - Rope sounds indicate tension and safety
##
## Nothing here is told to play: it watches the systems that do the work (the
## rope service, the rappel, the slide, the climber's hands on straps and
## bindings) and makes the sound of what they are doing.

# =============================================================================
# CONFIGURATION
# =============================================================================

## Audio bus for gear sounds
const GEAR_BUS := "Effects"

## Base volumes
const VOLUME_QUIET := -16.0
const VOLUME_NORMAL := -10.0
const VOLUME_LOUD := -5.0

## Seconds between the sounds of an anchor being built, of threading the rope,
## of flicking a snagged rope, of fiddling with straps
const PLACING_GAP := 4.5
const THREADING_GAP := 1.6
const FLICK_GAP := 1.2
const STRAP_GAP := 2.0

## Metres of rappel between two footfalls on the face
const RAPPEL_STEP := 1.3

## Rope speed (m/s) at which the rope sings through the device at full level
const ROPE_RUN_FULL := 2.5

## A snow pit: seconds between shovelfuls, and the last seconds are the taps
## of the column test
const DIG_GAP := 1.8
const TAP_TIME := 6.0
const TAP_GAP := 0.5

## Fraction of a crevasse wall climbed between two placements
const CLIMB_STEP := 0.07

# =============================================================================
# STATE
# =============================================================================

## Is initialized
var is_initialized: bool = false

var _service: AudioService
var _library: SoundLibrary
var _player: PlayerController
var _rope: RopeService
var _deployment: RopeDeploymentSystem
var _rappel: RappelController
var _slides: SlideSystem
var _crevasses: CrevasseSystem
var _avalanches: AvalancheSystem

## Looping textures: name -> AudioFader
var _loops: Dictionary = {}

var _work_timer: float = 0.0
var _flick_timer: float = 0.0
var _strap_timer: float = 0.0
var _rappel_metres: float = 0.0
var _last_descended: float = 0.0
var _stress_cooldown: float = 0.0

## What the hands were doing last frame, to hear it start and stop
var _gear_action: StringName = &""
var _gear_putting_on: bool = false
var _pit_active: bool = false
var _dig_timer: float = 0.0
var _tap_timer: float = 0.0
var _taps: int = 0
var _dig_progress: float = 0.0
var _probing: bool = false
var _climb_mark: float = 0.0
var _climb_axe_next: bool = true


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_library = ServiceLocator.get_service("SoundLibrary") as SoundLibrary
	_create_loops()
	_connect_signals()
	is_initialized = true
	print("[GearAudioManager] Initialized")


func _create_loops() -> void:
	_add_loop("rope_run", "rope_run_loop", -9.0)
	_add_loop("rope_pull", "rope_pull_loop", -11.0)
	_add_loop("axe_drag", "axe_drag_loop", -7.0)


func _add_loop(key: String, sound_id: String, trim_db: float) -> void:
	var player := AudioStreamPlayer.new()
	player.name = "Loop_" + key
	player.bus = GEAR_BUS
	if _library != null and _library.has_sound(sound_id):
		player.stream = _library.get_stream(sound_id)
	add_child(player)
	_loops[key] = AudioFader.new(player, trim_db, 0.15, 0.35)


func _connect_signals() -> void:
	ServiceLocator.get_service_async("AudioService", func(service): _service = service as AudioService)
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)
	ServiceLocator.get_service_async("RopeService", _on_rope_service_ready)
	ServiceLocator.get_service_async("RopeDeploymentSystem", _on_deployment_ready)
	ServiceLocator.get_service_async("RappelController", _on_rappel_ready)
	ServiceLocator.get_service_async("SlideSystem", _on_slide_system_ready)
	ServiceLocator.get_service_async("CrevasseSystem", _on_crevasse_system_ready)
	ServiceLocator.get_service_async("AvalancheSystem", _on_avalanche_system_ready)

	EventBus.rope_deployment_started.connect(_on_rope_deployment_started)
	EventBus.decision_recorded.connect(_on_decision)


func _on_player_ready(service: Object) -> void:
	_player = service as PlayerController
	if _player != null and not _player.footwear_changed.is_connected(_on_footwear_changed):
		_player.footwear_changed.connect(_on_footwear_changed)


func _on_rope_service_ready(service: Object) -> void:
	_rope = service as RopeService
	if _rope == null:
		return
	_rope.phase_changed.connect(_on_rope_phase_changed)
	_rope.recovery_complete.connect(_on_recovery_complete)


func _on_deployment_ready(service: Object) -> void:
	_deployment = service as RopeDeploymentSystem
	if _deployment == null:
		return
	_deployment.state_changed.connect(_on_deployment_state_changed)
	_deployment.deployment_failed.connect(_on_deployment_failed)


func _on_rappel_ready(service: Object) -> void:
	_rappel = service as RappelController
	if _rappel == null:
		return
	_rappel.rappel_started.connect(_on_rappel_started)
	_rappel.rappel_ended.connect(_on_rappel_ended)
	_rappel.rope_jam_occurred.connect(_on_rope_jam)
	_rappel.rope_jam_cleared.connect(_on_rope_jam_cleared)
	_rappel.rope_running_low.connect(_on_rope_running_low)
	_rappel.rope_end_reached.connect(_on_rope_end_reached)
	_rappel.anchor_stress_warning.connect(_on_anchor_stress)
	_rappel.terrain_contact.connect(_on_rappel_touchdown)


func _on_slide_system_ready(service: Object) -> void:
	_slides = service as SlideSystem
	if _slides == null:
		return
	_slides.self_arrest_started.connect(_on_self_arrest_started)
	_slides.self_arrest_engaged.connect(_on_self_arrest_engaged)
	_slides.self_arrest_failed.connect(_on_self_arrest_failed)


func _on_crevasse_system_ready(service: Object) -> void:
	_crevasses = service as CrevasseSystem
	if _crevasses != null:
		_crevasses.probed.connect(_on_probed)


func _on_avalanche_system_ready(service: Object) -> void:
	_avalanches = service as AvalancheSystem
	if _avalanches != null:
		_avalanches.pit_dug.connect(_on_pit_dug)


## Forget whatever was going on (the run ended)
func reset() -> void:
	for key in _loops.keys():
		var fader: AudioFader = _loops[key]
		fader.cut()
	_gear_action = &""
	_pit_active = false
	_probing = false
	_dig_progress = 0.0
	_climb_mark = 0.0


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_stress_cooldown = maxf(0.0, _stress_cooldown - delta)
	var playing := GameStateManager.current_state == GameEnums.GameState.DESCENT
	_update_rope(delta, playing)
	_update_axe(delta, playing)
	if not playing:
		return
	_update_anchor_work(delta)
	_update_gear_change(delta)
	_update_probe()
	_update_crevasse_climb()
	_update_pit(delta)
	_update_digging()


## Rope through the device on rappel, and through the anchor when pulled down
func _update_rope(delta: float, playing: bool) -> void:
	var run := 0.0
	var run_pitch := 1.0
	var pull := 0.0
	if playing and _rappel != null and is_instance_valid(_rappel) and _rappel.is_rappelling:
		var speed := absf(_rappel.current_speed)
		if not _rappel.is_jammed and not _rappel.at_rope_end:
			run = pow(clampf(speed / ROPE_RUN_FULL, 0.0, 1.0), 0.8)
			run_pitch = 0.8 + 0.25 * speed
		_update_rappel_steps()
		if _rappel.is_jammed:
			# Working it free: a flick of the rope every second or so
			_flick_timer -= delta
			if _flick_timer <= 0.0:
				_flick_timer = FLICK_GAP * AudioService.roll_range(0.8, 1.3)
				_play("rope_flick", VOLUME_NORMAL)
	if playing and _rope != null and is_instance_valid(_rope) and _rope.phase == RopeService.RopePhase.PULLING:
		pull = 1.0
	_set_loop("rope_run", run, run_pitch, delta)
	_set_loop("rope_pull", pull, 1.0, delta)


## Boots finding the face on the way down
func _update_rappel_steps() -> void:
	var descended := _rappel.distance_descended
	_rappel_metres += absf(descended - _last_descended)
	_last_descended = descended
	if _rappel_metres < RAPPEL_STEP:
		return
	_rappel_metres = 0.0
	var surface := GameEnums.SurfaceType.ROCK_DRY
	if _player != null and _player.current_cell != null:
		surface = _player.current_cell.surface_type
	var id := "footstep_rock"
	if _player != null and _player.footwear == GameEnums.Footwear.CRAMPONS:
		id = "crampon_ice" if surface == GameEnums.SurfaceType.ICE or TractionModel.is_snow(surface) else "crampon_rock"
	elif surface == GameEnums.SurfaceType.ICE:
		id = "footstep_ice"
	elif TractionModel.is_snow(surface):
		id = "footstep_snow_firm"
	_play(id, VOLUME_QUIET, AudioService.vary(0.08), AudioService.BUS_PLAYER)


## The pick dragging: braking a glissade, and a self-arrest biting
func _update_axe(delta: float, playing: bool) -> void:
	var drag := 0.0
	var pitch := 1.0
	if playing and _slides != null and is_instance_valid(_slides) and _slides.is_sliding and _slides.current_state != null:
		var speed: float = _slides.current_state.speed
		var moving := clampf(speed / 7.0, 0.0, 1.0)
		if _slides.arrest_engaged:
			drag = maxf(moving, 0.25)
		elif _slides.controller != null:
			drag = clampf(_slides.controller.get_brake_level(), 0.0, 1.0) * moving * 0.7
		pitch = 0.8 + 0.035 * minf(speed, 14.0)
	_set_loop("axe_drag", drag, pitch, delta)


func _set_loop(key: String, level: float, pitch: float, delta: float) -> void:
	var fader: AudioFader = _loops[key]
	fader.level = level
	fader.pitch = pitch
	fader.update(delta)


## Building an anchor takes a while: keep hearing the work
func _update_anchor_work(delta: float) -> void:
	if _deployment == null or not is_instance_valid(_deployment) or not _deployment.is_deploying:
		return
	_work_timer -= delta
	if _work_timer > 0.0:
		return
	match _deployment.current_state:
		RopeDeploymentSystem.DeploymentState.PLACING:
			_work_timer = PLACING_GAP * AudioService.roll_range(0.8, 1.2)
			_play_anchor_work()
		RopeDeploymentSystem.DeploymentState.THREADING:
			_work_timer = THREADING_GAP * AudioService.roll_range(0.85, 1.2)
			_play("rope_thread", VOLUME_NORMAL)


## Straps and bindings: the hands are busy for several seconds
func _update_gear_change(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var action := _player.gear_action
	if action != _gear_action:
		if action != &"":
			# Starting: the gear comes off the pack
			_gear_putting_on = (_player.footwear != GameEnums.Footwear.CRAMPONS) if action == &"crampons" \
				else not _player.is_on_skis()
			_strap_timer = 1.4
			if action == &"crampons":
				_play("crampon_clank", VOLUME_NORMAL)
			elif _gear_putting_on:
				_play("pack_zip", VOLUME_QUIET)
				_later(0.7, "ski_drop", VOLUME_NORMAL)
			else:
				_play("cloth_rustle", VOLUME_QUIET)
		_gear_action = action
	if action == &"":
		return
	_strap_timer -= delta
	if _strap_timer <= 0.0:
		_strap_timer = STRAP_GAP * AudioService.roll_range(0.8, 1.3)
		if action == &"crampons":
			_play("strap_pull" if _gear_putting_on else "crampon_clank", VOLUME_QUIET)
		else:
			_play("cloth_rustle", VOLUME_QUIET, AudioService.vary(0.08), AudioService.BUS_PLAYER)


## The shaft going in; what it found comes with the probed signal
func _update_probe() -> void:
	if _crevasses == null or not is_instance_valid(_crevasses):
		return
	var probing := _crevasses.probe_timer >= 0.0
	if probing and not _probing:
		_play("axe_plant", VOLUME_QUIET)
	_probing = probing


## Out of a crevasse one placement at a time: pick, then points, then pick
func _update_crevasse_climb() -> void:
	if _crevasses == null or not is_instance_valid(_crevasses) or not _crevasses.climbing:
		_climb_mark = 0.0
		return
	if _crevasses.climb_progress < _climb_mark:
		_climb_mark = _crevasses.climb_progress
	if _crevasses.climb_progress - _climb_mark < CLIMB_STEP:
		return
	_climb_mark = _crevasses.climb_progress
	if _climb_axe_next:
		_play("axe_ice", VOLUME_NORMAL)
		_later(0.35, "ice_chips", VOLUME_QUIET)
	else:
		_play("crampon_ice", VOLUME_NORMAL, AudioService.vary(0.08), AudioService.BUS_PLAYER)
	_climb_axe_next = not _climb_axe_next


## A snow pit: shovelfuls, then the taps of the column test
func _update_pit(delta: float) -> void:
	if _avalanches == null or not is_instance_valid(_avalanches):
		return
	var remaining := _avalanches.pit_timer
	var active := remaining >= 0.0
	if active and not _pit_active:
		_dig_timer = 0.3
		_tap_timer = 0.0
		_taps = 0
		_play("pack_zip", VOLUME_QUIET)
	_pit_active = active
	if not active:
		return
	if remaining > TAP_TIME:
		_dig_timer -= delta
		if _dig_timer <= 0.0:
			_dig_timer = DIG_GAP * AudioService.roll_range(0.85, 1.2)
			_play("shovel_dig", VOLUME_NORMAL)
	else:
		# Ten from the wrist, ten from the elbow, ten from the shoulder: harder each time
		_tap_timer -= delta
		if _tap_timer <= 0.0:
			_tap_timer = TAP_GAP
			var force := float(_taps) / 12.0
			_play("pit_tap", lerpf(-14.0, -5.0, clampf(force, 0.0, 1.0)), 0.95 + 0.1 * force)
			_taps += 1


## Buried: every stroke of digging is heard, close and muffled
func _update_digging() -> void:
	if _avalanches == null or not is_instance_valid(_avalanches) or not _avalanches.is_buried():
		_dig_progress = 0.0
		return
	if _avalanches.dig_progress > _dig_progress:
		_play("snow_scrabble", -6.0, AudioService.vary(0.1), AudioService.BUS_PLAYER)
	_dig_progress = _avalanches.dig_progress


# =============================================================================
# PLAYBACK
# =============================================================================

func _play(id: String, volume_db: float = VOLUME_NORMAL, pitch: float = -1.0, bus: String = GEAR_BUS) -> void:
	if _service == null:
		return
	_service.play(id, volume_db, AudioService.vary(0.05) if pitch < 0.0 else pitch, bus)


func _later(delay: float, id: String, volume_db: float = VOLUME_NORMAL) -> void:
	if _service != null:
		_service.play_later(delay, id, volume_db, AudioService.vary(0.05), GEAR_BUS)


## Play a gear sound at a 3D position
func play_sound_3d(sound_name: String, position: Vector3) -> void:
	if _service != null:
		_service.play_at(sound_name, position, VOLUME_NORMAL, AudioService.vary(0.05))


## Play a gear sound (2D, no position)
func play_sound(sound_name: String) -> void:
	_play(sound_name)


## Play rope deployment sound
func play_rope_deploy(position: Vector3) -> void:
	play_sound_3d("rope_uncoil", position)


## Play rope catch sound (when rope stops fall)
func play_rope_catch(position: Vector3) -> void:
	play_sound_3d("rope_jam", position)


## Play ice axe strike
func play_axe_strike(position: Vector3, surface: GameEnums.SurfaceType) -> void:
	play_sound_3d("axe_ice" if surface == GameEnums.SurfaceType.ICE else "axe_rock", position)


## Play self-arrest sound
func play_self_arrest(position: Vector3) -> void:
	play_sound_3d("axe_bite", position)


## Play crampon step
func play_crampon_step(position: Vector3, surface: GameEnums.SurfaceType) -> void:
	play_sound_3d("crampon_ice" if surface == GameEnums.SurfaceType.ICE else "crampon_rock", position)


## Play carabiner clip
func play_carabiner_clip(position: Vector3) -> void:
	play_sound_3d("carabiner_clip", position)


## Play gear rustle
func play_gear_rustle() -> void:
	_play("cloth_rustle", VOLUME_QUIET)


# =============================================================================
# ROPE WORK
# =============================================================================

func _on_rope_deployment_started(_quality: GameEnums.AnchorQuality) -> void:
	# The rope comes out of the pack and is flaked out
	_play("pack_zip", VOLUME_QUIET)
	_later(0.5, "rope_uncoil", VOLUME_NORMAL)


func _on_deployment_state_changed(_old_state: RopeDeploymentSystem.DeploymentState, new_state: RopeDeploymentSystem.DeploymentState) -> void:
	match new_state:
		RopeDeploymentSystem.DeploymentState.PLACING:
			_work_timer = 1.4
		RopeDeploymentSystem.DeploymentState.TESTING:
			# Weight on it
			_play("rope_tug", VOLUME_NORMAL)
		RopeDeploymentSystem.DeploymentState.THREADING:
			_work_timer = 0.2
		RopeDeploymentSystem.DeploymentState.READY:
			# Ends thrown clear, device clipped in
			_play("rope_throw", VOLUME_NORMAL)
			_later(1.0, "carabiner_clip", VOLUME_NORMAL)
		RopeDeploymentSystem.DeploymentState.ABORTING:
			_play("carabiner_unclip", VOLUME_NORMAL)
			_later(0.4, "gear_jingle", VOLUME_QUIET)


## The sound of the anchor being built, by what it is built from
func _play_anchor_work() -> void:
	var anchor := _deployment.selected_anchor
	if anchor == null:
		_play("gear_jingle", VOLUME_QUIET)
		return
	match anchor.anchor_type:
		AnchorPoint.AnchorType.ROCK_CRACK:
			_play("anchor_rock", VOLUME_NORMAL)
		AnchorPoint.AnchorType.ICE_SCREW, AnchorPoint.AnchorType.V_THREAD:
			_play("anchor_ice", VOLUME_NORMAL)
		AnchorPoint.AnchorType.SNOW_STAKE, AnchorPoint.AnchorType.SNOW_BOLLARD:
			_play("anchor_snow", VOLUME_NORMAL)
		AnchorPoint.AnchorType.FIXED_ANCHOR:
			_play("gear_jingle", VOLUME_QUIET)
			_later(0.5, "carabiner_clip", VOLUME_NORMAL)
		AnchorPoint.AnchorType.TREE:
			_play("sling_swish", VOLUME_NORMAL)
			_later(0.5, "rope_creak", VOLUME_QUIET)
		_:
			# A sling round a horn or a boulder
			_play("sling_swish", VOLUME_NORMAL)
			_later(0.6, "carabiner_clip", VOLUME_NORMAL)


func _on_deployment_failed(_reason: String) -> void:
	# It moved when weighted: stone grating, the gear swinging back
	_play("slip_rock", VOLUME_NORMAL)
	_later(0.3, "gear_jingle", VOLUME_QUIET)


func _on_rappel_started(_rope_used: Rope, _anchor: AnchorPoint) -> void:
	_last_descended = _rappel.distance_descended
	_rappel_metres = 0.0
	_flick_timer = 0.0
	# Weight onto the rope
	_play("rope_creak", VOLUME_NORMAL)


func _on_rappel_ended(outcome: RappelController.RappelOutcome) -> void:
	match outcome:
		RappelController.RappelOutcome.ANCHOR_FAILURE:
			_play("anchor_fail", -4.0, 1.0)
		RappelController.RappelOutcome.ROPE_END:
			pass  # The knot has already been heard
		_:
			_play("carabiner_unclip", VOLUME_NORMAL)


func _on_rope_jam() -> void:
	_play("rope_jam", VOLUME_LOUD)
	_flick_timer = 0.8


func _on_rope_jam_cleared() -> void:
	_play("rope_flick", VOLUME_NORMAL)
	_later(0.25, "rope_creak", VOLUME_QUIET)


func _on_rope_running_low(_remaining: float) -> void:
	_play("rope_creak", VOLUME_QUIET)


func _on_rope_end_reached() -> void:
	_play("rope_knot", VOLUME_LOUD)


## Rope tension as mechanical feedback: a loaded anchor is heard
func _on_anchor_stress(stress: float) -> void:
	if _stress_cooldown > 0.0:
		return
	_stress_cooldown = 2.2
	_play("rope_creak", lerpf(-14.0, -6.0, clampf(stress, 0.0, 1.0)))


func _on_rappel_touchdown(_position: Vector3) -> void:
	_play("gear_jingle", VOLUME_QUIET)


func _on_rope_phase_changed(_phase: RopeService.RopePhase) -> void:
	# The pull itself is the rope_pull loop (see _update_rope)
	pass


func _on_recovery_complete(success: bool, _rope_used: Rope) -> void:
	if success:
		# The end whips through and the whole length comes down
		_play("rope_fall", VOLUME_NORMAL)
	else:
		_play("rope_jam", VOLUME_LOUD)
		_later(0.4, "rope_creak", VOLUME_NORMAL)


# =============================================================================
# AXE, CRAMPONS, BINDINGS
# =============================================================================

func _on_self_arrest_started() -> void:
	# Rolling over onto the axe
	_play("cloth_rustle", VOLUME_NORMAL, AudioService.vary(0.08), AudioService.BUS_PLAYER)
	_play("reaction_effort", VOLUME_NORMAL, AudioService.vary(0.08), AudioService.BUS_PLAYER)


func _on_self_arrest_engaged() -> void:
	if _player != null and _player.has_ice_axe():
		_play("axe_bite", VOLUME_LOUD)
	else:
		# Hands and toes
		_play("slip_snow", VOLUME_NORMAL)


func _on_self_arrest_failed(_reason: String) -> void:
	_play("axe_ripped", -5.0, 1.0)


func _on_footwear_changed(_old: GameEnums.Footwear, new_footwear: GameEnums.Footwear) -> void:
	# Only a change the climber worked for is heard here. Skis torn off in an
	# avalanche or broken on rock, and the crampons a run starts with, are not
	if _gear_action == &"":
		return
	match new_footwear:
		GameEnums.Footwear.CRAMPONS:
			_play("strap_pull", VOLUME_NORMAL)
			_later(0.5, "crampon_snow", VOLUME_NORMAL)
		GameEnums.Footwear.SKIS:
			_play("binding_click", VOLUME_LOUD)
			_later(0.6, "binding_click", VOLUME_LOUD)
		GameEnums.Footwear.SNOWBOARD:
			_play("board_ratchet", VOLUME_NORMAL)
			_later(0.7, "board_ratchet", VOLUME_NORMAL)
		GameEnums.Footwear.BOOTS:
			if _gear_action == &"skis":
				_play("binding_release", VOLUME_LOUD)
				_later(0.5, "binding_release", VOLUME_LOUD)
			else:
				_play("crampon_clank", VOLUME_NORMAL)


# =============================================================================
# PROBE, PIT, AIRBAG
# =============================================================================

func _on_probed(found: bool) -> void:
	_play("probe_hollow" if found else "probe_firm", VOLUME_NORMAL)


## The column test's answer: ECTP fails clean across, ECTN cracks and stops
func _on_pit_dug(result: String) -> void:
	if result.begins_with("ECTP"):
		_play("column_fracture", VOLUME_LOUD)
	elif result.begins_with("ECTN"):
		_play("column_fracture", -14.0, 1.25)


func _on_decision(decision_type: String, _context: Dictionary) -> void:
	match decision_type:
		"airbag_deployed":
			_play("airbag_deploy", -5.0, 1.0, AudioService.BUS_PLAYER)
		"crevasse_climbed_out":
			_play("cloth_rustle", VOLUME_NORMAL, AudioService.vary(0.08), AudioService.BUS_PLAYER)
			_play("reaction_effort", VOLUME_NORMAL, AudioService.vary(0.08), AudioService.BUS_PLAYER)
