class_name FatalPhaseHandler
extends Node
## Executes phase-specific behaviors during fatal events
## Each phase has distinct camera, audio, and visual responses
##
## Phase Design:
## 1. Moment of Error - Human shock, hesitation
## 2. Loss of Control - Scale over proximity, drift upward
## 3. Vanishing - Subject lost behind terrain, wind overtakes
## 4. Aftermath - Stillness, absence, wind continues
## 5. Acknowledgment - Slow reveal, mountain remains

# =============================================================================
# SIGNALS
# =============================================================================

signal phase_action_complete()
signal camera_instruction(instruction: CameraInstruction)
signal audio_instruction(instruction: AudioInstruction)

# =============================================================================
# INSTRUCTION CLASSES
# =============================================================================

class CameraInstruction:
	var action: String
	var target_position: Vector3
	var duration: float
	var params: Dictionary

	func _init(a: String, pos: Vector3 = Vector3.ZERO, dur: float = 1.0, p: Dictionary = {}):
		action = a
		target_position = pos
		duration = dur
		params = p


class AudioInstruction:
	var action: String
	var target_volume: float
	var duration: float
	var params: Dictionary

	func _init(a: String, vol: float = 1.0, dur: float = 1.0, p: Dictionary = {}):
		action = a
		target_volume = vol
		duration = dur
		params = p


# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Moment of Error")
## Hesitation delay before camera responds
@export var hesitation_delay: float = 0.3
## Framing error magnitude
@export var framing_error: float = 0.15

@export_group("Loss of Control")
## How far camera drifts upward
@export var upward_drift: float = 5.0
## How much camera pulls back
@export var pullback_distance: float = 10.0

@export_group("Vanishing")
## How much drone slows
@export var drone_slow_factor: float = 0.3
## Wind audio crossfade duration
@export var wind_crossfade: float = 2.0

@export_group("Aftermath")
## Minimum silence duration
@export var silence_duration: float = 4.0

@export_group("Acknowledgment")
## Final ascent height
@export var ascent_height: float = 20.0
## Reveal pullback distance
@export var reveal_distance: float = 30.0

# =============================================================================
# STATE
# =============================================================================

## Current phase being executed
var current_phase: GameEnums.FatalPhase = GameEnums.FatalPhase.NONE

## Current trigger type
var trigger_type: FatalEventManager.FatalTrigger

## Event position
var event_position: Vector3 = Vector3.ZERO

## Phase execution state
var phase_state: Dictionary = {}

## Service references
var drone_service: DroneService
var audio_service: AudioService
var camera_director: CameraDirector


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("DroneService", func(s): drone_service = s)
	ServiceLocator.get_service_async("AudioService", func(s): audio_service = s)
	ServiceLocator.get_service_async("CameraDirector", func(c): camera_director = c)


# =============================================================================
# PHASE EXECUTION
# =============================================================================

func execute_phase(phase: GameEnums.FatalPhase, trigger: FatalEventManager.FatalTrigger, position: Vector3) -> void:
	current_phase = phase
	trigger_type = trigger
	event_position = position
	phase_state.clear()

	match phase:
		GameEnums.FatalPhase.MOMENT_OF_ERROR:
			_execute_moment_of_error()
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			_execute_loss_of_control()
		GameEnums.FatalPhase.VANISHING:
			_execute_vanishing()
		GameEnums.FatalPhase.AFTERMATH:
			_execute_aftermath()
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			_execute_acknowledgment()


# =============================================================================
# PHASE 1: MOMENT OF ERROR
# =============================================================================

func _execute_moment_of_error() -> void:
	## "AI hesitates, micro-delay. Slight framing error (human shock).
	## Medium-wide shot, player not centered. Terrain dominates frame."

	# Camera hesitates
	_emit_camera(CameraInstruction.new(
		"hesitate",
		event_position,
		hesitation_delay,
		{
			"framing_offset": Vector2(randf_range(-framing_error, framing_error), randf_range(-framing_error, framing_error)),
			"shot_type": "medium_wide",
			"center_subject": false
		}
	))

	# Audio: subtle compression, hint of wrongness
	_emit_audio(AudioInstruction.new(
		"compress",
		0.8,
		0.5,
		{"frequency_cut": 0.9}
	))

	# Inform camera director
	if camera_director:
		camera_director.call_consequence_shot("fatal_moment_of_error")

	# Drone behavior
	if drone_service:
		drone_service.hesitate(hesitation_delay)

	phase_action_complete.emit()


# =============================================================================
# PHASE 2: LOSS OF CONTROL
# =============================================================================

func _execute_loss_of_control() -> void:
	## "No zoom-in, no frantic chase. Drone chooses scale over proximity.
	## Lateral tracking or static wide. Camera drifts upward, not downward.
	## Message: 'This is bigger than them now'"

	var upward_target := event_position + Vector3(0, upward_drift, 0)
	var pullback_target := event_position + Vector3(0, upward_drift, pullback_distance)

	# Camera pulls back and up - never closer
	_emit_camera(CameraInstruction.new(
		"drift_upward",
		pullback_target,
		3.0,
		{
			"shot_type": "wide",
			"tracking": "lateral",
			"zoom_direction": "out",  # NEVER in
			"speed": 0.3  # Slow, contemplative
		}
	))

	# Audio: wind begins to dominate
	_emit_audio(AudioInstruction.new(
		"wind_rise",
		1.0,
		2.0,
		{"motor_fade": 0.5}
	))

	# Drone pulls back
	if drone_service and drone_service.drone:
		var controller := drone_service.drone.controller
		if controller:
			controller.set_target_position(pullback_target, 0.3)
			controller.is_orbiting = false  # Stop orbiting

	# Camera director: consequence, not action
	if camera_director:
		camera_director.call_consequence_shot("fatal_loss_of_control")
		camera_director.start_sequence("fatal_sequence")

	phase_action_complete.emit()


# =============================================================================
# PHASE 3: THE VANISHING
# =============================================================================

func _execute_vanishing() -> void:
	## "Drone does not follow into abyss. Slows, loses subject behind terrain.
	## Wind noise overtakes motor. Framing: empty slope, moving snow, no body."

	# Camera slows dramatically
	_emit_camera(CameraInstruction.new(
		"slow_stop",
		event_position,
		vanishing_duration,
		{
			"speed_factor": drone_slow_factor,
			"follow_subject": false,  # CRITICAL: stop following
			"frame_terrain": true,    # Frame where they were, not where they are
			"lose_subject": true
		}
	))

	# Audio: wind overtakes everything
	_emit_audio(AudioInstruction.new(
		"wind_overtake",
		1.0,
		wind_crossfade,
		{
			"motor_volume": 0.1,
			"breathing_volume": 0.0,  # Subject audio fades
			"wind_intensity": 1.0
		}
	))

	# Drone behavior
	if drone_service and drone_service.drone:
		# Slow drone dramatically
		drone_service.drone.movement_speed *= drone_slow_factor

		# Stop tracking subject
		drone_service.filming_subject = null

		# Frame empty terrain
		if drone_service.drone_camera:
			drone_service.drone_camera.lose_subject()

	# Request audio duck
	EventBus.audio_duck_requested.emit("fatal_vanishing")

	phase_action_complete.emit()


# =============================================================================
# PHASE 4: AFTERMATH
# =============================================================================

func _execute_aftermath() -> void:
	## "Drone holds position. No music, no motion for several seconds.
	## Wind continues, snow settles.
	## THIS IS ONE OF THE MOST IMPORTANT MOMENTS IN THE GAME"

	# Camera holds absolutely still
	_emit_camera(CameraInstruction.new(
		"hold",
		Vector3.ZERO,  # Don't move
		silence_duration,
		{
			"motion": false,
			"stabilization": "maximum",
			"frame_empty_terrain": true
		}
	))

	# Audio: wind only, complete silence otherwise
	_emit_audio(AudioInstruction.new(
		"wind_only",
		1.0,
		0.5,
		{
			"music": false,
			"motor": false,
			"breathing": false,
			"wind": true,
			"ambient_creak": true  # Snow settling
		}
	))

	# Drone holds position
	if drone_service and drone_service.drone:
		drone_service.drone.controller.hold_position()

	# Camera director: release, let it breathe
	if camera_director:
		camera_director.call_release_shot("fatal_aftermath")

	# Emit silence moment for audio coordination
	EventBus.silence_moment.emit(true)

	phase_action_complete.emit()


# =============================================================================
# PHASE 5: ACKNOWLEDGMENT
# =============================================================================

func _execute_acknowledgment() -> void:
	## "Drone slowly ascends, pulls back. Reveals terrain enormity.
	## No text, no marker, no body. THE MOUNTAIN REMAINS."

	var ascent_target := event_position + Vector3(0, ascent_height, -reveal_distance)

	# Camera slowly reveals the scale
	_emit_camera(CameraInstruction.new(
		"reveal_ascent",
		ascent_target,
		acknowledgment_duration,
		{
			"motion": "slow_crane_up",
			"reveal": true,
			"frame": "mountain_scale",
			"no_subject": true
		}
	))

	# Audio: wind continues, very subtle fade
	_emit_audio(AudioInstruction.new(
		"fade_ambient",
		0.7,
		acknowledgment_duration,
		{
			"wind_fade": 0.8,
			"prepare_transition": true
		}
	))

	# Drone ascends
	if drone_service and drone_service.drone:
		var controller := drone_service.drone.controller
		if controller:
			controller.set_target_position(ascent_target, 0.2)  # Very slow

	# Camera director: context, show the mountain
	if camera_director:
		camera_director.call_context_shot("fatal_acknowledgment")
		camera_director.end_sequence()

	# End silence moment
	EventBus.silence_moment.emit(false)

	phase_action_complete.emit()


# =============================================================================
# INSTRUCTION EMISSION
# =============================================================================

func _emit_camera(instruction: CameraInstruction) -> void:
	camera_instruction.emit(instruction)

	# Apply to drone camera if available
	if drone_service and drone_service.drone_camera:
		_apply_camera_instruction(instruction)


func _emit_audio(instruction: AudioInstruction) -> void:
	audio_instruction.emit(instruction)

	# Apply to audio service if available
	if audio_service:
		_apply_audio_instruction(instruction)


func _apply_camera_instruction(instr: CameraInstruction) -> void:
	var camera := drone_service.drone_camera
	if camera == null:
		return

	match instr.action:
		"hesitate":
			# Apply framing error
			camera.add_framing_offset(instr.params.get("framing_offset", Vector2.ZERO))

		"drift_upward":
			# Set wide shot
			camera.set_shot_intent(GameEnums.ShotIntent.CONTEXT)

		"slow_stop":
			# Stop following subject
			if instr.params.get("follow_subject", true) == false:
				camera.lose_subject()

		"hold":
			# Maximum stabilization
			camera.rotation_smoothing = 20.0

		"reveal_ascent":
			# Prepare for final shot
			camera.set_shot_intent(GameEnums.ShotIntent.RELEASE)


func _apply_audio_instruction(instr: AudioInstruction) -> void:
	match instr.action:
		"compress":
			EventBus.audio_duck_requested.emit("fatal_compress")

		"wind_rise":
			EventBus.wind_audio_changed.emit(0.8)

		"wind_overtake":
			EventBus.wind_audio_changed.emit(1.0)
			EventBus.breathing_changed.emit(0.0)

		"wind_only":
			# This is the silence
			pass

		"fade_ambient":
			EventBus.audio_restore_requested.emit()


# =============================================================================
# TRIGGER-SPECIFIC BEHAVIORS
# =============================================================================

## Get additional camera parameters based on trigger type
func get_trigger_camera_params(trigger: FatalEventManager.FatalTrigger) -> Dictionary:
	match trigger:
		FatalEventManager.FatalTrigger.FALL:
			return {
				"tilt": "down_then_up",  # Don't follow into void
				"speed": "slow"
			}

		FatalEventManager.FatalTrigger.TERMINAL_SLIDE:
			return {
				"tracking": "lateral",
				"lead_subject": false  # Trail, don't lead
			}

		FatalEventManager.FatalTrigger.EXPOSURE:
			return {
				"motion": "minimal",
				"stillness": true
			}

		FatalEventManager.FatalTrigger.AVALANCHE:
			return {
				"retreat": true,
				"frame_debris": false
			}

		_:
			return {}


# =============================================================================
# PROHIBITED BEHAVIORS CHECK
# =============================================================================

## Verify camera behavior is ethical
## Returns false if behavior would violate ethical constraints
func is_behavior_permitted(action: String, params: Dictionary) -> bool:
	# NEVER zoom in during fatal events
	if action == "zoom" and params.get("direction") == "in":
		return false

	# NEVER follow into voids
	if action == "follow" and params.get("into_void", false):
		return false

	# NEVER circle stopped body
	if action == "orbit" and current_phase in [
		GameEnums.FatalPhase.AFTERMATH,
		GameEnums.FatalPhase.ACKNOWLEDGMENT
	]:
		return false

	# NEVER hover directly overhead
	if action == "position" and params.get("overhead", false):
		return false

	# NEVER reframe to show body
	if action == "reframe" and params.get("show_body", false):
		return false

	return true
