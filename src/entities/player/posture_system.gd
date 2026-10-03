class_name PostureSystem
extends Node
## Manages player stability, balance, and slips
## Creates the "feel" of precarious mountain terrain
##
## Balance comes from footing first: the grip of what is on the feet
## (TractionModel.foot_grip) against what the slope and the pace demand, plus
## the axe and the hands while downclimbing. Fatigue, injuries and a drop
## beside you take a little more off.
##
## Slips are a Poisson process on that grip margin: rare with grip to spare,
## every few seconds on a knife edge, immediate once the footing cannot hold.
## Most slips are a stagger. On thin margins they become a slide (snow, ice,
## scree and broken rock steeper than a body can rest on) or a fall (cliffs),
## unless the plunged axe or the other holds catch it.

# =============================================================================
# CONFIGURATION
# =============================================================================

## Base stability value
var base_stability: float = 1.0

## How quickly stability recovers when stable
var stability_recovery_rate: float = 0.3

## How quickly stability drains in dangerous situations
var stability_drain_rate: float = 0.5

## Shortest gap between two slips (seconds): a slip is a moment, not a buzz
var slip_refractory_time: float = 0.6

## Longer gap after going down on the ground
var fall_over_refractory_time: float = 2.0

## Probability multiplier for micro-slips
var micro_slip_probability_scale: float = 1.0

## Clinging with three points on, a slip is mostly a foot popping off
var clinging_escalation_scale: float = 0.4

# =============================================================================
# STATE
# =============================================================================

## Reference to player controller
var player: PlayerController

## Seconds until another slip can happen
var micro_slip_timer: float = 0.0

## Current stability modifiers
var stability_modifiers: Dictionary = {}

## Recent micro-slips for tracking
var recent_slips: Array[float] = []

## Time window for slip tracking
var slip_tracking_window: float = 10.0

## Is player in a precarious situation
var is_precarious: bool = false

var _slip_history_timer: float = 0.0


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

	# Slips on thin footing
	micro_slip_timer = maxf(0.0, micro_slip_timer - delta)
	if micro_slip_timer <= 0.0 and _can_slip():
		var rate := TractionModel.slip_rate(player.grip_margin) * (1.0 + 0.25 * recent_slips.size())
		if randf() < rate * micro_slip_probability_scale * delta:
			_trigger_micro_slip()

	# Update precarious state
	is_precarious = player.stability < 0.5

	# Clean up old slip records
	_clean_slip_history(delta)


# =============================================================================
# STABILITY CALCULATION
# =============================================================================

## Grip left over what the slope and the pace demand (negative: cannot hold)
func compute_grip_margin() -> float:
	var cell := player.current_cell
	if cell == null:
		return 1.0

	var footwear := player.get_traction_footwear()
	var grip := TractionModel.foot_grip(
		cell.surface_type, footwear, player.get_crampon_effectiveness(), player.air_temperature)

	# Footwork suffers with tired legs and numb feet
	grip *= 1.0 - 0.12 * player.get_fatigue()
	grip *= 1.0 - 0.15 * player.get_foot_cold()

	if player.is_clinging():
		grip += TractionModel.downclimb_support(
			cell.surface_type, player.has_ice_axe(), player.get_ice_axe_effectiveness(),
			player.get_hand_dexterity(), footwear)

	# The body's own velocity, not the position delta (a teleport or respawn
	# would read as a sprint)
	var speed := minf(player.velocity.length(), 8.0)
	var demand := TractionModel.required_grip(cell.slope_angle, speed)
	return grip - demand


func _calculate_target_stability() -> float:
	stability_modifiers.clear()

	match player.current_state:
		GameEnums.PlayerMovementState.SLIDING, GameEnums.PlayerMovementState.FALLING:
			stability_modifiers["off_feet"] = -0.7
			return 0.3
		GameEnums.PlayerMovementState.ROPING:
			stability_modifiers["on_rope"] = -0.15
			return 0.85
		GameEnums.PlayerMovementState.INCAPACITATED:
			return 0.1
		GameEnums.PlayerMovementState.SKIING:
			if player.ski != null:
				var on_skis := player.ski.get_stability()
				stability_modifiers["skiing"] = on_skis - 1.0
				return on_skis
			return 0.8

	var margin := compute_grip_margin()
	player.grip_margin = margin
	var stability := minf(base_stability, TractionModel.stability_from_margin(margin))
	if stability < 1.0:
		stability_modifiers["footing"] = stability - 1.0

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

	# A drop beside you takes the confidence out of every step
	if player.current_cell:
		var cliff_dist := player.current_cell.distance_to_cliff
		if cliff_dist < 10.0:
			var cliff_penalty := (1.0 - cliff_dist / 10.0) * 0.2
			stability -= cliff_penalty
			stability_modifiers["cliff_proximity"] = -cliff_penalty

	if player.current_state == GameEnums.PlayerMovementState.RESTING:
		stability += 0.2
		stability_modifiers["resting"] = 0.2

	return clampf(stability, 0.0, 1.0)


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
# SLIPS
# =============================================================================

func _can_slip() -> bool:
	return player.current_state in [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.TRAVERSING,
	]


func _trigger_micro_slip() -> void:
	var margin := player.grip_margin
	var speed := minf(player.velocity.length(), 8.0)
	var severity := clampf(0.3 + (0.12 - margin) * 2.0 + speed * 0.05, 0.1, 1.0)

	micro_slip_timer = slip_refractory_time
	player.set_stability(player.stability - severity * 0.25)
	recent_slips.append(severity)
	player.trigger_micro_slip(severity)

	var chance := TractionModel.slip_escalation_chance(margin) * (1.0 - _catch_chance())
	if player.is_clinging():
		chance *= clinging_escalation_scale
	if randf() < chance:
		_escalate_slip(severity, margin)
		return

	# A stagger: a lurch downhill, caught
	if not player.is_clinging() and player.current_cell != null:
		player.velocity += player.current_cell.slope_direction * severity * 1.2


## Chance the axe or the other holds catch a slip before it becomes a slide
func _catch_chance() -> float:
	var cell := player.current_cell
	if cell == null:
		return 0.0
	var surface := cell.surface_type
	var axe := player.has_ice_axe()
	var axe_eff := player.get_ice_axe_effectiveness()

	if player.is_clinging():
		if axe and (TractionModel.is_snow(surface) or surface == GameEnums.SurfaceType.ICE or surface == GameEnums.SurfaceType.MIXED):
			return 0.6 * axe_eff
		if TractionModel.is_rock(surface):
			return 0.55 * player.get_hand_dexterity()
		return 0.35

	# Walking a snow slope with the shaft plunged in (self-belay)
	if axe and TractionModel.is_snow(surface) and cell.slope_angle >= 20.0:
		return 0.5 * axe_eff
	return 0.0


## The slip got away: a slide where a body cannot rest, a fall off a face,
## or just a heavy fall on the spot
func _escalate_slip(severity: float, margin: float) -> void:
	var cell := player.current_cell
	if cell == null:
		return
	var slope := cell.slope_angle
	var surface := cell.surface_type
	var body_hold := TractionModel.max_holding_slope(TractionModel.body_static_friction(surface))

	if slope >= 60.0:
		EventBus.record_incident("fall_from_slip", {
			"severity": severity, "slope": slope, "margin": margin,
			"surface": GameEnums.SurfaceType.keys()[surface]
		})
		player.say(_fall_line(surface), 2.0)
		player.trigger_fall()
	elif slope > body_hold:
		EventBus.record_incident("slide_from_slip", {
			"position": player.global_position, "slope": slope, "margin": margin,
			"surface": GameEnums.SurfaceType.keys()[surface]
		})
		player.say(_slide_line(surface), 2.0)
		player.start_slide(true, "slip")
	else:
		# Down on the ground, but the slope holds you
		micro_slip_timer = fall_over_refractory_time
		player.set_stability(player.stability - 0.3)
		player.velocity = Vector3(0.0, player.velocity.y, 0.0)
		EventBus.record_incident("fall_over", {
			"position": player.global_position, "slope": slope,
			"surface": GameEnums.SurfaceType.keys()[surface]
		})
		if TractionModel.is_rock(surface) and randf() < 0.3 and player.body_state != null:
			var part: GameEnums.BodyPart = [GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND][randi() % 2]
			var injury := Injury.new(GameEnums.InjuryType.SPRAIN, randf_range(0.1, 0.25), part, 0.0)
			player.body_state.add_injury(injury)
			EventBus.injury_occurred.emit(injury)


func _slide_line(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.ICE:
			return "Your feet skate out on the ice."
		GameEnums.SurfaceType.SCREE:
			return "The scree goes out from under you."
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET, GameEnums.SurfaceType.MIXED:
			return "A hold goes. You're tumbling."
	return "Your feet go. You're sliding."


func _fall_line(surface: GameEnums.SurfaceType) -> String:
	if surface == GameEnums.SurfaceType.ICE:
		return "The ice lets go of you."
	return "You come off the face."


func _clean_slip_history(delta: float) -> void:
	# Each slip shakes you for a while; the memory fades
	_slip_history_timer += delta
	if _slip_history_timer >= slip_tracking_window / 5.0:
		_slip_history_timer = 0.0
		if not recent_slips.is_empty():
			recent_slips.pop_front()
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
