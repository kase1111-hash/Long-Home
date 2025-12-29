class_name Rope
extends Resource
## Rope data structure
## Represents a single rope with its properties and state
##
## Design Philosophy:
## - Rope is a tool, not an ability
## - Has physical properties that affect gameplay
## - Condition degrades with use and environment
## - Weight affects player movement and fatigue

# =============================================================================
# PROPERTIES
# =============================================================================

## Unique identifier for this rope
@export var id: String = ""

## Total length in meters
@export var total_length: float = 50.0

## Current available length (may be less if partially deployed)
@export var available_length: float = 50.0

## Rope condition (0-1, affects reliability)
@export var condition: float = 1.0

## Base weight in kg
@export var base_weight: float = 3.5

## Rope diameter in mm (affects handling, durability)
@export var diameter: float = 10.0

## Is the rope currently deployed
@export var is_deployed: bool = false

## Length currently deployed
@export var deployed_length: float = 0.0

## Number of times used this descent
@export var use_count: int = 0

## Has rope been wet (affects handling)
@export var is_wet: bool = false

## Is rope frozen (severely affects handling)
@export var is_frozen: bool = false


# =============================================================================
# DERIVED PROPERTIES
# =============================================================================

## Get current weight (includes water if wet)
func get_weight() -> float:
	var weight := base_weight

	# Wet rope is heavier
	if is_wet:
		weight *= 1.3

	# Frozen rope is slightly heavier
	if is_frozen:
		weight *= 1.1

	return weight


## Get handling difficulty modifier (0 = easy, 1 = very difficult)
func get_handling_difficulty() -> float:
	var difficulty := 0.0

	# Thick rope is harder to handle
	if diameter > 10.0:
		difficulty += (diameter - 10.0) * 0.05

	# Wet rope is slippery
	if is_wet:
		difficulty += 0.2

	# Frozen rope is stiff and very difficult
	if is_frozen:
		difficulty += 0.4

	# Poor condition makes handling unpredictable
	difficulty += (1.0 - condition) * 0.3

	return clampf(difficulty, 0.0, 1.0)


## Get reliability (chance operations succeed)
func get_reliability() -> float:
	var reliability := condition

	# Wet reduces reliability slightly
	if is_wet:
		reliability *= 0.95

	# Frozen significantly reduces reliability
	if is_frozen:
		reliability *= 0.7

	# Each use slightly degrades expected reliability
	reliability -= use_count * 0.01

	return clampf(reliability, 0.1, 1.0)


## Get stretch factor (dynamic ropes stretch more)
func get_stretch_factor() -> float:
	# Thinner ropes stretch more
	var stretch := 0.1 - (diameter - 8.0) * 0.01
	return clampf(stretch, 0.02, 0.15)


# =============================================================================
# OPERATIONS
# =============================================================================

## Deploy rope for use
func deploy(length: float) -> bool:
	if is_deployed:
		return false

	if length > available_length:
		length = available_length

	is_deployed = true
	deployed_length = length
	use_count += 1

	return true


## Recover rope after use
func recover() -> void:
	is_deployed = false
	deployed_length = 0.0

	# Slight condition degradation from use
	condition = maxf(0.0, condition - 0.02)


## Apply environmental effects
func apply_environment(temperature: float, is_snowing: bool, is_in_water: bool) -> void:
	# Freezing
	if temperature < -5.0:
		is_frozen = true
	elif temperature > 5.0:
		is_frozen = false

	# Wetting
	if is_in_water or (is_snowing and temperature > -2.0):
		is_wet = true

	# Drying (very slow at altitude)
	if not is_in_water and not is_snowing and temperature > 10.0:
		is_wet = false


## Damage rope from abrasion or impact
func apply_damage(amount: float) -> void:
	condition = maxf(0.0, condition - amount)

	# Severe damage may reduce available length
	if condition < 0.3 and randf() < 0.1:
		available_length = maxf(0.0, available_length - 5.0)


## Check if rope is safe to use
func is_safe() -> bool:
	return condition > 0.2 and available_length > 5.0


## Check if rope needs inspection
func needs_inspection() -> bool:
	return condition < 0.5 or use_count > 5


# =============================================================================
# FACTORY
# =============================================================================

static func create_standard() -> Rope:
	var rope := Rope.new()
	rope.id = "rope_%d" % randi()
	rope.total_length = 50.0
	rope.available_length = 50.0
	rope.condition = 1.0
	rope.base_weight = 3.5
	rope.diameter = 10.0
	return rope


static func create_lightweight() -> Rope:
	var rope := Rope.new()
	rope.id = "rope_%d" % randi()
	rope.total_length = 40.0
	rope.available_length = 40.0
	rope.condition = 1.0
	rope.base_weight = 2.5
	rope.diameter = 8.5
	return rope


static func create_heavy_duty() -> Rope:
	var rope := Rope.new()
	rope.id = "rope_%d" % randi()
	rope.total_length = 60.0
	rope.available_length = 60.0
	rope.condition = 1.0
	rope.base_weight = 4.5
	rope.diameter = 11.0
	return rope
