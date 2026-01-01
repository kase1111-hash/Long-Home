class_name CameraDirector
extends Node
## The "brain" of the cinematic camera system
## Coordinates all camera decisions like a documentary filmmaker
##
## Design Philosophy:
## - Thinks in shots, not frames
## - Anticipates action, doesn't just react
## - Has personality - sometimes late, sometimes perfect
## - Creates rhythm through shot selection
## - Respects the emotional arc of each moment

# =============================================================================
# SIGNALS
# =============================================================================

signal shot_started(intent: GameEnums.ShotIntent)
signal shot_ended(intent: GameEnums.ShotIntent, duration: float)
signal cut_executed(from_intent: GameEnums.ShotIntent, to_intent: GameEnums.ShotIntent)
signal director_decision(decision: String, reason: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Behavior")
## Enable AI-driven shot selection
@export var ai_enabled: bool = true
## How reactive the director is (0 = contemplative, 1 = reactive)
@export var reactivity: float = 0.6
## How much the director anticipates (0 = reactive, 1 = predictive)
@export var anticipation: float = 0.4

@export_group("Timing")
## Minimum shot duration
@export var min_shot_duration: float = 2.0
## Maximum shot duration
@export var max_shot_duration: float = 15.0
## Time to hold after major event
@export var event_hold_time: float = 3.0

@export_group("Imperfection")
## Enable human-like imperfection
@export var imperfection_enabled: bool = true
## Base chance to miss a shot
@export var miss_chance: float = 0.05
## Base chance to arrive late
@export var late_chance: float = 0.15
## Base chance to hesitate
@export var hesitate_chance: float = 0.1

# =============================================================================
# COMPONENTS
# =============================================================================

## Signal detector
var signal_detector: SignalDetector

## Intent selector
var intent_selector: IntentSelector

## Emotional rhythm engine
var rhythm_engine: EmotionalRhythmEngine

## Drone service
var drone_service: DroneService

# =============================================================================
# STATE
# =============================================================================

## Is director active
var is_active: bool = false

## Current shot start time
var shot_start_time: float = 0.0

## Current shot intent
var current_shot_intent: GameEnums.ShotIntent = GameEnums.ShotIntent.CONTEXT

## Shots executed this session
var shot_count: int = 0

## Decisions made this session
var decision_history: Array[Dictionary] = []

## Is currently executing a scripted sequence
var in_sequence: bool = false

## Pending imperfection
var pending_imperfection: String = ""
var imperfection_timer: float = 0.0

## Last significant event
var last_event_time: float = 0.0
var last_event_type: String = ""

## Subject velocity prediction
var predicted_velocity: Vector3 = Vector3.ZERO

## Last frame's subject position
var last_subject_position: Vector3 = Vector3.ZERO


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("CameraDirector", self)

	# Get component references
	ServiceLocator.get_service_async("SignalDetector", func(s): signal_detector = s)
	ServiceLocator.get_service_async("IntentSelector", func(s):
		intent_selector = s
		intent_selector.intent_changed.connect(_on_intent_changed)
	)
	ServiceLocator.get_service_async("EmotionalRhythmEngine", func(s): rhythm_engine = s)
	ServiceLocator.get_service_async("DroneService", func(s): drone_service = s)

	_connect_events()
	print("[CameraDirector] Initialized - The show begins")


func _connect_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.descent_ready.connect(_on_descent_ready)
	EventBus.run_ended.connect(_on_run_ended)

	# Major events that need director attention
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.fatal_event_started.connect(_on_fatal_event_started)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_active or not ai_enabled:
		return

	_update_prediction(delta)
	_process_imperfection(delta)
	_evaluate_shot(delta)
	_check_cut_opportunity()


func _update_prediction(delta: float) -> void:
	if drone_service == null or drone_service.filming_subject == null:
		return

	var current_pos := drone_service.filming_subject.global_position
	predicted_velocity = (current_pos - last_subject_position) / maxf(delta, 0.001)
	last_subject_position = current_pos


func _process_imperfection(delta: float) -> void:
	if not imperfection_enabled or pending_imperfection.is_empty():
		return

	imperfection_timer -= delta
	if imperfection_timer <= 0:
		_execute_imperfection()


func _evaluate_shot(delta: float) -> void:
	if in_sequence:
		return

	var shot_duration := Time.get_ticks_msec() / 1000.0 - shot_start_time

	# Get rhythm recommendations
	var recommended_duration := min_shot_duration
	if rhythm_engine:
		recommended_duration = rhythm_engine.get_recommended_shot_duration()

	# Check if shot has run its course
	if shot_duration > recommended_duration:
		if intent_selector and intent_selector.has_pending:
			# Let intent selector handle it
			pass
		elif shot_duration > max_shot_duration:
			# Force a change
			_record_decision("shot_timeout", "max_duration_exceeded")


func _check_cut_opportunity() -> void:
	if intent_selector == null or rhythm_engine == null:
		return

	# Check if a cut would be good right now
	var cut_recommended := rhythm_engine.is_cut_recommended()
	var intent_suggests_cut := intent_selector.should_cut()

	if cut_recommended and intent_suggests_cut:
		_execute_cut()


func _execute_cut() -> void:
	if drone_service == null:
		return

	var old_intent := current_shot_intent
	current_shot_intent = intent_selector.get_current_intent()

	# Maybe add imperfection
	if imperfection_enabled and randf() < late_chance:
		_queue_imperfection("late", randf_range(0.2, 0.5))

	# Execute the shot
	drone_service.set_shot_intent(current_shot_intent)

	shot_count += 1
	cut_executed.emit(old_intent, current_shot_intent)
	_record_decision("cut", "%s_to_%s" % [
		GameEnums.ShotIntent.keys()[old_intent],
		GameEnums.ShotIntent.keys()[current_shot_intent]
	])


# =============================================================================
# IMPERFECTION SYSTEM
# =============================================================================

func _queue_imperfection(type: String, delay: float) -> void:
	pending_imperfection = type
	imperfection_timer = delay


func _execute_imperfection() -> void:
	if drone_service == null:
		pending_imperfection = ""
		return

	match pending_imperfection:
		"miss":
			drone_service.miss_shot(randf_range(0.3, 0.8))
			_record_decision("imperfection", "missed_shot")

		"late":
			drone_service.arrive_late(randf_range(0.2, 0.5))
			_record_decision("imperfection", "arrived_late")

		"hesitate":
			drone_service.hesitate(randf_range(0.1, 0.3))
			_record_decision("imperfection", "hesitated")

	pending_imperfection = ""


func _maybe_add_imperfection(event_type: String) -> void:
	if not imperfection_enabled:
		return

	# More likely to miss unexpected events
	var adjusted_miss := miss_chance
	var adjusted_late := late_chance

	match event_type:
		"slide":
			# Slides are fast, easy to miss
			adjusted_miss *= 1.5
			adjusted_late *= 2.0
		"stumble":
			# Very quick, often missed
			adjusted_miss *= 2.0
		"fatal":
			# Never miss fatal moments
			adjusted_miss = 0.0
			adjusted_late *= 0.5

	if randf() < adjusted_miss:
		_queue_imperfection("miss", 0.0)
	elif randf() < adjusted_late:
		_queue_imperfection("late", randf_range(0.1, 0.4))
	elif randf() < hesitate_chance:
		_queue_imperfection("hesitate", randf_range(0.0, 0.2))


# =============================================================================
# SHOT CONTROL
# =============================================================================

func _start_shot(intent: GameEnums.ShotIntent) -> void:
	var old_intent := current_shot_intent
	current_shot_intent = intent
	shot_start_time = Time.get_ticks_msec() / 1000.0

	if drone_service:
		drone_service.set_shot_intent(intent)

	shot_started.emit(intent)


func _end_shot() -> void:
	var duration := Time.get_ticks_msec() / 1000.0 - shot_start_time
	shot_ended.emit(current_shot_intent, duration)


func _on_intent_changed(old_intent: GameEnums.ShotIntent, new_intent: GameEnums.ShotIntent) -> void:
	_end_shot()
	_start_shot(new_intent)

	cut_executed.emit(old_intent, new_intent)
	shot_count += 1


# =============================================================================
# DIRECTOR COMMANDS
# =============================================================================

## Execute a context shot (wide, establishing)
func call_context_shot(reason: String = "director_call") -> void:
	if intent_selector:
		intent_selector.force_intent(GameEnums.ShotIntent.CONTEXT, reason)
	_record_decision("context_shot", reason)


## Execute a tension shot
func call_tension_shot(reason: String = "director_call") -> void:
	if intent_selector:
		intent_selector.force_intent(GameEnums.ShotIntent.TENSION, reason)
	_record_decision("tension_shot", reason)


## Execute a commitment shot (close, action)
func call_commitment_shot(reason: String = "director_call") -> void:
	if intent_selector:
		intent_selector.force_intent(GameEnums.ShotIntent.COMMITMENT, reason)
	_record_decision("commitment_shot", reason)


## Execute a consequence shot (observation)
func call_consequence_shot(reason: String = "director_call") -> void:
	if intent_selector:
		intent_selector.force_intent(GameEnums.ShotIntent.CONSEQUENCE, reason)
	_record_decision("consequence_shot", reason)


## Execute a release shot (breathe)
func call_release_shot(reason: String = "director_call") -> void:
	if intent_selector:
		intent_selector.force_intent(GameEnums.ShotIntent.RELEASE, reason)
	_record_decision("release_shot", reason)


## Start a scripted camera sequence
func start_sequence(sequence_name: String) -> void:
	in_sequence = true
	_record_decision("sequence_start", sequence_name)


## End a scripted sequence
func end_sequence() -> void:
	in_sequence = false
	_record_decision("sequence_end", "")


## Anticipate where subject will be
func anticipate_action(predicted_position: Vector3, time_ahead: float = 1.0) -> void:
	if drone_service and drone_service.drone and drone_service.drone.controller:
		# Move drone to where action will be
		var anticipation_pos := predicted_position + predicted_velocity * time_ahead
		drone_service.drone.controller.set_target_position(anticipation_pos, 0.8)

	_record_decision("anticipate", "%.1fs_ahead" % time_ahead)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.DESCENT:
			is_active = true
		GameEnums.GameState.MAIN_MENU:
			is_active = false
			shot_count = 0
		GameEnums.GameState.PAUSED:
			# Keep state but pause processing
			pass


func _on_descent_ready() -> void:
	is_active = true
	shot_count = 0
	decision_history.clear()

	# Start with establishing shot
	call_context_shot("descent_start")


func _on_run_ended(_run_context: RunContext, _outcome: GameEnums.ResolutionType) -> void:
	# Director goes into observation mode
	_record_decision("run_ended", GameEnums.ResolutionType.keys()[_outcome])


func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	last_event_time = Time.get_ticks_msec() / 1000.0
	last_event_type = "slide"

	_maybe_add_imperfection("slide")
	call_commitment_shot("slide_entry")

	# Plan aftermath
	if slope_angle > 35:
		# Steep slide - be ready for chaos
		_record_decision("anticipate", "steep_slide")


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	last_event_time = Time.get_ticks_msec() / 1000.0

	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			call_release_shot("slide_clean")
		GameEnums.SlideOutcome.TUMBLE_STOP:
			call_consequence_shot("slide_tumble")
		GameEnums.SlideOutcome.TERMINAL_RUNOUT:
			call_consequence_shot("slide_terminal")


func _on_fatal_event_started(phase: GameEnums.FatalPhase) -> void:
	last_event_time = Time.get_ticks_msec() / 1000.0
	last_event_type = "fatal"

	# Never miss fatal moments - be perfect here
	call_consequence_shot("fatal_event")

	# But add subtle hesitation - the human moment of shock
	if imperfection_enabled:
		_queue_imperfection("hesitate", 0.1)


# =============================================================================
# DECISION TRACKING
# =============================================================================

func _record_decision(decision: String, reason: String) -> void:
	var entry := {
		"time": Time.get_ticks_msec() / 1000.0,
		"decision": decision,
		"reason": reason,
		"intent": GameEnums.ShotIntent.keys()[current_shot_intent]
	}

	decision_history.append(entry)

	# Keep history manageable
	if decision_history.size() > 100:
		decision_history.pop_front()

	director_decision.emit(decision, reason)


# =============================================================================
# QUERIES
# =============================================================================

func get_current_intent() -> GameEnums.ShotIntent:
	return current_shot_intent


func get_shot_count() -> int:
	return shot_count


func get_shot_duration() -> float:
	return Time.get_ticks_msec() / 1000.0 - shot_start_time


func is_in_sequence() -> bool:
	return in_sequence


func get_summary() -> Dictionary:
	var summary := {
		"is_active": is_active,
		"current_intent": GameEnums.ShotIntent.keys()[current_shot_intent],
		"shot_count": shot_count,
		"shot_duration": get_shot_duration(),
		"in_sequence": in_sequence,
		"ai_enabled": ai_enabled,
		"imperfection_enabled": imperfection_enabled
	}

	# Add component summaries
	if signal_detector:
		summary["signals"] = signal_detector.get_summary()
	if intent_selector:
		summary["intent"] = intent_selector.get_summary()
	if rhythm_engine:
		summary["rhythm"] = rhythm_engine.get_summary()

	return summary


func get_decision_history() -> Array[Dictionary]:
	return decision_history
