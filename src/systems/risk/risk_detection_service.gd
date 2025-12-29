class_name RiskDetectionService
extends Node
## Central service coordinating all risk detection systems
## Provides unified API for risk queries and events
##
## Design Philosophy:
## - Risk is omnipresent but invisible
## - Players feel risk through feedback
## - Risk affects decision-making
## - System never lies about danger

# =============================================================================
# SIGNALS
# =============================================================================

signal risk_level_changed(old_level: GameEnums.RiskLevel, new_level: GameEnums.RiskLevel)
signal high_risk_entered()
signal extreme_risk_entered()
signal risk_stabilized()
signal fall_event(severity: FallPredictor.FallSeverity, cause: String)
signal point_of_no_return()

# =============================================================================
# CHILD SYSTEMS
# =============================================================================

## Risk calculator (stateless)
var calculator: RiskCalculator

## Zone analyzer
var zone_analyzer: RiskZoneAnalyzer

## Fall predictor
var fall_predictor: FallPredictor

## Feedback system
var feedback: RiskFeedback


# =============================================================================
# STATE
# =============================================================================

## Current risk context
var current_context: RiskCalculator.RiskContext

## Current risk result
var current_result: RiskCalculator.RiskResult

## Previous risk level
var previous_level: GameEnums.RiskLevel = GameEnums.RiskLevel.MINIMAL

## Risk history for trend analysis
var risk_history: Array[float] = []

## History sample interval
var history_interval: float = 0.5

## History timer
var history_timer: float = 0.0


# =============================================================================
# DEPENDENCIES
# =============================================================================

## Terrain service
var terrain_service: TerrainService

## Body condition service
var body_service: BodyConditionService

## Environment service
var environment_service: EnvironmentService

## Player reference
var player: Node


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	# Create subsystems
	calculator = RiskCalculator.new()
	zone_analyzer = RiskZoneAnalyzer.new()
	fall_predictor = FallPredictor.new()
	feedback = RiskFeedback.new()

	# Add node-based systems as children
	add_child(zone_analyzer)
	add_child(fall_predictor)
	add_child(feedback)

	# Initialize context
	current_context = RiskCalculator.RiskContext.new()
	current_result = RiskCalculator.RiskResult.new()

	# Connect signals
	_connect_signals()

	# Get dependencies
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.get_service_async("BodyConditionService", _on_body_ready)
	ServiceLocator.get_service_async("EnvironmentService", _on_environment_ready)
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)

	# Register service
	ServiceLocator.register_service("RiskDetectionService", self)

	print("[RiskDetectionService] Initialized")


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


func _on_body_ready(service: Object) -> void:
	body_service = service as BodyConditionService


func _on_environment_ready(service: Object) -> void:
	environment_service = service as EnvironmentService


func _on_player_ready(service: Object) -> void:
	player = service


func _connect_signals() -> void:
	fall_predictor.fall_triggered.connect(_on_fall_triggered)
	fall_predictor.near_miss_occurred.connect(_on_near_miss)
	fall_predictor.slip_occurred.connect(_on_slip)

	zone_analyzer.point_of_no_return_detected.connect(_on_ponr_detected)
	zone_analyzer.risk_zone_entered.connect(_on_risk_zone_entered)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	_update_context()
	_calculate_risk()
	_update_subsystems()
	_update_history(delta)
	_check_level_changes()


func _update_context() -> void:
	if player == null:
		return

	# Terrain data
	if terrain_service:
		var cell := terrain_service.get_cell_at(player.global_position)
		if cell:
			current_context.slope_angle = cell.slope_angle
			current_context.surface_type = cell.surface_type
			current_context.cliff_distance = cell.distance_to_cliff
			current_context.in_no_exit_zone = not cell.is_exit_zone and cell.exit_zone_quality < 0.3

	# Movement data
	if player.has_method("get_speed"):
		current_context.speed = player.get_speed()
	else:
		current_context.speed = player.velocity.length() if "velocity" in player else 0.0

	if player.has_method("get_stability"):
		current_context.stability = player.get_stability()
	else:
		current_context.stability = 1.0

	# Body data
	if body_service:
		current_context.fatigue = body_service.get_body_state().fatigue
		current_context.is_injured = body_service.get_body_state().get_total_injury_severity() > 0.3

	# Weather data
	if environment_service:
		var conditions := environment_service.get_conditions()
		current_context.wind_strength = conditions.weather
		current_context.visibility = conditions.visibility
		current_context.is_whiteout = conditions.weather == GameEnums.WeatherState.WHITEOUT
		current_context.is_night = conditions.time_period == TimeService.TimePeriod.NIGHT

	# Gear data (would integrate with gear system)
	# current_context.has_crampons = ...
	# current_context.gear_condition = ...


func _calculate_risk() -> void:
	current_result = calculator.calculate_risk(current_context)


func _update_subsystems() -> void:
	# Update zone analyzer
	if player:
		zone_analyzer.update_player(player.global_position, player.velocity if "velocity" in player else Vector3.ZERO)

	# Update fall predictor
	fall_predictor.set_stability(current_context.stability)
	fall_predictor.set_speed(current_context.speed)
	fall_predictor.set_surface(current_context.surface_type)
	fall_predictor.set_slope(current_context.slope_angle)

	# Update feedback
	feedback.set_risk_level(current_result.total_risk)


func _update_history(delta: float) -> void:
	history_timer += delta
	if history_timer >= history_interval:
		history_timer = 0.0
		risk_history.append(current_result.total_risk)

		# Limit history
		while risk_history.size() > 20:
			risk_history.pop_front()


func _check_level_changes() -> void:
	var new_level := current_result.risk_level

	if new_level != previous_level:
		risk_level_changed.emit(previous_level, new_level)
		EventBus.risk_level_changed.emit(current_result.total_risk, {
			"level": GameEnums.RiskLevel.keys()[new_level],
			"primary_danger": current_result.primary_danger
		})

		if new_level == GameEnums.RiskLevel.HIGH:
			high_risk_entered.emit()
			EventBus.high_risk_zone_entered.emit("combined", current_result.total_risk)

		if new_level == GameEnums.RiskLevel.EXTREME:
			extreme_risk_entered.emit()

		if new_level < previous_level and new_level <= GameEnums.RiskLevel.LOW:
			risk_stabilized.emit()

		previous_level = new_level


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_fall_triggered(severity: FallPredictor.FallSeverity, cause: String) -> void:
	fall_event.emit(severity, cause)
	feedback.trigger_fall_feedback(severity)


func _on_near_miss(margin: float) -> void:
	feedback.trigger_near_miss()


func _on_slip(severity: float) -> void:
	feedback.apply_risk_spike(severity, 0.2)


func _on_ponr_detected(distance: float) -> void:
	point_of_no_return.emit()


func _on_risk_zone_entered(zone_type: RiskZoneAnalyzer.ZoneType, position: Vector3) -> void:
	if zone_type >= RiskZoneAnalyzer.ZoneType.DANGER:
		feedback.apply_risk_spike(0.5, 0.3)


# =============================================================================
# QUERIES
# =============================================================================

## Get current risk level
func get_risk_level() -> GameEnums.RiskLevel:
	return current_result.risk_level


## Get current risk value (0-1)
func get_risk_value() -> float:
	return current_result.total_risk


## Get risk result
func get_risk_result() -> RiskCalculator.RiskResult:
	return current_result


## Get primary danger
func get_primary_danger() -> String:
	return current_result.primary_danger


## Check if in high risk
func is_high_risk() -> bool:
	return current_result.risk_level >= GameEnums.RiskLevel.HIGH


## Check if in extreme risk
func is_extreme_risk() -> bool:
	return current_result.risk_level == GameEnums.RiskLevel.EXTREME


## Get risk trend
func get_risk_trend() -> float:
	if risk_history.size() < 5:
		return 0.0

	var recent := 0.0
	var older := 0.0

	for i in range(risk_history.size() / 2):
		older += risk_history[i]
	older /= risk_history.size() / 2

	for i in range(risk_history.size() / 2, risk_history.size()):
		recent += risk_history[i]
	recent /= risk_history.size() - risk_history.size() / 2

	return recent - older


## Check if risk is increasing
func is_risk_increasing() -> bool:
	return get_risk_trend() > 0.05


## Check if risk is decreasing
func is_risk_decreasing() -> bool:
	return get_risk_trend() < -0.05


## Get zone analyzer
func get_zone_analyzer() -> RiskZoneAnalyzer:
	return zone_analyzer


## Get fall predictor
func get_fall_predictor() -> FallPredictor:
	return fall_predictor


## Get feedback system
func get_feedback() -> RiskFeedback:
	return feedback


## Get comprehensive summary
func get_summary() -> Dictionary:
	return {
		"risk_level": GameEnums.RiskLevel.keys()[current_result.risk_level],
		"risk_value": current_result.total_risk,
		"primary_danger": current_result.primary_danger,
		"active_multipliers": current_result.active_multipliers,
		"trend": get_risk_trend(),
		"is_increasing": is_risk_increasing(),
		"zone": zone_analyzer.get_summary(),
		"fall": fall_predictor.get_summary(),
		"feedback": feedback.get_feedback_state()
	}
