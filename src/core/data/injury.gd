class_name Injury
extends Resource
## Represents a single injury on a body part

@export var type: GameEnums.InjuryType = GameEnums.InjuryType.NONE
@export var severity: float = 0.0  # 0.0 to 1.0
@export var location: GameEnums.BodyPart = GameEnums.BodyPart.TORSO
@export var time_occurred: float = 0.0  # Game time when injury occurred
@export var is_treated: bool = false

## Effects this injury has on player capabilities
var _cached_effects: Dictionary = {}


func _init(
	p_type: GameEnums.InjuryType = GameEnums.InjuryType.NONE,
	p_severity: float = 0.0,
	p_location: GameEnums.BodyPart = GameEnums.BodyPart.TORSO,
	p_time: float = 0.0
) -> void:
	type = p_type
	severity = p_severity
	location = p_location
	time_occurred = p_time
	_calculate_effects()


## Get the severity level enum
func get_severity_level() -> GameEnums.InjurySeverity:
	return GameEnums.get_injury_severity(severity)


## Check if this injury affects a specific capability
func affects_capability(capability: String) -> bool:
	return _cached_effects.has(capability)


## Get the modifier for a capability (1.0 = no effect, 0.0 = completely disabled)
func get_capability_modifier(capability: String) -> float:
	return _cached_effects.get(capability, 1.0)


## Get all effects as a dictionary
func get_effects() -> Dictionary:
	return _cached_effects.duplicate()


## Calculate effects based on injury type, severity, and location
func _calculate_effects() -> void:
	_cached_effects.clear()

	match type:
		GameEnums.InjuryType.SPRAIN:
			_apply_sprain_effects()
		GameEnums.InjuryType.STRAIN:
			_apply_strain_effects()
		GameEnums.InjuryType.LACERATION:
			_apply_laceration_effects()
		GameEnums.InjuryType.FRACTURE:
			_apply_fracture_effects()
		GameEnums.InjuryType.FROSTBITE:
			_apply_frostbite_effects()
		GameEnums.InjuryType.HYPOTHERMIA:
			_apply_hypothermia_effects()
		GameEnums.InjuryType.EXHAUSTION:
			_apply_exhaustion_effects()


func _apply_sprain_effects() -> void:
	var modifier := 1.0 - (severity * 0.6)

	match location:
		GameEnums.BodyPart.LEFT_FOOT, GameEnums.BodyPart.RIGHT_FOOT:
			_cached_effects["movement_speed"] = modifier
			_cached_effects["stability"] = modifier * 0.9
		GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG:
			_cached_effects["movement_speed"] = modifier
			_cached_effects["slide_control"] = modifier
		GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND:
			_cached_effects["rope_handling"] = modifier
			_cached_effects["grip_strength"] = modifier
		_:
			_cached_effects["general_mobility"] = modifier


func _apply_strain_effects() -> void:
	var modifier := 1.0 - (severity * 0.4)
	_cached_effects["fatigue_rate"] = 1.0 + (severity * 0.5)  # Increases fatigue
	_cached_effects["movement_speed"] = modifier


func _apply_laceration_effects() -> void:
	var modifier := 1.0 - (severity * 0.3)
	_cached_effects["cold_resistance"] = modifier  # Open wound = more cold exposure

	if location in [GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND]:
		_cached_effects["rope_handling"] = modifier
		_cached_effects["grip_strength"] = modifier


func _apply_fracture_effects() -> void:
	var modifier := 1.0 - (severity * 0.9)  # Fractures are severe

	match location:
		GameEnums.BodyPart.LEFT_FOOT, GameEnums.BodyPart.RIGHT_FOOT, \
		GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG:
			_cached_effects["movement_speed"] = modifier * 0.3
			_cached_effects["stability"] = modifier * 0.5
			_cached_effects["slide_control"] = modifier * 0.4
		GameEnums.BodyPart.LEFT_ARM, GameEnums.BodyPart.RIGHT_ARM, \
		GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND:
			_cached_effects["rope_handling"] = modifier * 0.2
			_cached_effects["grip_strength"] = modifier * 0.3
			_cached_effects["balance"] = modifier


func _apply_frostbite_effects() -> void:
	var modifier := 1.0 - (severity * 0.7)

	match location:
		GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND:
			_cached_effects["dexterity"] = modifier
			_cached_effects["rope_handling"] = modifier
			_cached_effects["grip_strength"] = modifier
		GameEnums.BodyPart.LEFT_FOOT, GameEnums.BodyPart.RIGHT_FOOT:
			_cached_effects["stability"] = modifier
			_cached_effects["crampon_effectiveness"] = modifier


func _apply_hypothermia_effects() -> void:
	var modifier := 1.0 - (severity * 0.8)
	_cached_effects["cognitive_speed"] = modifier
	_cached_effects["reaction_time"] = 1.0 + (severity * 1.0)  # Slower reactions
	_cached_effects["movement_speed"] = modifier
	_cached_effects["decision_making"] = modifier


func _apply_exhaustion_effects() -> void:
	_cached_effects["fatigue_rate"] = 1.0 + (severity * 1.0)
	_cached_effects["recovery_rate"] = 1.0 - (severity * 0.5)
	_cached_effects["movement_speed"] = 1.0 - (severity * 0.4)


## Get a human-readable description of the injury
func get_description() -> String:
	var severity_text := ""
	match get_severity_level():
		GameEnums.InjurySeverity.MINOR:
			severity_text = "Minor"
		GameEnums.InjurySeverity.MODERATE:
			severity_text = "Moderate"
		GameEnums.InjurySeverity.SEVERE:
			severity_text = "Severe"
		GameEnums.InjurySeverity.CRITICAL:
			severity_text = "Critical"

	var type_text := ""
	match type:
		GameEnums.InjuryType.SPRAIN:
			type_text = "sprain"
		GameEnums.InjuryType.STRAIN:
			type_text = "strain"
		GameEnums.InjuryType.LACERATION:
			type_text = "laceration"
		GameEnums.InjuryType.FRACTURE:
			type_text = "fracture"
		GameEnums.InjuryType.FROSTBITE:
			type_text = "frostbite"
		GameEnums.InjuryType.HYPOTHERMIA:
			type_text = "hypothermia"
		GameEnums.InjuryType.EXHAUSTION:
			type_text = "exhaustion"

	var location_text := _get_location_text()

	return "%s %s (%s)" % [severity_text, type_text, location_text]


func _get_location_text() -> String:
	match location:
		GameEnums.BodyPart.HEAD:
			return "head"
		GameEnums.BodyPart.TORSO:
			return "torso"
		GameEnums.BodyPart.LEFT_ARM:
			return "left arm"
		GameEnums.BodyPart.RIGHT_ARM:
			return "right arm"
		GameEnums.BodyPart.LEFT_HAND:
			return "left hand"
		GameEnums.BodyPart.RIGHT_HAND:
			return "right hand"
		GameEnums.BodyPart.LEFT_LEG:
			return "left leg"
		GameEnums.BodyPart.RIGHT_LEG:
			return "right leg"
		GameEnums.BodyPart.LEFT_FOOT:
			return "left foot"
		GameEnums.BodyPart.RIGHT_FOOT:
			return "right foot"
		_:
			return "body"
