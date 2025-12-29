class_name InjuryManager
extends Node
## Manages injury generation and tracking
## Injuries result from impacts, falls, and environmental exposure
##
## Design Philosophy:
## - Injuries are consequential and persistent
## - Location matters (leg injury vs hand injury)
## - Severity scales with force and bad luck
## - Some injuries can worsen without treatment

# =============================================================================
# SIGNALS
# =============================================================================

signal injury_occurred(injury: Injury)
signal injury_worsened(injury: Injury, old_severity: float)
signal injury_healed(injury: Injury)
signal multiple_injuries_warning(count: int)
signal incapacitating_injury(injury: Injury)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Impact Thresholds")
## Minimum force to cause injury (N)
@export var minor_impact_threshold: float = 500.0
## Force for moderate injury
@export var moderate_impact_threshold: float = 1500.0
## Force for severe injury
@export var severe_impact_threshold: float = 3000.0
## Maximum survivable force
@export var fatal_impact_threshold: float = 8000.0

@export_group("Injury Chance")
## Base chance of injury at threshold
@export var base_injury_chance: float = 0.3
## Chance increase per 100N over threshold
@export var chance_per_force: float = 0.02

@export_group("Healing")
## Base healing rate per game hour
@export var base_healing_rate: float = 0.01
## Healing rate when resting
@export var rest_healing_rate: float = 0.03
## Healing modifier when moving
@export var movement_healing_modifier: float = 0.3

# =============================================================================
# STATE
# =============================================================================

## Reference to body state
var body_state: BodyState

## Time service reference
var time_service: TimeService

## Cold exposure manager reference
var cold_manager: ColdExposureManager

## Is player currently resting
var is_resting: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("TimeService", _on_time_ready)
	ServiceLocator.get_service_async("ColdExposureManager", _on_cold_ready)
	ServiceLocator.register_service("InjuryManager", self)


func _on_time_ready(service: Object) -> void:
	time_service = service as TimeService


func _on_cold_ready(service: Object) -> void:
	cold_manager = service as ColdExposureManager


## Set body state reference
func set_body_state(state: BodyState) -> void:
	body_state = state


# =============================================================================
# INJURY GENERATION
# =============================================================================

## Process impact and potentially generate injury
func process_impact(force: float, direction: Vector3, context: Dictionary = {}) -> Injury:
	if body_state == null:
		return null

	if force < minor_impact_threshold:
		return null

	# Determine injury chance
	var chance := _calculate_injury_chance(force)

	if randf() > chance:
		return null  # Lucky, no injury

	# Generate the injury
	var injury := _generate_injury(force, direction, context)

	if injury:
		_apply_injury(injury)

	return injury


## Generate injury from slide impact
func process_slide_impact(speed: float, surface_type: GameEnums.SurfaceType) -> Injury:
	# Convert speed to approximate force (mass * deceleration)
	var estimated_mass := 80.0  # kg
	var deceleration := speed * 2.0  # Rough estimate
	var force := estimated_mass * deceleration

	var context := {
		"source": "slide",
		"surface": surface_type,
		"speed": speed
	}

	return process_impact(force, Vector3.DOWN, context)


## Generate injury from fall
func process_fall(height: float, landing_surface: GameEnums.SurfaceType) -> Injury:
	# Force = mass * g * height (simplified)
	var mass := 80.0
	var force := mass * 9.8 * height

	# Surface affects force
	match landing_surface:
		GameEnums.SurfaceType.SNOW_POWDER:
			force *= 0.5  # Soft landing
		GameEnums.SurfaceType.SNOW_SOFT:
			force *= 0.7
		GameEnums.SurfaceType.SNOW_FIRM:
			force *= 0.9
		GameEnums.SurfaceType.ICE, GameEnums.SurfaceType.ROCK:
			force *= 1.2  # Hard landing

	var context := {
		"source": "fall",
		"height": height,
		"surface": landing_surface
	}

	return process_impact(force, Vector3.DOWN, context)


## Generate frostbite from cold exposure
func process_frostbite(body_part: GameEnums.BodyPart) -> Injury:
	if body_state == null:
		return null

	var cold := body_state.extremity_cold.get(body_part, 0.0)
	if cold < 0.8:
		return null

	# Severity based on cold level
	var severity := (cold - 0.8) / 0.2  # 0-1 scale above threshold

	var injury := Injury.new(
		GameEnums.InjuryType.FROSTBITE,
		severity,
		body_part,
		time_service.current_time if time_service else 0.0
	)

	_apply_injury(injury)
	return injury


func _calculate_injury_chance(force: float) -> float:
	var chance := base_injury_chance

	# Force over threshold increases chance
	var excess_force := force - minor_impact_threshold
	chance += excess_force / 100.0 * chance_per_force

	# Fatigue increases injury chance
	if body_state:
		chance *= 1.0 + body_state.fatigue * 0.5

	return clampf(chance, 0.0, 0.95)


func _generate_injury(force: float, direction: Vector3, context: Dictionary) -> Injury:
	var injury_type := _determine_injury_type(force, context)
	var severity := _calculate_severity(force)
	var location := _determine_location(direction, context)

	var current_time := 0.0
	if time_service:
		current_time = time_service.current_time

	return Injury.new(injury_type, severity, location, current_time)


func _determine_injury_type(force: float, context: Dictionary) -> GameEnums.InjuryType:
	var source: String = context.get("source", "impact")

	if force > severe_impact_threshold:
		# High force = fracture likely
		if randf() < 0.6:
			return GameEnums.InjuryType.FRACTURE
		else:
			return GameEnums.InjuryType.LACERATION
	elif force > moderate_impact_threshold:
		# Moderate force = sprains common
		var roll := randf()
		if roll < 0.5:
			return GameEnums.InjuryType.SPRAIN
		elif roll < 0.8:
			return GameEnums.InjuryType.STRAIN
		else:
			return GameEnums.InjuryType.LACERATION
	else:
		# Minor force = strains
		if randf() < 0.7:
			return GameEnums.InjuryType.STRAIN
		else:
			return GameEnums.InjuryType.SPRAIN


func _calculate_severity(force: float) -> float:
	if force >= fatal_impact_threshold:
		return 1.0

	# Scale severity based on force
	var base_severity := 0.0

	if force > severe_impact_threshold:
		base_severity = 0.7 + (force - severe_impact_threshold) / (fatal_impact_threshold - severe_impact_threshold) * 0.3
	elif force > moderate_impact_threshold:
		base_severity = 0.4 + (force - moderate_impact_threshold) / (severe_impact_threshold - moderate_impact_threshold) * 0.3
	else:
		base_severity = 0.1 + (force - minor_impact_threshold) / (moderate_impact_threshold - minor_impact_threshold) * 0.3

	# Add some randomness
	base_severity *= 0.8 + randf() * 0.4

	return clampf(base_severity, 0.1, 1.0)


func _determine_location(direction: Vector3, context: Dictionary) -> GameEnums.BodyPart:
	var source: String = context.get("source", "impact")

	# Fall = usually legs
	if source == "fall":
		var roll := randf()
		if roll < 0.4:
			return GameEnums.BodyPart.LEFT_FOOT if randf() < 0.5 else GameEnums.BodyPart.RIGHT_FOOT
		elif roll < 0.7:
			return GameEnums.BodyPart.LEFT_LEG if randf() < 0.5 else GameEnums.BodyPart.RIGHT_LEG
		elif roll < 0.85:
			return GameEnums.BodyPart.LEFT_ARM if randf() < 0.5 else GameEnums.BodyPart.RIGHT_ARM
		else:
			return GameEnums.BodyPart.TORSO

	# Slide = legs and arms from catching
	if source == "slide":
		var roll := randf()
		if roll < 0.3:
			return GameEnums.BodyPart.LEFT_LEG if randf() < 0.5 else GameEnums.BodyPart.RIGHT_LEG
		elif roll < 0.6:
			return GameEnums.BodyPart.LEFT_ARM if randf() < 0.5 else GameEnums.BodyPart.RIGHT_ARM
		elif roll < 0.8:
			return GameEnums.BodyPart.LEFT_HAND if randf() < 0.5 else GameEnums.BodyPart.RIGHT_HAND
		else:
			return GameEnums.BodyPart.TORSO

	# Default distribution
	var parts := [
		GameEnums.BodyPart.LEFT_LEG,
		GameEnums.BodyPart.RIGHT_LEG,
		GameEnums.BodyPart.LEFT_ARM,
		GameEnums.BodyPart.RIGHT_ARM,
		GameEnums.BodyPart.TORSO
	]
	return parts[randi() % parts.size()]


func _apply_injury(injury: Injury) -> void:
	body_state.add_injury(injury)
	injury_occurred.emit(injury)
	EventBus.injury_occurred.emit(injury)

	# Check for multiple injuries
	if body_state.injuries.size() >= 3:
		multiple_injuries_warning.emit(body_state.injuries.size())

	# Check for incapacitating injury
	if injury.severity >= 0.8:
		incapacitating_injury.emit(injury)

	EventBus.record_incident("injury", {
		"type": GameEnums.InjuryType.keys()[injury.type],
		"severity": injury.severity,
		"location": GameEnums.BodyPart.keys()[injury.location]
	})


# =============================================================================
# INJURY PROGRESSION
# =============================================================================

func _physics_process(delta: float) -> void:
	if body_state == null:
		return

	# Process healing and worsening
	_process_injuries(delta)


func _process_injuries(delta: float) -> void:
	var to_remove: Array[Injury] = []

	for injury in body_state.injuries:
		# Check for worsening conditions
		if _should_worsen(injury):
			var old_severity := injury.severity
			injury.severity = minf(1.0, injury.severity + 0.01)
			injury_worsened.emit(injury, old_severity)
		else:
			# Apply healing
			var healing := _calculate_healing_rate() * delta / 3600.0  # Per hour to per second
			injury.severity = maxf(0.0, injury.severity - healing)

		# Check if healed
		if injury.severity <= 0.0:
			to_remove.append(injury)
			injury_healed.emit(injury)

	# Remove healed injuries
	for injury in to_remove:
		body_state.injuries.erase(injury)


func _should_worsen(injury: Injury) -> bool:
	# Untreated severe injuries may worsen
	if injury.is_treated:
		return false

	if injury.severity < 0.5:
		return false

	# Moving with bad injury = worse
	if not is_resting and injury.severity > 0.6:
		return randf() < 0.001  # Small chance per frame

	return false


func _calculate_healing_rate() -> float:
	var rate := base_healing_rate

	if is_resting:
		rate = rest_healing_rate
	else:
		rate *= movement_healing_modifier

	# Cold slows healing
	if body_state.cold_exposure > 0.3:
		rate *= 1.0 - body_state.cold_exposure * 0.5

	return rate


# =============================================================================
# INPUT FROM OTHER SYSTEMS
# =============================================================================

## Set resting state
func set_resting(resting: bool) -> void:
	is_resting = resting


## Treat an injury (reduces severity, prevents worsening)
func treat_injury(injury: Injury) -> void:
	injury.is_treated = true
	injury.severity *= 0.8  # Treatment helps


# =============================================================================
# QUERIES
# =============================================================================

## Get all current injuries
func get_injuries() -> Array[Injury]:
	if body_state:
		return body_state.injuries
	return []


## Get total injury severity
func get_total_severity() -> float:
	if body_state:
		return body_state.get_total_injury_severity()
	return 0.0


## Get most severe injury
func get_worst_injury() -> Injury:
	if body_state == null or body_state.injuries.is_empty():
		return null

	var worst: Injury = body_state.injuries[0]
	for injury in body_state.injuries:
		if injury.severity > worst.severity:
			worst = injury
	return worst


## Check if any limb is severely injured
func has_limb_injury() -> bool:
	for injury in get_injuries():
		if injury.severity > 0.5:
			if injury.location in [
				GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG,
				GameEnums.BodyPart.LEFT_ARM, GameEnums.BodyPart.RIGHT_ARM
			]:
				return true
	return false


## Get movement penalty from injuries
func get_movement_penalty() -> float:
	var penalty := 0.0

	for injury in get_injuries():
		var modifier := injury.get_capability_modifier("movement_speed")
		if modifier < 1.0:
			penalty += 1.0 - modifier

	return clampf(penalty, 0.0, 0.8)


## Check if can continue descent
func can_continue() -> bool:
	if get_total_severity() >= 2.0:
		return false

	var worst := get_worst_injury()
	if worst and worst.severity >= 0.9:
		return false

	return true


## Get summary for debug/UI
func get_summary() -> Dictionary:
	return {
		"injury_count": get_injuries().size(),
		"total_severity": get_total_severity(),
		"worst_injury": get_worst_injury().get_description() if get_worst_injury() else "None",
		"movement_penalty": get_movement_penalty(),
		"can_continue": can_continue()
	}
