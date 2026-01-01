class_name FatalEventManager
extends Node
## Manages fatal event detection and phase-based death sequence
## The most ethically sensitive system in the game
##
## Design Philosophy:
## - "The camera does not look away—but it does not exploit."
## - The drone never confirms death
## - It only records loss of control
## - Death is inferred by absence of recovery
## - Watching someone disappear is more powerful than watching them impact

# =============================================================================
# SIGNALS
# =============================================================================

signal fatal_detected(trigger: FatalTrigger)
signal phase_started(phase: GameEnums.FatalPhase)
signal phase_completed(phase: GameEnums.FatalPhase)
signal fatal_sequence_complete()
signal point_of_no_return_reached(trigger: FatalTrigger)

# =============================================================================
# ENUMS
# =============================================================================

enum FatalTrigger {
	IMPACT,             # High-force impact
	FALL,               # Fall exceeds survival distance
	TERMINAL_SLIDE,     # No exit zone at terminal speed
	EXPOSURE,           # Cold/hypothermia
	ACCUMULATED_INJURY, # Injuries exceed survival threshold
	AVALANCHE,          # Caught in avalanche
	CREVASSE            # Fall into crevasse
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Detection Thresholds")
## Impact force that causes instant fatality (Gs)
@export var instant_death_impact: float = 50.0
## Fall distance that cannot be survived (meters)
@export var survival_fall_limit: float = 30.0
## Slide speed with no exit (m/s)
@export var terminal_slide_speed: float = 25.0
## Total injury severity that is fatal
@export var fatal_injury_threshold: float = 2.5

@export_group("Phase Timing")
## Duration of moment of error phase
@export var moment_of_error_duration: float = 1.5
## Duration of loss of control phase
@export var loss_of_control_duration: float = 4.0
## Duration of vanishing phase
@export var vanishing_duration: float = 3.0
## Duration of aftermath (silence)
@export var aftermath_duration: float = 6.0
## Duration of acknowledgment
@export var acknowledgment_duration: float = 5.0

@export_group("Ethical Options")
## Enable predictive fade for streaming
@export var predictive_fade_enabled: bool = true
## Replace fatal audio with wind only
@export var wind_only_audio: bool = false
## Delay replay of fatal moments
@export var delay_fatal_replay: bool = false

# =============================================================================
# STATE
# =============================================================================

## Current fatal phase
var current_phase: GameEnums.FatalPhase = GameEnums.FatalPhase.NONE

## Is a fatal event in progress
var is_fatal_active: bool = false

## The trigger that caused this fatal event
var active_trigger: FatalTrigger = FatalTrigger.IMPACT

## Time in current phase
var phase_timer: float = 0.0

## Player's last known position
var last_known_position: Vector3 = Vector3.ZERO

## Player's last known velocity
var last_known_velocity: Vector3 = Vector3.ZERO

## Point of no return detected
var point_of_no_return: bool = false

## Phase handlers
var phase_handler: FatalPhaseHandler

## Ethical constraints
var ethical_constraints: EthicalConstraints

## Player reference
var player: PlayerController

## Camera director reference
var camera_director: CameraDirector


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("FatalEventManager", self)

	# Get references
	ServiceLocator.get_service_async("PlayerController", func(p): player = p)
	ServiceLocator.get_service_async("CameraDirector", func(c): camera_director = c)

	# Create sub-components
	phase_handler = FatalPhaseHandler.new()
	add_child(phase_handler)
	phase_handler.phase_action_complete.connect(_on_phase_action_complete)

	ethical_constraints = EthicalConstraints.new()
	add_child(ethical_constraints)

	_connect_events()
	print("[FatalEventManager] Initialized - Witness without harm")


func _connect_events() -> void:
	# Player condition events
	EventBus.injury_occurred.connect(_on_injury)
	EventBus.body_state_updated.connect(_on_body_state_updated)
	EventBus.player_position_updated.connect(_on_player_position_updated)

	# Slide events
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.slide_state_updated.connect(_on_slide_state_updated)

	# Terrain events
	EventBus.cliff_proximity_changed.connect(_on_cliff_proximity)

	# Game state
	EventBus.game_state_changed.connect(_on_game_state_changed)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_fatal_active:
		_check_for_fatal_conditions()
		return

	phase_timer += delta

	if _is_phase_complete():
		_advance_phase()


func _check_for_fatal_conditions() -> void:
	if player == null:
		return

	# Check for point of no return (pre-fatal detection)
	if not point_of_no_return:
		_check_point_of_no_return()


func _check_point_of_no_return() -> void:
	if player == null or player.body_state == null:
		return

	var ponr_detected := false
	var trigger := FatalTrigger.IMPACT

	# Terminal slide with no exit
	if player.movement_state == GameEnums.PlayerMovementState.SLIDING:
		var speed := player.smooth_velocity.length()
		if speed > terminal_slide_speed * 0.8:
			# Check for exit zones (would need terrain system)
			# For now, use cliff proximity as indicator
			var cliff_dist := _get_cliff_distance()
			if cliff_dist < 5.0:
				ponr_detected = true
				trigger = FatalTrigger.TERMINAL_SLIDE

	# Critical exposure
	if player.body_state.cold_exposure >= 0.9:
		ponr_detected = true
		trigger = FatalTrigger.EXPOSURE

	# Accumulated injury
	var total_injury := _calculate_total_injury()
	if total_injury > fatal_injury_threshold * 0.9:
		ponr_detected = true
		trigger = FatalTrigger.ACCUMULATED_INJURY

	if ponr_detected and not point_of_no_return:
		point_of_no_return = true
		point_of_no_return_reached.emit(trigger)
		EventBus.point_of_no_return_detected.emit()

		# Start predictive fade if enabled
		if predictive_fade_enabled and ethical_constraints:
			ethical_constraints.begin_predictive_fade()


func _get_cliff_distance() -> float:
	var signal_detector := ServiceLocator.get_service("SignalDetector") as SignalDetector
	if signal_detector:
		return signal_detector.get_cliff_distance()
	return INF


func _calculate_total_injury() -> float:
	if player == null or player.body_state == null:
		return 0.0

	var total := 0.0
	for injury in player.body_state.injuries:
		total += injury.severity
	return total


# =============================================================================
# FATAL DETECTION
# =============================================================================

## Detect impact fatality
func check_impact_fatal(impact_force: float, position: Vector3) -> void:
	if impact_force >= instant_death_impact:
		_trigger_fatal(FatalTrigger.IMPACT, position)


## Detect fall fatality
func check_fall_fatal(fall_distance: float, position: Vector3) -> void:
	if fall_distance >= survival_fall_limit:
		_trigger_fatal(FatalTrigger.FALL, position)


## Detect terminal slide fatality
func check_slide_fatal(speed: float, has_exit: bool, position: Vector3) -> void:
	if speed >= terminal_slide_speed and not has_exit:
		_trigger_fatal(FatalTrigger.TERMINAL_SLIDE, position)


## Detect exposure fatality
func check_exposure_fatal(cold_level: float) -> void:
	if cold_level >= 1.0:
		_trigger_fatal(FatalTrigger.EXPOSURE, last_known_position)


## Detect injury fatality
func check_injury_fatal(total_severity: float) -> void:
	if total_severity >= fatal_injury_threshold:
		_trigger_fatal(FatalTrigger.ACCUMULATED_INJURY, last_known_position)


## Main fatal trigger
func _trigger_fatal(trigger: FatalTrigger, position: Vector3) -> void:
	if is_fatal_active:
		return

	is_fatal_active = true
	active_trigger = trigger
	last_known_position = position

	if player:
		last_known_velocity = player.smooth_velocity

	fatal_detected.emit(trigger)
	_start_phase(GameEnums.FatalPhase.MOMENT_OF_ERROR)

	print("[FatalEventManager] Fatal event triggered: %s" % FatalTrigger.keys()[trigger])


# =============================================================================
# PHASE MANAGEMENT
# =============================================================================

func _start_phase(phase: GameEnums.FatalPhase) -> void:
	var old_phase := current_phase
	current_phase = phase
	phase_timer = 0.0

	phase_started.emit(phase)
	EventBus.fatal_phase_changed.emit(old_phase, phase)

	if phase == GameEnums.FatalPhase.MOMENT_OF_ERROR:
		EventBus.fatal_event_started.emit(phase)

	# Execute phase-specific actions
	phase_handler.execute_phase(phase, active_trigger, last_known_position)

	# Notify ethical constraints
	ethical_constraints.on_phase_changed(phase)

	print("[FatalEventManager] Phase: %s" % GameEnums.FatalPhase.keys()[phase])


func _is_phase_complete() -> bool:
	match current_phase:
		GameEnums.FatalPhase.MOMENT_OF_ERROR:
			return phase_timer >= moment_of_error_duration
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			return phase_timer >= loss_of_control_duration
		GameEnums.FatalPhase.VANISHING:
			return phase_timer >= vanishing_duration
		GameEnums.FatalPhase.AFTERMATH:
			return phase_timer >= aftermath_duration
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			return phase_timer >= acknowledgment_duration
		_:
			return false


func _advance_phase() -> void:
	phase_completed.emit(current_phase)

	match current_phase:
		GameEnums.FatalPhase.MOMENT_OF_ERROR:
			_start_phase(GameEnums.FatalPhase.LOSS_OF_CONTROL)
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			_start_phase(GameEnums.FatalPhase.VANISHING)
		GameEnums.FatalPhase.VANISHING:
			_start_phase(GameEnums.FatalPhase.AFTERMATH)
		GameEnums.FatalPhase.AFTERMATH:
			_start_phase(GameEnums.FatalPhase.ACKNOWLEDGMENT)
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			_complete_fatal_sequence()


func _complete_fatal_sequence() -> void:
	current_phase = GameEnums.FatalPhase.NONE
	is_fatal_active = false
	point_of_no_return = false

	fatal_sequence_complete.emit()
	EventBus.fatal_event_completed.emit()

	# Trigger run end
	EventBus.run_ended.emit(null, GameEnums.ResolutionType.FATALITY)

	print("[FatalEventManager] Fatal sequence complete")


func _on_phase_action_complete() -> void:
	# Phase handler finished its work, continue
	pass


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_injury(injury: Injury) -> void:
	var total := _calculate_total_injury()
	check_injury_fatal(total)


func _on_body_state_updated(body_state: BodyState) -> void:
	if body_state:
		check_exposure_fatal(body_state.cold_exposure)


func _on_player_position_updated(position: Vector3, velocity: Vector3) -> void:
	if not is_fatal_active:
		last_known_position = position
		last_known_velocity = velocity


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	if outcome == GameEnums.SlideOutcome.TERMINAL_RUNOUT:
		_trigger_fatal(FatalTrigger.TERMINAL_SLIDE, last_known_position)


func _on_slide_state_updated(control_level: float, speed: float, trajectory: Vector3) -> void:
	# Continuous check during slide
	if speed > terminal_slide_speed:
		var cliff_dist := _get_cliff_distance()
		if cliff_dist < 3.0:
			check_slide_fatal(speed, false, last_known_position)


func _on_cliff_proximity(distance: float) -> void:
	# Track for fatal detection
	pass


func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	if new_state == GameEnums.GameState.MAIN_MENU:
		_reset()


func _reset() -> void:
	is_fatal_active = false
	current_phase = GameEnums.FatalPhase.NONE
	point_of_no_return = false
	phase_timer = 0.0


# =============================================================================
# QUERIES
# =============================================================================

func is_in_fatal_sequence() -> bool:
	return is_fatal_active


func get_current_phase() -> GameEnums.FatalPhase:
	return current_phase


func get_phase_progress() -> float:
	var duration := _get_phase_duration(current_phase)
	if duration <= 0:
		return 0.0
	return clampf(phase_timer / duration, 0.0, 1.0)


func _get_phase_duration(phase: GameEnums.FatalPhase) -> float:
	match phase:
		GameEnums.FatalPhase.MOMENT_OF_ERROR:
			return moment_of_error_duration
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			return loss_of_control_duration
		GameEnums.FatalPhase.VANISHING:
			return vanishing_duration
		GameEnums.FatalPhase.AFTERMATH:
			return aftermath_duration
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			return acknowledgment_duration
		_:
			return 0.0


func get_summary() -> Dictionary:
	return {
		"is_active": is_fatal_active,
		"phase": GameEnums.FatalPhase.keys()[current_phase],
		"phase_progress": get_phase_progress(),
		"trigger": FatalTrigger.keys()[active_trigger] if is_fatal_active else "none",
		"point_of_no_return": point_of_no_return,
		"last_position": last_known_position
	}
