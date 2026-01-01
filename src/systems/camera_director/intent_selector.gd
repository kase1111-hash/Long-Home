class_name IntentSelector
extends Node
## Decides which shot intent to use based on signals and pacing
## The "storytelling brain" of the camera system
##
## Design Philosophy:
## - Each shot intent has a purpose in the narrative
## - Context: Where are we? (Establishing)
## - Tension: Something is happening (Building)
## - Commitment: Point of no return (Peak action)
## - Consequence: What happened? (Observation)
## - Release: Take a breath (Resolution)

# =============================================================================
# SIGNALS
# =============================================================================

signal intent_changed(old_intent: GameEnums.ShotIntent, new_intent: GameEnums.ShotIntent)
signal shot_recommended(intent: GameEnums.ShotIntent, reason: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Timing")
## Minimum time before intent can change
@export var min_intent_duration: float = 2.0
## Maximum time in any single intent
@export var max_intent_duration: float = 20.0
## Time without activity before returning to context
@export var context_return_time: float = 8.0

@export_group("Thresholds")
## Intensity threshold for tension shot
@export var tension_threshold: float = 0.3
## Intensity threshold for commitment shot
@export var commitment_threshold: float = 0.6
## Intensity drop for consequence shot
@export var consequence_drop_threshold: float = 0.3
## Intensity for release shot
@export var release_threshold: float = 0.2

@export_group("Behavior")
## Enable variety in shot selection
@export var variety_enabled: bool = true
## Avoid repeating same intent within this time
@export var variety_window: float = 30.0

# =============================================================================
# STATE
# =============================================================================

## Current shot intent
var current_intent: GameEnums.ShotIntent = GameEnums.ShotIntent.CONTEXT

## Time in current intent
var time_in_intent: float = 0.0

## Time since last significant activity
var time_since_activity: float = 0.0

## Last intensity value (for detecting drops)
var last_intensity: float = 0.0

## Intent history for variety
var intent_history: Array[Dictionary] = []

## Signal detector reference
var signal_detector: SignalDetector

## Rhythm engine reference
var rhythm_engine: EmotionalRhythmEngine

## Is selector active
var is_active: bool = false

## Pending intent (for delayed changes)
var pending_intent: GameEnums.ShotIntent = GameEnums.ShotIntent.CONTEXT
var pending_reason: String = ""
var has_pending: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("IntentSelector", self)
	ServiceLocator.get_service_async("SignalDetector", func(s): signal_detector = s)
	ServiceLocator.get_service_async("EmotionalRhythmEngine", func(s): rhythm_engine = s)

	_connect_events()
	print("[IntentSelector] Initialized")


func _connect_events() -> void:
	# React to major game events directly for immediate response
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.fatal_event_started.connect(_on_fatal_event_started)
	EventBus.fatal_phase_changed.connect(_on_fatal_phase_changed)
	EventBus.descent_ready.connect(_on_descent_ready)
	EventBus.game_state_changed.connect(_on_game_state_changed)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_active:
		return

	time_in_intent += delta
	time_since_activity += delta

	_process_pending()
	_evaluate_intent(delta)
	_record_history()


func _process_pending() -> void:
	if not has_pending:
		return

	# Only apply pending if minimum duration has passed
	if time_in_intent >= min_intent_duration:
		_change_intent(pending_intent, pending_reason)
		has_pending = false


func _evaluate_intent(delta: float) -> void:
	if signal_detector == null:
		return

	var intensity := signal_detector.get_total_intensity()
	var intensity_delta := intensity - last_intensity
	last_intensity = intensity

	# Track activity
	if intensity > 0.2:
		time_since_activity = 0.0

	# Don't change too quickly
	if time_in_intent < min_intent_duration:
		return

	# Evaluate what intent makes sense now
	var recommended := _determine_recommended_intent(intensity, intensity_delta)

	if recommended != current_intent:
		_queue_intent_change(recommended, _get_change_reason(recommended, intensity))


func _determine_recommended_intent(intensity: float, intensity_delta: float) -> GameEnums.ShotIntent:
	# Check rhythm engine recommendations
	var rhythm_phase := EmotionalRhythmEngine.RhythmPhase.REST
	if rhythm_engine:
		rhythm_phase = rhythm_engine.get_rhythm_phase()

		# Forced release if rhythm engine says so
		if rhythm_engine.is_release_needed():
			return GameEnums.ShotIntent.RELEASE

	# High intensity = commitment
	if intensity >= commitment_threshold:
		return GameEnums.ShotIntent.COMMITMENT

	# Rising intensity = tension
	if intensity >= tension_threshold and intensity_delta > 0.05:
		return GameEnums.ShotIntent.TENSION

	# Falling intensity after high = consequence
	if intensity_delta < -consequence_drop_threshold and last_intensity > tension_threshold:
		return GameEnums.ShotIntent.CONSEQUENCE

	# Low intensity for a while = release
	if intensity < release_threshold and time_in_intent > 5.0:
		if current_intent == GameEnums.ShotIntent.CONSEQUENCE:
			return GameEnums.ShotIntent.RELEASE

	# Return to context after inactivity
	if time_since_activity > context_return_time:
		return GameEnums.ShotIntent.CONTEXT

	# Max duration reached, shift to something
	if time_in_intent > max_intent_duration:
		return _get_next_logical_intent()

	return current_intent


func _get_next_logical_intent() -> GameEnums.ShotIntent:
	# Natural progression based on current intent
	match current_intent:
		GameEnums.ShotIntent.CONTEXT:
			return GameEnums.ShotIntent.TENSION
		GameEnums.ShotIntent.TENSION:
			return GameEnums.ShotIntent.COMMITMENT
		GameEnums.ShotIntent.COMMITMENT:
			return GameEnums.ShotIntent.CONSEQUENCE
		GameEnums.ShotIntent.CONSEQUENCE:
			return GameEnums.ShotIntent.RELEASE
		GameEnums.ShotIntent.RELEASE:
			return GameEnums.ShotIntent.CONTEXT
		_:
			return GameEnums.ShotIntent.CONTEXT


func _get_change_reason(intent: GameEnums.ShotIntent, intensity: float) -> String:
	match intent:
		GameEnums.ShotIntent.CONTEXT:
			return "returning_to_context"
		GameEnums.ShotIntent.TENSION:
			return "intensity_rising_%.2f" % intensity
		GameEnums.ShotIntent.COMMITMENT:
			return "high_intensity_%.2f" % intensity
		GameEnums.ShotIntent.CONSEQUENCE:
			return "intensity_falling"
		GameEnums.ShotIntent.RELEASE:
			return "breathing_room"
		_:
			return "automatic"


# =============================================================================
# INTENT CHANGES
# =============================================================================

func _queue_intent_change(intent: GameEnums.ShotIntent, reason: String) -> void:
	# Check variety constraint
	if variety_enabled and _was_intent_recent(intent):
		return

	pending_intent = intent
	pending_reason = reason
	has_pending = true


func _change_intent(new_intent: GameEnums.ShotIntent, reason: String) -> void:
	if new_intent == current_intent:
		return

	var old_intent := current_intent
	current_intent = new_intent
	time_in_intent = 0.0

	intent_changed.emit(old_intent, new_intent)
	shot_recommended.emit(new_intent, reason)

	print("[IntentSelector] %s -> %s (%s)" % [
		GameEnums.ShotIntent.keys()[old_intent],
		GameEnums.ShotIntent.keys()[new_intent],
		reason
	])


func _record_history() -> void:
	# Only record on changes
	if time_in_intent > 0.1:
		return

	var current_time := Time.get_ticks_msec() / 1000.0

	intent_history.append({
		"intent": current_intent,
		"timestamp": current_time
	})

	# Prune old history
	while intent_history.size() > 0 and intent_history[0].get("timestamp", 0) < current_time - variety_window:
		intent_history.pop_front()


func _was_intent_recent(intent: GameEnums.ShotIntent) -> bool:
	var current_time := Time.get_ticks_msec() / 1000.0
	var check_window := variety_window * 0.5  # Half window for recent check

	for entry in intent_history:
		if entry.get("intent") == intent:
			if current_time - entry.get("timestamp", 0) < check_window:
				return true

	return false


# =============================================================================
# SPECIAL EVENTS (Immediate Response)
# =============================================================================

func _on_slide_started(_entry_speed: float, _slope_angle: float) -> void:
	# Immediate commitment for slide
	_change_intent(GameEnums.ShotIntent.COMMITMENT, "slide_started")


func _on_slide_ended(outcome: GameEnums.SlideOutcome, _final_speed: float) -> void:
	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			_change_intent(GameEnums.ShotIntent.RELEASE, "slide_clean_stop")
		GameEnums.SlideOutcome.TUMBLE_STOP:
			_change_intent(GameEnums.ShotIntent.CONSEQUENCE, "slide_tumble")
		GameEnums.SlideOutcome.TERMINAL_RUNOUT:
			_change_intent(GameEnums.ShotIntent.CONSEQUENCE, "slide_runout")


func _on_fatal_event_started(_phase: GameEnums.FatalPhase) -> void:
	# Hold on consequence for fatal events
	_change_intent(GameEnums.ShotIntent.CONSEQUENCE, "fatal_event")


func _on_fatal_phase_changed(_old: GameEnums.FatalPhase, new_phase: GameEnums.FatalPhase) -> void:
	match new_phase:
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			_change_intent(GameEnums.ShotIntent.CONSEQUENCE, "loss_of_control")
		GameEnums.FatalPhase.AFTERMATH:
			_change_intent(GameEnums.ShotIntent.RELEASE, "aftermath")
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			_change_intent(GameEnums.ShotIntent.CONTEXT, "acknowledgment")


func _on_descent_ready() -> void:
	is_active = true
	_change_intent(GameEnums.ShotIntent.CONTEXT, "descent_start")


func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.DESCENT:
			is_active = true
		GameEnums.GameState.MAIN_MENU:
			is_active = false
		GameEnums.GameState.PAUSED:
			is_active = false


# =============================================================================
# MANUAL CONTROL
# =============================================================================

## Force a specific intent (for scripted sequences)
func force_intent(intent: GameEnums.ShotIntent, reason: String = "forced") -> void:
	_change_intent(intent, reason)


## Suggest an intent (respects constraints)
func suggest_intent(intent: GameEnums.ShotIntent, reason: String = "suggested") -> void:
	_queue_intent_change(intent, reason)


## Get intent for a specific signal type
func get_intent_for_signal(signal_type: GameEnums.CameraSignal) -> GameEnums.ShotIntent:
	match signal_type:
		GameEnums.CameraSignal.SLOPE_CHANGE:
			return GameEnums.ShotIntent.TENSION
		GameEnums.CameraSignal.SPEED_CHANGE:
			return GameEnums.ShotIntent.TENSION
		GameEnums.CameraSignal.SLIDE_ENTRY:
			return GameEnums.ShotIntent.COMMITMENT
		GameEnums.CameraSignal.SLIDE_EXIT:
			return GameEnums.ShotIntent.RELEASE
		GameEnums.CameraSignal.CLIFF_PROXIMITY:
			return GameEnums.ShotIntent.TENSION
		GameEnums.CameraSignal.STANCE_CHANGE:
			return GameEnums.ShotIntent.CONTEXT
		GameEnums.CameraSignal.BREATH_HOLD:
			return GameEnums.ShotIntent.TENSION
		GameEnums.CameraSignal.STUMBLE:
			return GameEnums.ShotIntent.CONSEQUENCE
		GameEnums.CameraSignal.WEATHER_CHANGE:
			return GameEnums.ShotIntent.CONTEXT
		GameEnums.CameraSignal.FATAL_MOMENT:
			return GameEnums.ShotIntent.CONSEQUENCE
		_:
			return GameEnums.ShotIntent.CONTEXT


# =============================================================================
# QUERIES
# =============================================================================

func get_current_intent() -> GameEnums.ShotIntent:
	return current_intent


func get_time_in_intent() -> float:
	return time_in_intent


func should_cut() -> bool:
	# Recommend cut when intent just changed
	return time_in_intent < 0.5


func get_intent_urgency() -> float:
	# How urgent is a change? Higher = should change soon
	if time_in_intent > max_intent_duration * 0.8:
		return 0.8
	if has_pending:
		return 0.5
	return 0.0


func get_summary() -> Dictionary:
	return {
		"current_intent": GameEnums.ShotIntent.keys()[current_intent],
		"time_in_intent": time_in_intent,
		"time_since_activity": time_since_activity,
		"has_pending": has_pending,
		"pending_intent": GameEnums.ShotIntent.keys()[pending_intent] if has_pending else "none",
		"urgency": get_intent_urgency(),
		"is_active": is_active
	}
