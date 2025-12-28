class_name PostureSystem
extends Node
## Manages player stability, balance, and micro-slip events
## Creates the "feel" of precarious mountain terrain

# =============================================================================
# CONFIGURATION
# =============================================================================

## Base stability value
var base_stability: float = 1.0

## How quickly stability recovers when stable
var stability_recovery_rate: float = 0.3

## How quickly stability drains in dangerous situations
var stability_drain_rate: float = 0.5

## Interval between potential micro-slip checks (seconds)
var micro_slip_check_interval: float = 0.5

## Probability multiplier for micro-slips
var micro_slip_probability_scale: float = 1.0

## Speed threshold for speed-based instability
var speed_instability_threshold: float = 3.0

## Slope threshold for slope-based instability
var slope_instability_threshold: float = 25.0

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Time since last micro-slip check
var micro_slip_timer: float = 0.0

## Current stability modifiers
var stability_modifiers: Dictionary = {}

## Recent micro-slips for tracking
var recent_slips: Array[float] = []

## Time window for slip tracking
var slip_tracking_window: float = 10.0

## Is player in a precarious situation
var is_precarious: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(controller: PlayerController) -> void:
	player = controller


# =============================================================================
# UPDATE
# =============================================================================

func update(delta: float) -> void:
	# Calculate base stability from conditions
	var target_stability := _calculate_target_stability()

	# Apply stability change
	_update_stability(target_stability, delta)

	# Check for micro-slips
	micro_slip_timer += delta
	if micro_slip_timer >= micro_slip_check_interval:
		micro_slip_timer = 0.0
		_check_for_micro_slip()

	# Update precarious state
	is_precarious = player.stability < 0.5

	# Clean up old slip records
	_clean_slip_history()


# =============================================================================
# STABILITY CALCULATION
# =============================================================================

func _calculate_target_stability() -> float:
	var stability := base_stability

	# Clear modifiers
	stability_modifiers.clear()

	# Terrain slope modifier
	if player.current_cell:
		var slope := player.current_cell.slope_angle
		if slope > slope_instability_threshold:
			var slope_penalty := (slope - slope_instability_threshold) / 45.0 * 0.4
			stability -= slope_penalty
			stability_modifiers["slope"] = -slope_penalty

	# Surface modifier
	if player.current_cell:
		var surface_penalty := _get_surface_stability_penalty(player.current_cell.surface_type)
		stability -= surface_penalty
		if surface_penalty > 0:
			stability_modifiers["surface"] = -surface_penalty

	# Speed modifier
	var speed := player.smooth_velocity.length()
	if speed > speed_instability_threshold:
		var speed_penalty := (speed - speed_instability_threshold) / 10.0 * 0.3
		stability -= speed_penalty
		stability_modifiers["speed"] = -speed_penalty

	# Fatigue modifier
	if player.body_state:
		var fatigue := player.body_state.fatigue
		if fatigue > 0.3:
			var fatigue_penalty := (fatigue - 0.3) * 0.5
			stability -= fatigue_penalty
			stability_modifiers["fatigue"] = -fatigue_penalty

	# Body state modifier
	if player.body_state:
		var body_modifier := player.body_state.get_stability_modifier()
		var body_penalty := 1.0 - body_modifier
		stability -= body_penalty
		if body_penalty > 0:
			stability_modifiers["body"] = -body_penalty

	# Gear modifier (crampons help on ice)
	if player.gear_state and player.current_cell:
		if player.current_cell.surface_type == GameEnums.SurfaceType.ICE:
			if player.gear_state.has_crampons():
				var crampon_bonus := player.gear_state.get_crampon_effectiveness() * 0.3
				stability += crampon_bonus
				stability_modifiers["crampons"] = crampon_bonus
			else:
				stability -= 0.3
				stability_modifiers["no_crampons"] = -0.3

	# Cliff proximity modifier
	if player.current_cell:
		var cliff_dist := player.current_cell.distance_to_cliff
		if cliff_dist < 10.0:
			var cliff_penalty := (1.0 - cliff_dist / 10.0) * 0.2
			stability -= cliff_penalty
			stability_modifiers["cliff_proximity"] = -cliff_penalty

	# Movement state modifier
	match player.current_state:
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			stability -= 0.1
			stability_modifiers["downclimbing"] = -0.1
		GameEnums.PlayerMovementState.RESTING:
			stability += 0.2
			stability_modifiers["resting"] = 0.2

	return clampf(stability, 0.0, 1.0)


func _get_surface_stability_penalty(surface: GameEnums.SurfaceType) -> float:
	match surface:
		GameEnums.SurfaceType.ICE:
			return 0.3
		GameEnums.SurfaceType.ROCK_WET:
			return 0.2
		GameEnums.SurfaceType.SCREE:
			return 0.15
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.1
		_:
			return 0.0


func _update_stability(target: float, delta: float) -> void:
	var current := player.stability

	if target > current:
		# Recovery
		var recovery := stability_recovery_rate * delta
		player.set_stability(minf(target, current + recovery))
	else:
		# Drain
		var drain := stability_drain_rate * delta
		player.set_stability(maxf(target, current - drain))


# =============================================================================
# MICRO-SLIP SYSTEM
# =============================================================================

func _check_for_micro_slip() -> void:
	# Don't slip in safe states
	if player.current_state in [
		GameEnums.PlayerMovementState.RESTING,
		GameEnums.PlayerMovementState.SLIDING,  # Already sliding
		GameEnums.PlayerMovementState.FALLING   # Already falling
	]:
		return

	# Calculate slip probability
	var slip_chance := _calculate_slip_probability()

	# Random roll
	if randf() < slip_chance:
		_trigger_micro_slip()


func _calculate_slip_probability() -> float:
	var probability := 0.0

	# Base probability from stability
	var instability := 1.0 - player.stability
	probability += instability * 0.1

	# Slope adds to probability
	if player.current_cell:
		var slope := player.current_cell.slope_angle
		if slope > 20:
			probability += (slope - 20) / 50.0 * 0.1

	# Surface adds to probability
	if player.current_cell:
		match player.current_cell.surface_type:
			GameEnums.SurfaceType.ICE:
				probability += 0.15
			GameEnums.SurfaceType.ROCK_WET:
				probability += 0.08
			GameEnums.SurfaceType.SCREE:
				probability += 0.05

	# Speed adds to probability
	var speed := player.smooth_velocity.length()
	if speed > 2.0:
		probability += (speed - 2.0) / 10.0 * 0.1

	# Fatigue adds to probability
	if player.body_state:
		probability += player.body_state.fatigue * 0.1

	# Recent slips increase future slip probability (destabilization)
	probability += len(recent_slips) * 0.02

	return probability * micro_slip_probability_scale


func _trigger_micro_slip() -> void:
	# Calculate severity based on conditions
	var severity := 0.3  # Base severity

	# Slope increases severity
	if player.current_cell:
		severity += player.current_cell.slope_angle / 90.0 * 0.3

	# Speed increases severity
	severity += player.smooth_velocity.length() / 10.0 * 0.2

	# Low stability increases severity
	severity += (1.0 - player.stability) * 0.2

	severity = clampf(severity, 0.1, 1.0)

	# Apply stability loss
	player.set_stability(player.stability - severity * 0.2)

	# Record slip
	recent_slips.append(severity)

	# Trigger player response
	player.trigger_micro_slip(severity)

	# Apply small velocity perturbation
	if player.current_cell:
		var slip_dir := player.current_cell.slope_direction
		var slip_force := slip_dir * severity * 2.0
		player.velocity += slip_force

	# Check if slip leads to fall
	if player.stability < player.fall_threshold:
		_trigger_fall_from_slip(severity)

	# Check if slip leads to slide
	if severity > 0.7 and player.can_initiate_slide():
		_trigger_slide_from_slip()


func _trigger_fall_from_slip(severity: float) -> void:
	player.change_state(GameEnums.PlayerMovementState.FALLING)

	EventBus.record_incident("fall_from_slip", {
		"severity": severity,
		"stability": player.stability
	})


func _trigger_slide_from_slip() -> void:
	player.change_state(GameEnums.PlayerMovementState.SLIDING)

	EventBus.record_incident("slide_from_slip", {
		"position": player.global_position,
		"stability": player.stability
	})


func _clean_slip_history() -> void:
	# Remove old slip records
	# For simplicity, just keep a max count
	while recent_slips.size() > 5:
		recent_slips.pop_front()


# =============================================================================
# QUERIES
# =============================================================================

## Get current stability modifiers for debug/UI
func get_stability_modifiers() -> Dictionary:
	return stability_modifiers.duplicate()


## Get risk level (0-1)
func get_risk_level() -> float:
	return 1.0 - player.stability


## Check if player should be warned about stability
func should_warn_stability() -> bool:
	return player.stability < 0.5


## Get descriptive stability status
func get_stability_description() -> String:
	match player.posture_state:
		GameEnums.PostureState.STABLE:
			return "Stable footing"
		GameEnums.PostureState.MARGINAL:
			return "Balance challenged"
		GameEnums.PostureState.UNSTABLE:
			return "Losing balance"
		GameEnums.PostureState.FALLING:
			return "Falling!"
		_:
			return "Unknown"
