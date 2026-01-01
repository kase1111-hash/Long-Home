extends Node
## Global event bus for cross-system communication
## Autoloaded as EventBus
##
## Usage:
##   EventBus.player_state_changed.connect(_on_player_state_changed)
##   EventBus.player_state_changed.emit(old_state, new_state)

# =============================================================================
# GAME STATE SIGNALS
# =============================================================================

## Emitted when game state changes
signal game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState)

## Emitted when a run begins
signal run_started(run_context: RunContext)

## Emitted when a run ends
signal run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType)

## Emitted when game is paused/unpaused
signal pause_state_changed(is_paused: bool)

## Emitted when descent gameplay is fully initialized and ready
signal descent_ready()

# =============================================================================
# PLAYER SIGNALS
# =============================================================================

## Emitted when player movement state changes
signal player_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState)

## Emitted when player position updates (throttled for performance)
signal player_position_updated(position: Vector3, velocity: Vector3)

## Emitted when player stability changes significantly
signal player_stability_changed(stability: float, posture: GameEnums.PostureState)

## Emitted when a micro-slip occurs
signal micro_slip_occurred(severity: float, position: Vector3)

## Emitted when player stumbles/balance recovery
signal stumble_occurred(severity: float, recovered: bool)

## Emitted when player starts checking themselves
signal self_check_started()

## Emitted when player finishes checking themselves
signal self_check_completed(body_state: BodyState)

# =============================================================================
# SLIDING SIGNALS
# =============================================================================

## Emitted when slide is initiated
signal slide_started(entry_speed: float, slope_angle: float)

## Emitted during slide with current state
signal slide_state_updated(control_level: float, speed: float, trajectory: Vector3)

## Emitted when slide ends
signal slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float)

## Emitted when slide control level changes category
signal slide_control_changed(old_level: GameEnums.SlideControlLevel, new_level: GameEnums.SlideControlLevel)

# =============================================================================
# ROPE SIGNALS
# =============================================================================

## Emitted when rope deployment begins
signal rope_deployment_started(anchor_quality: GameEnums.AnchorQuality)

## Emitted when rope is ready for descent
signal rope_ready(rope_length: float)

## Emitted when rappel begins
signal rappel_started()

## Emitted when rappel ends
signal rappel_ended(outcome: int)

## Emitted during rappel
signal rappel_progress(distance_remaining: float, speed: float)

## Emitted when rope jams
signal rope_jammed(position: Vector3)

## Emitted when rope is recovered
signal rope_recovered()

# =============================================================================
# BODY CONDITION SIGNALS
# =============================================================================

## Emitted when fatigue crosses a threshold
signal fatigue_threshold_crossed(fatigue: float, threshold_name: String)

## Emitted when cold exposure changes significantly
signal cold_exposure_changed(cold_level: float, affected_parts: Array[GameEnums.BodyPart])

## Emitted when injury occurs
signal injury_occurred(injury: Injury)

## Emitted when body state updates
signal body_state_updated(body_state: BodyState)

# =============================================================================
# TERRAIN SIGNALS
# =============================================================================

## Emitted when player enters new terrain zone
signal terrain_zone_changed(old_zone: GameEnums.TerrainZone, new_zone: GameEnums.TerrainZone)

## Emitted when surface type changes
signal surface_changed(old_surface: GameEnums.SurfaceType, new_surface: GameEnums.SurfaceType)

## Emitted when approaching cliff edge
signal cliff_proximity_warning(distance: float, direction: Vector3)

## Emitted when cliff distance changes during slide
signal cliff_proximity_changed(distance: float)

## Emitted when exit zone detected during slide
signal exit_zone_detected(position: Vector3, quality: float)

# =============================================================================
# WEATHER & TIME SIGNALS
# =============================================================================

## Emitted when weather state changes
signal weather_changed(old_weather: GameEnums.WeatherState, new_weather: GameEnums.WeatherState)

## Emitted when wind strength changes
signal wind_changed(strength: GameEnums.WindStrength, direction: Vector3)

## Emitted at significant time events
signal time_milestone(game_time: float, event: String)  # "dusk", "night", etc.

## Emitted when temperature changes significantly
signal temperature_changed(temperature: float, feels_like: float)

# =============================================================================
# CAMERA & DRONE SIGNALS
# =============================================================================

## Emitted when camera signal detected
signal camera_signal_detected(signal_type: GameEnums.CameraSignal, intensity: float)

## Emitted when shot intent changes
signal shot_intent_changed(old_intent: GameEnums.ShotIntent, new_intent: GameEnums.ShotIntent)

## Emitted when drone mode changes
signal drone_mode_changed(old_mode: GameEnums.DroneMode, new_mode: GameEnums.DroneMode)

## Emitted when drone battery low
signal drone_battery_low(battery_level: float)

## Emitted when drone loses signal
signal drone_signal_lost()

# =============================================================================
# FATAL EVENT SIGNALS
# =============================================================================

## Emitted when fatal event begins
signal fatal_event_started(phase: GameEnums.FatalPhase)

## Emitted when fatal phase changes
signal fatal_phase_changed(old_phase: GameEnums.FatalPhase, new_phase: GameEnums.FatalPhase)

## Emitted when fatal event completes (after acknowledgment)
signal fatal_event_completed()

# =============================================================================
# RISK SIGNALS
# =============================================================================

## Emitted when risk level changes significantly
signal risk_level_changed(risk: float, factors: Dictionary)

## Emitted when entering high-risk zone
signal high_risk_zone_entered(risk_type: String, severity: float)

## Emitted when point of no return detected
signal point_of_no_return_detected()

# =============================================================================
# UI SIGNALS
# =============================================================================

## Emitted when map is opened
signal map_opened()

## Emitted when map is closed
signal map_closed()

## Emitted to show diegetic message
signal diegetic_message(message: String, duration: float)

# =============================================================================
# REPLAY & RECORDING SIGNALS
# =============================================================================

## Emitted when significant decision made (for replay)
signal decision_recorded(decision_type: String, context: Dictionary)

## Emitted when incident occurs (for replay)
signal incident_recorded(incident_type: String, context: Dictionary)

# =============================================================================
# AUDIO SIGNALS
# =============================================================================

## Emitted when audio system is ready
signal audio_ready()

## Emitted when wind intensity changes significantly
signal wind_audio_changed(intensity: float)

## Emitted when breathing pattern changes
signal breathing_changed(intensity: float)

## Emitted when silence moment occurs (for camera coordination)
signal silence_moment(is_active: bool)

## Emitted when audio should duck for dramatic moment
signal audio_duck_requested(reason: String)

## Emitted when ducked audio should restore
signal audio_restore_requested()

# =============================================================================
# TUTORIAL SIGNALS
# =============================================================================

## Emitted when tutorial starts
signal tutorial_started(is_hard_mode: bool)

## Emitted when tutorial phase changes
signal tutorial_phase_changed(phase_name: String)

## Emitted when player learns a lesson organically
signal lesson_learned(lesson: String)

## Emitted when instructor speaks
signal instructor_spoke(line_id: String, text: String)

## Emitted when instructor falls (hard mode)
signal instructor_accident()

## Emitted when tutorial completes
signal tutorial_completed(rescued_instructor: bool)


# =============================================================================
# HELPER METHODS
# =============================================================================

## Emit a camera signal with automatic intensity calculation
func emit_camera_signal(signal_type: GameEnums.CameraSignal, base_intensity: float = 1.0) -> void:
	camera_signal_detected.emit(signal_type, base_intensity)

## Emit a decision for recording
func record_decision(decision_type: String, context: Dictionary = {}) -> void:
	decision_recorded.emit(decision_type, context)

## Emit an incident for recording
func record_incident(incident_type: String, context: Dictionary = {}) -> void:
	incident_recorded.emit(incident_type, context)
