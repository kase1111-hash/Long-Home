class_name BodyState
extends Resource
## Represents the player's physical condition

# =============================================================================
# CORE STATS (0.0 to 1.0 where applicable)
# =============================================================================

## Overall fatigue level (0 = fresh, 1 = collapsed)
@export_range(0.0, 1.0) var fatigue: float = 0.0

## Cold exposure level (0 = warm, 1 = hypothermic)
@export_range(0.0, 1.0) var cold_exposure: float = 0.0

## Hydration level (1 = fully hydrated, 0 = severely dehydrated)
@export_range(0.0, 1.0) var hydration: float = 1.0

## Mental state / focus (1 = sharp, 0 = impaired)
@export_range(0.0, 1.0) var mental_state: float = 1.0

## List of current injuries
@export var injuries: Array[Injury] = []

# =============================================================================
# BODY PART SPECIFIC STATES
# =============================================================================

## Cold exposure per body part (for frostbite tracking)
var extremity_cold: Dictionary = {
	GameEnums.BodyPart.LEFT_HAND: 0.0,
	GameEnums.BodyPart.RIGHT_HAND: 0.0,
	GameEnums.BodyPart.LEFT_FOOT: 0.0,
	GameEnums.BodyPart.RIGHT_FOOT: 0.0,
}

# =============================================================================
# COMPUTED PROPERTIES
# =============================================================================

## Get effective movement speed modifier (0-1)
func get_movement_modifier() -> float:
	var modifier := 1.0

	# Fatigue effect
	if fatigue > GameEnums.FATIGUE_THRESHOLDS.movement_slow:
		modifier *= 1.0 - ((fatigue - 0.5) * 0.6)

	# Hydration effect
	modifier *= 0.7 + (hydration * 0.3)

	# Injury effects
	for injury in injuries:
		modifier *= injury.get_capability_modifier("movement_speed")

	return clampf(modifier, 0.1, 1.0)


## Get effective stability modifier (0-1)
func get_stability_modifier() -> float:
	var modifier := 1.0

	# Fatigue effect on stability
	modifier *= 1.0 - (fatigue * 0.3)

	# Mental state affects balance
	modifier *= 0.8 + (mental_state * 0.2)

	# Injury effects
	for injury in injuries:
		modifier *= injury.get_capability_modifier("stability")

	return clampf(modifier, 0.1, 1.0)


## Get effective rope handling modifier (0-1)
func get_rope_handling_modifier() -> float:
	var modifier := 1.0

	# Hand cold affects dexterity
	var hand_cold := maxf(
		extremity_cold.get(GameEnums.BodyPart.LEFT_HAND, 0.0),
		extremity_cold.get(GameEnums.BodyPart.RIGHT_HAND, 0.0)
	)
	modifier *= 1.0 - (hand_cold * 0.5)

	# Fatigue affects precision
	modifier *= 1.0 - (fatigue * 0.2)

	# Injury effects - use additive penalty to avoid exponential stacking
	var injury_penalty := 0.0
	for injury in injuries:
		# Take the worse of rope_handling or dexterity modifier per injury
		var rope_mod := injury.get_capability_modifier("rope_handling")
		var dex_mod := injury.get_capability_modifier("dexterity")
		injury_penalty += (1.0 - minf(rope_mod, dex_mod))
	modifier *= maxf(0.1, 1.0 - injury_penalty)

	return clampf(modifier, 0.1, 1.0)


## Get effective slide control modifier (0-1)
func get_slide_control_modifier() -> float:
	var modifier := 1.0

	# Fatigue significantly affects slide control
	modifier *= 1.0 - (fatigue * 0.4)

	# Foot cold affects edge control
	var foot_cold := maxf(
		extremity_cold.get(GameEnums.BodyPart.LEFT_FOOT, 0.0),
		extremity_cold.get(GameEnums.BodyPart.RIGHT_FOOT, 0.0)
	)
	modifier *= 1.0 - (foot_cold * 0.3)

	# Injury effects
	for injury in injuries:
		modifier *= injury.get_capability_modifier("slide_control")

	return clampf(modifier, 0.1, 1.0)


## Get input delay in seconds (fatigue causes delayed responses)
func get_input_delay() -> float:
	var delay := 0.0

	if fatigue > GameEnums.FATIGUE_THRESHOLDS.input_delay:
		delay += (fatigue - 0.7) * 0.3  # Up to 0.09s delay at max fatigue

	# Hypothermia slows reactions
	if cold_exposure > 0.7:
		delay += (cold_exposure - 0.7) * 0.2

	# Injury effects
	for injury in injuries:
		var reaction_modifier := injury.get_capability_modifier("reaction_time")
		if reaction_modifier > 1.0:
			delay += (reaction_modifier - 1.0) * 0.1

	return delay


## Get camera sway amount (fatigue causes visual instability)
func get_camera_sway() -> float:
	var sway := 0.0

	if fatigue > GameEnums.FATIGUE_THRESHOLDS.breathing_change:
		sway += (fatigue - 0.3) * 0.5

	# Low blood sugar / dehydration
	sway += (1.0 - hydration) * 0.2

	return clampf(sway, 0.0, 1.0)


## Get fatigue accumulation rate modifier
func get_fatigue_rate_modifier() -> float:
	var modifier := 1.0

	# Dehydration increases fatigue rate
	modifier += (1.0 - hydration) * 0.5

	# Cold increases fatigue rate
	modifier += cold_exposure * 0.3

	# Injury effects
	for injury in injuries:
		modifier *= injury.get_capability_modifier("fatigue_rate")

	return modifier


## Get total injury severity (sum of all injuries)
func get_total_injury_severity() -> float:
	var total := 0.0
	for injury in injuries:
		total += injury.severity
	return total


## Check if body state is critical
func is_critical() -> bool:
	return fatigue >= GameEnums.FATIGUE_THRESHOLDS.critical \
		or cold_exposure >= 0.9 \
		or hydration <= 0.1 \
		or get_total_injury_severity() >= 1.5


## Check if body state would cause collapse
func would_collapse() -> bool:
	return fatigue >= GameEnums.FATIGUE_THRESHOLDS.collapse \
		or cold_exposure >= 1.0 \
		or get_total_injury_severity() >= 2.0

# =============================================================================
# MODIFICATION METHODS
# =============================================================================

## Add fatigue (respects modifiers and clamps)
func add_fatigue(amount: float) -> void:
	var modified_amount := amount * get_fatigue_rate_modifier()
	fatigue = clampf(fatigue + modified_amount, 0.0, 1.0)


## Recover fatigue (slower when injured/cold)
func recover_fatigue(amount: float) -> void:
	var recovery_modifier := 1.0

	# Cold slows recovery
	recovery_modifier *= 1.0 - (cold_exposure * 0.5)

	# Injuries slow recovery
	for injury in injuries:
		recovery_modifier *= injury.get_capability_modifier("recovery_rate")

	fatigue = clampf(fatigue - (amount * recovery_modifier), 0.0, 1.0)


## Add cold exposure
func add_cold_exposure(amount: float, body_part: GameEnums.BodyPart = GameEnums.BodyPart.TORSO) -> void:
	# Global cold exposure
	cold_exposure = clampf(cold_exposure + amount, 0.0, 1.0)

	# Extremity-specific cold (faster than core)
	if extremity_cold.has(body_part):
		extremity_cold[body_part] = clampf(
			extremity_cold[body_part] + (amount * 1.5),
			0.0, 1.0
		)


## Add an injury
func add_injury(injury: Injury) -> void:
	injuries.append(injury)


## Get diegetic status messages for self-check
func get_status_messages() -> Array[String]:
	var messages: Array[String] = []

	# Fatigue messages
	if fatigue > 0.9:
		messages.append("Body screaming for rest. Can barely stand.")
	elif fatigue > 0.7:
		messages.append("Legs burning. Pace unsustainable.")
	elif fatigue > 0.5:
		messages.append("Breathing hard. Need to slow down.")
	elif fatigue > 0.3:
		messages.append("Starting to feel the effort.")

	# Cold messages
	if cold_exposure > 0.8:
		messages.append("Core temperature dropping. Critical.")
	elif cold_exposure > 0.5:
		messages.append("Cold seeping in. Need to keep moving.")

	# Extremity cold
	var worst_hand := maxf(
		extremity_cold.get(GameEnums.BodyPart.LEFT_HAND, 0.0),
		extremity_cold.get(GameEnums.BodyPart.RIGHT_HAND, 0.0)
	)
	if worst_hand > 0.7:
		messages.append("Fingers going numb. Losing dexterity.")
	elif worst_hand > 0.4:
		messages.append("Hands getting cold.")

	var worst_foot := maxf(
		extremity_cold.get(GameEnums.BodyPart.LEFT_FOOT, 0.0),
		extremity_cold.get(GameEnums.BodyPart.RIGHT_FOOT, 0.0)
	)
	if worst_foot > 0.7:
		messages.append("Can't feel my feet properly.")

	# Hydration
	if hydration < 0.3:
		messages.append("Desperately thirsty. Thinking getting foggy.")
	elif hydration < 0.5:
		messages.append("Need water soon.")

	# Injuries
	for injury in injuries:
		if injury.severity > 0.5:
			messages.append(injury.get_description() + " - limiting movement.")

	if messages.is_empty():
		messages.append("Holding up okay. Stay focused.")

	return messages


## Create a copy of this body state
func duplicate_state() -> BodyState:
	var copy := BodyState.new()
	copy.fatigue = fatigue
	copy.cold_exposure = cold_exposure
	copy.hydration = hydration
	copy.mental_state = mental_state
	copy.extremity_cold = extremity_cold.duplicate()

	for injury in injuries:
		copy.injuries.append(injury.duplicate())

	return copy
