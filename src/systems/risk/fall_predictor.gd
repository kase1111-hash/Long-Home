class_name FallPredictor
extends Node
## Predicts and triggers fall events based on accumulated risk
## The core "consequence" engine of the game
##
## Design Philosophy:
## - Falls are probabilistic, not deterministic
## - Accumulated risk increases fall chance
## - Some falls are recoverable, some are not
## - Players should feel "close calls"

# =============================================================================
# SIGNALS
# =============================================================================

signal fall_triggered(severity: FallSeverity, cause: String)
signal near_miss_occurred(margin: float)
signal slip_occurred(severity: float)
signal balance_recovered()
signal stability_warning(stability: float)

# =============================================================================
# ENUMS
# =============================================================================

enum FallSeverity {
	STUMBLE,         # Minor - quick recovery
	SLIP,            # Moderate - may slide
	FALL,            # Significant - definitely slides
	TUMBLE,          # Severe - uncontrolled
	CATASTROPHIC     # Fatal - no recovery
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Base Probabilities")
## Base fall chance per second at zero risk
@export var base_fall_chance: float = 0.0001
## Maximum fall chance per second
@export var max_fall_chance: float = 0.05

@export_group("Factor Weights")
## Stability deficit weight
@export var stability_weight: float = 0.4
## Speed excess weight
@export var speed_weight: float = 0.3
## Random variance weight
@export var variance_weight: float = 0.1
## Surface weight
@export var surface_weight: float = 0.2

@export_group("Thresholds")
## Stability below which fall becomes likely
@export var critical_stability: float = 0.3
## Speed above which fall becomes likely
@export var critical_speed: float = 8.0
## Near miss margin for feedback
@export var near_miss_margin: float = 0.02

# =============================================================================
# STATE
# =============================================================================

## Current stability (from player)
var current_stability: float = 1.0

## Current speed
var current_speed: float = 0.0

## Current surface type
var current_surface: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM

## Current slope angle
var current_slope: float = 0.0

## Accumulated near-miss tension
var near_miss_tension: float = 0.0

## Recent fall probability (for feedback)
var last_fall_probability: float = 0.0

## Grace period after recovery
var recovery_grace: float = 0.0

## Random variance accumulator
var variance_accumulator: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("FallPredictor", self)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	# Update variance
	_update_variance(delta)

	# Update grace period
	if recovery_grace > 0:
		recovery_grace -= delta

	# Calculate fall probability
	var probability := _calculate_fall_probability()
	last_fall_probability = probability

	# Roll for fall
	if recovery_grace <= 0:
		_roll_for_fall(probability, delta)

	# Check for near misses
	_check_near_miss(probability)

	# Emit stability warning if needed
	if current_stability < 0.5:
		stability_warning.emit(current_stability)


func _update_variance(delta: float) -> void:
	# Random walk for variance
	variance_accumulator += (randf() - 0.5) * delta * 2.0
	variance_accumulator = clampf(variance_accumulator, -0.5, 0.5)


func _calculate_fall_probability() -> float:
	var probability := base_fall_chance

	# Stability deficit
	if current_stability < 1.0:
		var deficit := 1.0 - current_stability
		probability += deficit * stability_weight * 0.1

	# Speed excess
	if current_speed > critical_speed:
		var excess := (current_speed - critical_speed) / critical_speed
		probability += excess * speed_weight * 0.1

	# Surface factor
	probability += _get_surface_fall_modifier() * surface_weight * 0.05

	# Slope factor
	probability += _get_slope_fall_modifier() * 0.05

	# Variance
	probability += variance_accumulator * variance_weight * 0.01

	return clampf(probability, 0.0, max_fall_chance)


func _get_surface_fall_modifier() -> float:
	match current_surface:
		GameEnums.SurfaceType.ICE:
			return 0.8
		GameEnums.SurfaceType.SCREE:
			return 0.6
		GameEnums.SurfaceType.SNOW_SOFT:
			return 0.2
		GameEnums.SurfaceType.SNOW_FIRM:
			return 0.3
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.1
		GameEnums.SurfaceType.ROCK:
			return 0.4
		_:
			return 0.3


func _get_slope_fall_modifier() -> float:
	if current_slope < 25.0:
		return 0.0
	elif current_slope > 50.0:
		return 1.0
	else:
		return (current_slope - 25.0) / 25.0


func _roll_for_fall(probability: float, delta: float) -> void:
	var roll := randf()
	var threshold := probability * delta

	if roll < threshold:
		# Fall occurred
		var severity := _determine_fall_severity(probability)
		var cause := _determine_fall_cause()
		_trigger_fall(severity, cause)
	elif roll < threshold + near_miss_margin:
		# Near miss
		near_miss_tension += 0.1
		if near_miss_tension > 0.3:
			near_miss_occurred.emit(roll - threshold)
			near_miss_tension = 0.0


func _check_near_miss(probability: float) -> void:
	# Decay tension
	near_miss_tension = maxf(0.0, near_miss_tension - 0.01)


func _determine_fall_severity(probability: float) -> FallSeverity:
	# Higher probability = worse fall
	var severity_roll := randf()

	if probability < 0.005:
		# Low probability - likely just a stumble
		if severity_roll < 0.8:
			return FallSeverity.STUMBLE
		else:
			return FallSeverity.SLIP

	elif probability < 0.02:
		# Moderate probability
		if severity_roll < 0.5:
			return FallSeverity.STUMBLE
		elif severity_roll < 0.85:
			return FallSeverity.SLIP
		else:
			return FallSeverity.FALL

	elif probability < 0.04:
		# High probability
		if severity_roll < 0.3:
			return FallSeverity.SLIP
		elif severity_roll < 0.7:
			return FallSeverity.FALL
		else:
			return FallSeverity.TUMBLE

	else:
		# Very high probability - likely bad
		if severity_roll < 0.2:
			return FallSeverity.FALL
		elif severity_roll < 0.6:
			return FallSeverity.TUMBLE
		else:
			return FallSeverity.CATASTROPHIC


func _determine_fall_cause() -> String:
	# Identify primary cause
	var causes := []

	if current_stability < critical_stability:
		causes.append("loss_of_balance")

	if current_speed > critical_speed:
		causes.append("excessive_speed")

	if current_surface == GameEnums.SurfaceType.ICE:
		causes.append("ice")
	elif current_surface == GameEnums.SurfaceType.SCREE:
		causes.append("loose_rock")

	if current_slope > 45.0:
		causes.append("steep_terrain")

	if causes.is_empty():
		return "random_slip"

	return causes[randi() % causes.size()]


func _trigger_fall(severity: FallSeverity, cause: String) -> void:
	fall_triggered.emit(severity, cause)

	# Set grace period based on severity
	match severity:
		FallSeverity.STUMBLE:
			recovery_grace = 1.0
		FallSeverity.SLIP:
			recovery_grace = 1.5
		FallSeverity.FALL:
			recovery_grace = 2.0
		FallSeverity.TUMBLE:
			recovery_grace = 3.0
		FallSeverity.CATASTROPHIC:
			recovery_grace = 5.0

	# Log incident
	EventBus.record_incident("fall", {
		"severity": FallSeverity.keys()[severity],
		"cause": cause,
		"speed": current_speed,
		"stability": current_stability
	})


# =============================================================================
# INPUT FROM OTHER SYSTEMS
# =============================================================================

## Update stability from player
func set_stability(stability: float) -> void:
	current_stability = clampf(stability, 0.0, 1.0)


## Update speed
func set_speed(speed: float) -> void:
	current_speed = speed


## Update surface type
func set_surface(surface: GameEnums.SurfaceType) -> void:
	current_surface = surface


## Update slope
func set_slope(slope: float) -> void:
	current_slope = slope


## Report balance recovered (after stumble/slip)
func report_recovery() -> void:
	recovery_grace = 1.0
	balance_recovered.emit()


## Apply external destabilization
func apply_destabilization(amount: float) -> void:
	current_stability = maxf(0.0, current_stability - amount)

	if current_stability < 0.3:
		# Immediate check for fall
		var probability := _calculate_fall_probability()
		if randf() < probability * 10:
			var severity := _determine_fall_severity(probability * 2)
			_trigger_fall(severity, "destabilized")


# =============================================================================
# QUERIES
# =============================================================================

## Get current fall probability
func get_fall_probability() -> float:
	return last_fall_probability


## Get fall probability as percentage
func get_fall_probability_percent() -> float:
	return last_fall_probability * 100.0


## Check if fall is likely
func is_fall_likely() -> bool:
	return last_fall_probability > 0.01


## Check if fall is imminent
func is_fall_imminent() -> bool:
	return last_fall_probability > 0.03


## Get severity name
func get_severity_name(severity: FallSeverity) -> String:
	return FallSeverity.keys()[severity]


## Get risk level for camera/feedback
func get_risk_intensity() -> float:
	# 0 = safe, 1 = about to fall
	return clampf(last_fall_probability / 0.03, 0.0, 1.0)


## Get summary
func get_summary() -> Dictionary:
	return {
		"fall_probability": last_fall_probability,
		"is_likely": is_fall_likely(),
		"is_imminent": is_fall_imminent(),
		"stability": current_stability,
		"risk_intensity": get_risk_intensity(),
		"in_grace": recovery_grace > 0
	}
