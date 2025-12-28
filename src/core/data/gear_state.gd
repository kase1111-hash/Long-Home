class_name GearState
extends Resource
## Represents the player's equipment and its condition

# =============================================================================
# GEAR ITEMS
# =============================================================================

## Dictionary of gear type to GearItem
var items: Dictionary = {}

## Total weight of all gear in kg
var total_weight: float = 0.0


# =============================================================================
# GEAR ITEM CLASS
# =============================================================================

class GearItem:
	var type: GameEnums.GearType
	var condition: GameEnums.GearCondition
	var condition_value: float  # 0.0 to 1.0
	var weight: float  # in kg
	var is_equipped: bool
	var properties: Dictionary  # Type-specific properties

	func _init(
		p_type: GameEnums.GearType,
		p_condition: float = 1.0,
		p_weight: float = 0.0
	) -> void:
		type = p_type
		condition_value = p_condition
		weight = p_weight
		is_equipped = true
		properties = {}
		_update_condition_enum()
		_set_default_properties()

	func _update_condition_enum() -> void:
		if condition_value >= 0.9:
			condition = GameEnums.GearCondition.PRISTINE
		elif condition_value >= 0.7:
			condition = GameEnums.GearCondition.GOOD
		elif condition_value >= 0.4:
			condition = GameEnums.GearCondition.WORN
		elif condition_value >= 0.1:
			condition = GameEnums.GearCondition.DAMAGED
		else:
			condition = GameEnums.GearCondition.BROKEN

	func _set_default_properties() -> void:
		match type:
			GameEnums.GearType.ROPE:
				properties["length"] = 60.0  # meters
				properties["diameter"] = 9.5  # mm
			GameEnums.GearType.CRAMPONS:
				properties["points"] = 12
				properties["type"] = "hybrid"  # or "step-in"
			GameEnums.GearType.ICE_AXE:
				properties["length"] = 60  # cm
				properties["type"] = "technical"
			GameEnums.GearType.LAYERS:
				properties["warmth"] = 0.8
				properties["breathability"] = 0.6
			GameEnums.GearType.GLOVES:
				properties["warmth"] = 0.7
				properties["dexterity"] = 0.8

	func damage(amount: float) -> void:
		condition_value = maxf(0.0, condition_value - amount)
		_update_condition_enum()

	func is_functional() -> bool:
		return condition != GameEnums.GearCondition.BROKEN

	func get_effectiveness() -> float:
		# Gear effectiveness degrades with condition
		match condition:
			GameEnums.GearCondition.PRISTINE:
				return 1.0
			GameEnums.GearCondition.GOOD:
				return 0.9
			GameEnums.GearCondition.WORN:
				return 0.7
			GameEnums.GearCondition.DAMAGED:
				return 0.4
			GameEnums.GearCondition.BROKEN:
				return 0.0
		return 0.5


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	_calculate_total_weight()


## Create a standard loadout
static func create_standard_loadout() -> GearState:
	var state := GearState.new()

	state.add_item(GearItem.new(GameEnums.GearType.ROPE, 1.0, 4.5))
	state.add_item(GearItem.new(GameEnums.GearType.CRAMPONS, 1.0, 1.0))
	state.add_item(GearItem.new(GameEnums.GearType.ICE_AXE, 1.0, 0.5))
	state.add_item(GearItem.new(GameEnums.GearType.HELMET, 1.0, 0.4))
	state.add_item(GearItem.new(GameEnums.GearType.HARNESS, 1.0, 0.5))
	state.add_item(GearItem.new(GameEnums.GearType.CARABINERS, 1.0, 0.3))
	state.add_item(GearItem.new(GameEnums.GearType.ANCHOR_KIT, 1.0, 0.8))
	state.add_item(GearItem.new(GameEnums.GearType.LAYERS, 1.0, 2.0))
	state.add_item(GearItem.new(GameEnums.GearType.GLOVES, 1.0, 0.2))
	state.add_item(GearItem.new(GameEnums.GearType.GOGGLES, 1.0, 0.1))

	return state


## Create a light/fast loadout
static func create_light_loadout() -> GearState:
	var state := GearState.new()

	state.add_item(GearItem.new(GameEnums.GearType.CRAMPONS, 1.0, 0.8))
	state.add_item(GearItem.new(GameEnums.GearType.ICE_AXE, 1.0, 0.4))
	state.add_item(GearItem.new(GameEnums.GearType.LAYERS, 0.9, 1.5))
	state.add_item(GearItem.new(GameEnums.GearType.GLOVES, 0.9, 0.15))

	return state


## Create a heavy/safe loadout
static func create_heavy_loadout() -> GearState:
	var state := GearState.new()

	state.add_item(GearItem.new(GameEnums.GearType.ROPE, 1.0, 5.5))  # Longer rope
	state.add_item(GearItem.new(GameEnums.GearType.CRAMPONS, 1.0, 1.2))
	state.add_item(GearItem.new(GameEnums.GearType.ICE_AXE, 1.0, 0.6))
	state.add_item(GearItem.new(GameEnums.GearType.HELMET, 1.0, 0.5))
	state.add_item(GearItem.new(GameEnums.GearType.HARNESS, 1.0, 0.6))
	state.add_item(GearItem.new(GameEnums.GearType.CARABINERS, 1.0, 0.5))
	state.add_item(GearItem.new(GameEnums.GearType.ANCHOR_KIT, 1.0, 1.2))
	state.add_item(GearItem.new(GameEnums.GearType.BIVY_GEAR, 1.0, 2.5))
	state.add_item(GearItem.new(GameEnums.GearType.LAYERS, 1.0, 2.5))
	state.add_item(GearItem.new(GameEnums.GearType.GLOVES, 1.0, 0.3))
	state.add_item(GearItem.new(GameEnums.GearType.GOGGLES, 1.0, 0.15))

	return state


# =============================================================================
# ITEM MANAGEMENT
# =============================================================================

func add_item(item: GearItem) -> void:
	items[item.type] = item
	_calculate_total_weight()


func remove_item(type: GameEnums.GearType) -> void:
	items.erase(type)
	_calculate_total_weight()


func has_item(type: GameEnums.GearType) -> bool:
	return items.has(type) and items[type].is_functional()


func get_item(type: GameEnums.GearType) -> GearItem:
	return items.get(type, null)


func damage_item(type: GameEnums.GearType, amount: float) -> void:
	if items.has(type):
		items[type].damage(amount)


func _calculate_total_weight() -> void:
	total_weight = 0.0
	for item in items.values():
		if item.is_equipped:
			total_weight += item.weight


# =============================================================================
# CAPABILITY QUERIES
# =============================================================================

## Get rope if available and functional
func get_rope() -> GearItem:
	if has_item(GameEnums.GearType.ROPE):
		return items[GameEnums.GearType.ROPE]
	return null


## Get available rope length
func get_rope_length() -> float:
	var rope := get_rope()
	if rope:
		return rope.properties.get("length", 0.0)
	return 0.0


## Check if crampons are equipped and functional
func has_crampons() -> bool:
	return has_item(GameEnums.GearType.CRAMPONS)


## Get crampon effectiveness
func get_crampon_effectiveness() -> float:
	if has_crampons():
		return items[GameEnums.GearType.CRAMPONS].get_effectiveness()
	return 0.0


## Check if ice axe is available
func has_ice_axe() -> bool:
	return has_item(GameEnums.GearType.ICE_AXE)


## Get ice axe effectiveness (for self-arrest)
func get_ice_axe_effectiveness() -> float:
	if has_ice_axe():
		return items[GameEnums.GearType.ICE_AXE].get_effectiveness()
	return 0.0


## Check if bivy gear is available
func has_bivy_gear() -> bool:
	return has_item(GameEnums.GearType.BIVY_GEAR)


## Get warmth rating from layers
func get_warmth_rating() -> float:
	var warmth := 0.3  # Base warmth

	if has_item(GameEnums.GearType.LAYERS):
		var layers := items[GameEnums.GearType.LAYERS]
		warmth += layers.properties.get("warmth", 0.5) * layers.get_effectiveness()

	if has_item(GameEnums.GearType.GLOVES):
		var gloves := items[GameEnums.GearType.GLOVES]
		warmth += gloves.properties.get("warmth", 0.3) * gloves.get_effectiveness() * 0.2

	return clampf(warmth, 0.0, 1.0)


## Get weight penalty for movement (higher weight = slower, more momentum)
func get_weight_modifier() -> float:
	# Base weight is around 5kg, heavy is 15kg+
	if total_weight <= 5.0:
		return 1.0
	elif total_weight <= 10.0:
		return 0.95 - ((total_weight - 5.0) * 0.02)
	else:
		return 0.85 - ((total_weight - 10.0) * 0.03)


## Get momentum modifier for sliding (heavier = more momentum)
func get_momentum_modifier() -> float:
	return 0.8 + (total_weight / 50.0)  # 0.8 at 0kg, 1.1 at 15kg


# =============================================================================
# SERIALIZATION
# =============================================================================

func duplicate_state() -> GearState:
	var copy := GearState.new()
	for type in items:
		var original: GearItem = items[type]
		var item_copy := GearItem.new(original.type, original.condition_value, original.weight)
		item_copy.is_equipped = original.is_equipped
		item_copy.properties = original.properties.duplicate()
		copy.items[type] = item_copy
	copy._calculate_total_weight()
	return copy
