class_name GearDatabase
extends Node
## Database of available gear items
## Provides metadata for gear selection UI
##
## Design Philosophy:
## - Every gram matters on the mountain
## - Trade-offs between safety and speed
## - No perfect loadout, only informed choices

# =============================================================================
# SIGNALS
# =============================================================================

signal database_loaded()

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class GearItemInfo:
	## Gear type enum value
	var type: GameEnums.GearType
	## Display name
	var name: String
	## Category for grouping
	var category: String
	## Description
	var description: String
	## Base weight in kg
	var base_weight: float
	## Whether this is essential (always included)
	var is_essential: bool
	## Variants available
	var variants: Array[Dictionary] = []

	func _init(
		p_type: GameEnums.GearType,
		p_name: String,
		p_category: String,
		p_description: String,
		p_weight: float,
		p_essential: bool = false
	) -> void:
		type = p_type
		name = p_name
		category = p_category
		description = p_description
		base_weight = p_weight
		is_essential = p_essential


# =============================================================================
# CATEGORIES
# =============================================================================

const CATEGORY_PROTECTION := "Protection"
const CATEGORY_TECHNICAL := "Technical"
const CATEGORY_CLOTHING := "Clothing"
const CATEGORY_SURVIVAL := "Survival"
const CATEGORY_DESCENT := "Ski & Board"
const CATEGORY_NAVIGATION := "Navigation"
const CATEGORY_AVALANCHE := "Avalanche"

const CATEGORY_ORDER := [
	CATEGORY_PROTECTION,
	CATEGORY_TECHNICAL,
	CATEGORY_DESCENT,
	CATEGORY_NAVIGATION,
	CATEGORY_AVALANCHE,
	CATEGORY_CLOTHING,
	CATEGORY_SURVIVAL
]

## Gear that cannot be carried together (one way down on the snow)
const EXCLUSIVE_GEAR := {
	GameEnums.GearType.SKIS: GameEnums.GearType.SNOWBOARD,
	GameEnums.GearType.SNOWBOARD: GameEnums.GearType.SKIS,
}

# =============================================================================
# STATE
# =============================================================================

## All gear item info
var items: Dictionary = {}  # GearType -> GearItemInfo

## Is database loaded
var is_loaded: bool = false

# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("GearDatabase", self)
	_load_gear_data()
	print("[GearDatabase] Initialized with %d items" % items.size())


func _load_gear_data() -> void:
	# Protection Category
	_add_item(GearItemInfo.new(
		GameEnums.GearType.HELMET,
		"Helmet",
		CATEGORY_PROTECTION,
		"Protects against rockfall and impact. Essential for technical terrain.",
		0.4,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.GOGGLES,
		"Goggles",
		CATEGORY_PROTECTION,
		"Eye protection from wind, snow, and glare. Crucial in storms.",
		0.1,
		false
	))

	# Technical Category
	_add_item(GearItemInfo.new(
		GameEnums.GearType.ROPE,
		"Rope",
		CATEGORY_TECHNICAL,
		"60m dynamic rope for rappels and belays. Weight penalty but enables technical terrain.",
		4.5,
		false
	))
	items[GameEnums.GearType.ROPE].variants.assign([
		{"name": "Light (50m)", "weight": 3.5, "length": 50.0},
		{"name": "Standard (60m)", "weight": 4.5, "length": 60.0},
		{"name": "Long (70m)", "weight": 5.5, "length": 70.0}
	])

	_add_item(GearItemInfo.new(
		GameEnums.GearType.HARNESS,
		"Harness",
		CATEGORY_TECHNICAL,
		"Alpine harness for rope work. Required for rappelling.",
		0.5,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.CARABINERS,
		"Carabiners",
		CATEGORY_TECHNICAL,
		"Set of locking carabiners for anchors and rappels.",
		0.3,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.ANCHOR_KIT,
		"Anchor Kit",
		CATEGORY_TECHNICAL,
		"Ice screws and slings for building rappel anchors.",
		0.8,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.CRAMPONS,
		"Crampons",
		CATEGORY_TECHNICAL,
		"12-point steel crampons for ice and hard snow. Critical for steep terrain.",
		1.0,
		true
	))
	items[GameEnums.GearType.CRAMPONS].variants.assign([
		{"name": "Light Aluminum", "weight": 0.8, "durability": 0.7},
		{"name": "Steel Hybrid", "weight": 1.0, "durability": 1.0},
		{"name": "Heavy Steel", "weight": 1.2, "durability": 1.2}
	])

	_add_item(GearItemInfo.new(
		GameEnums.GearType.ICE_AXE,
		"Ice Axe",
		CATEGORY_TECHNICAL,
		"Technical axe for self-arrest and climbing. Your lifeline on steep slopes.",
		0.5,
		true
	))
	items[GameEnums.GearType.ICE_AXE].variants.assign([
		{"name": "Light (50cm)", "weight": 0.4, "length": 50},
		{"name": "Standard (60cm)", "weight": 0.5, "length": 60},
		{"name": "Long (70cm)", "weight": 0.6, "length": 70}
	])

	# Ski & board category
	_add_item(GearItemInfo.new(
		GameEnums.GearType.SKIS,
		"Touring Skis",
		CATEGORY_DESCENT,
		"Skis and touring bindings on the pack. T to step in on snow. The fastest way down snow, and the fastest way to get hurt on it. Useless on rock.",
		3.2,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.SNOWBOARD,
		"Splitboard",
		CATEGORY_DESCENT,
		"A splitboard in ride mode. Floats in powder, holds less on ice, and you walk the flats.",
		3.5,
		false
	))

	# Navigation category: planning happens on paper, at the hut; these carry
	# it onto the mountain (nothing is ever marked on the mountain itself)
	_add_item(GearItemInfo.new(
		GameEnums.GearType.GUIDEBOOK,
		"Guidebook",
		CATEGORY_NAVIGATION,
		"Route descriptions and pitch-by-pitch topos, graded and timed. Carried, its topos can be read on the map (M) during the descent.",
		0.25,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.TOPO_MAP,
		"Topo Map",
		CATEGORY_NAVIGATION,
		"The paper map with your planned line pencilled on. Without it there is nothing to pull out (M) on the mountain.",
		0.1,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.COMPASS,
		"Compass",
		CATEGORY_NAVIGATION,
		"Orients the map and holds a bearing in cloud: your position on the map is far less uncertain in poor visibility.",
		0.05,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.ALTIMETER,
		"Altimeter",
		CATEGORY_NAVIGATION,
		"Your height to the metre. The guidebook's topos are given in metres; without it you estimate to the nearest contour.",
		0.05,
		false
	))

	# Avalanche category: none of it stops an avalanche; it changes what
	# happens after one
	_add_item(GearItemInfo.new(
		GameEnums.GearType.TRANSCEIVER,
		"Avalanche Transceiver",
		CATEGORY_AVALANCHE,
		"Transmits from under the snow. If someone saw you go, they can find you in minutes instead of hours.",
		0.25,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.SHOVEL_PROBE,
		"Shovel & Probe",
		CATEGORY_AVALANCHE,
		"Dig a snow pit to test the snowpack (V), dig yourself free faster when your arms are clear, and probe for crevasses (G).",
		0.95,
		false
	))

	_add_item(GearItemInfo.new(
		GameEnums.GearType.AIRBAG,
		"Avalanche Airbag",
		CATEGORY_AVALANCHE,
		"A balloon pack. Pull the handle (Space) the moment you are caught: a big volume rises in moving snow, and you with it.",
		2.6,
		false
	))

	# Clothing Category
	_add_item(GearItemInfo.new(
		GameEnums.GearType.LAYERS,
		"Clothing Layers",
		CATEGORY_CLOTHING,
		"Base, mid, and shell layers. More warmth means more weight.",
		2.0,
		true
	))
	items[GameEnums.GearType.LAYERS].variants.assign([
		{"name": "Light System", "weight": 1.5, "warmth": 0.6},
		{"name": "Standard System", "weight": 2.0, "warmth": 0.8},
		{"name": "Heavy System", "weight": 2.5, "warmth": 1.0}
	])

	_add_item(GearItemInfo.new(
		GameEnums.GearType.GLOVES,
		"Gloves",
		CATEGORY_CLOTHING,
		"Insulated gloves with dexterity. Warmer = less dexterity.",
		0.2,
		true
	))
	items[GameEnums.GearType.GLOVES].variants.assign([
		{"name": "Light Gloves", "weight": 0.15, "warmth": 0.5, "dexterity": 0.9},
		{"name": "Insulated Gloves", "weight": 0.2, "warmth": 0.7, "dexterity": 0.8},
		{"name": "Heavy Mittens", "weight": 0.3, "warmth": 1.0, "dexterity": 0.5}
	])

	# Survival Category
	_add_item(GearItemInfo.new(
		GameEnums.GearType.BIVY_GEAR,
		"Bivy Gear",
		CATEGORY_SURVIVAL,
		"Emergency shelter for forced bivouac. Heavy but can save your life.",
		2.5,
		false
	))
	items[GameEnums.GearType.BIVY_GEAR].variants.assign([
		{"name": "Emergency Bivy", "weight": 1.5, "warmth": 0.4},
		{"name": "Standard Bivy", "weight": 2.5, "warmth": 0.7},
		{"name": "Full Bivy", "weight": 3.5, "warmth": 1.0}
	])

	is_loaded = true
	database_loaded.emit()


func _add_item(info: GearItemInfo) -> void:
	items[info.type] = info


# =============================================================================
# QUERIES
# =============================================================================

func get_item_info(type: GameEnums.GearType) -> GearItemInfo:
	return items.get(type)


func get_all_items() -> Array[GearItemInfo]:
	var result: Array[GearItemInfo] = []
	for item in items.values():
		result.append(item)
	return result


func get_items_by_category(category: String) -> Array[GearItemInfo]:
	var result: Array[GearItemInfo] = []
	for item in items.values():
		if item.category == category:
			result.append(item)
	return result


func get_essential_items() -> Array[GearItemInfo]:
	var result: Array[GearItemInfo] = []
	for item in items.values():
		if item.is_essential:
			result.append(item)
	return result


func get_optional_items() -> Array[GearItemInfo]:
	var result: Array[GearItemInfo] = []
	for item in items.values():
		if not item.is_essential:
			result.append(item)
	return result


func get_categories() -> Array[String]:
	var cats: Array[String] = []
	cats.assign(CATEGORY_ORDER)
	return cats


func get_item_name(type: GameEnums.GearType) -> String:
	var info := get_item_info(type)
	return info.name if info else "Unknown"


# =============================================================================
# LOADOUT PRESETS
# =============================================================================

func get_preset_names() -> Array[String]:
	return ["Light & Fast", "Standard", "Heavy & Safe", "Ski Descent", "Custom"]


func get_preset_description(preset_name: String) -> String:
	match preset_name:
		"Light & Fast":
			return "Minimal gear for speed. Higher risk, faster time."
		"Standard":
			return "Balanced loadout suitable for most descents."
		"Heavy & Safe":
			return "Full gear including bivy. Slower but prepared."
		"Ski Descent":
			return "Skis on the pack, light technical kit, a 40 m rope. Fast on snow, carried over rock."
		"Custom":
			return "Build your own loadout."
		_:
			return ""


func create_preset_loadout(preset_name: String) -> GearState:
	match preset_name:
		"Light & Fast":
			return GearState.create_light_loadout()
		"Standard":
			return GearState.create_standard_loadout()
		"Heavy & Safe":
			return GearState.create_heavy_loadout()
		"Ski Descent":
			return GearState.create_ski_loadout()
		_:
			return GearState.new()


# =============================================================================
# REQUIREMENT CHECKING
# =============================================================================

func check_requirements(
	loadout: GearState,
	mountain: MountainDatabase.MountainData
) -> Dictionary:
	## Check if loadout meets mountain requirements
	## Returns {met: bool, warnings: Array[String], errors: Array[String]}

	var result := {
		"met": true,
		"warnings": [] as Array[String],
		"errors": [] as Array[String]
	}

	# Check rope requirement
	if mountain.rope_required and not loadout.has_item(GameEnums.GearType.ROPE):
		result["met"] = false
		result["errors"].append("Rope is required for this descent")
	elif mountain.rope_recommended and not loadout.has_item(GameEnums.GearType.ROPE):
		result["warnings"].append("Rope is recommended for this mountain")

	# Check crampons requirement
	if mountain.crampons_required and not loadout.has_item(GameEnums.GearType.CRAMPONS):
		result["met"] = false
		result["errors"].append("Crampons are required for this descent")

	# Check ice axe (always essential)
	if not loadout.has_item(GameEnums.GearType.ICE_AXE):
		result["met"] = false
		result["errors"].append("Ice axe is required for all descents")

	# Weather-based warnings
	if mountain.weather_volatility > 0.7:
		if not loadout.has_item(GameEnums.GearType.GOGGLES):
			result["warnings"].append("Goggles recommended for volatile weather")

	# Temperature-based warnings
	if mountain.typical_temperature < -15:
		var warmth := loadout.get_warmth_rating()
		if warmth < 0.7:
			result["warnings"].append("Consider heavier layers for cold conditions")

	# Long route warnings
	if mountain.estimated_time > 360:  # 6 hours
		if mountain.bivy_possible and not loadout.has_item(GameEnums.GearType.BIVY_GEAR):
			result["warnings"].append("Bivy gear recommended for long descent")

	# Skis carried over rock are dead weight
	if loadout.has_item(GameEnums.GearType.SKIS) or loadout.has_item(GameEnums.GearType.SNOWBOARD):
		if mountain.cliff_exposure > 0.6:
			result["warnings"].append("Expect to carry the skis over rock bands")

	# Glacier travel: probing and climbing out of a crevasse need the axe
	if mountain.glacier_extent > 0.0:
		if not loadout.has_item(GameEnums.GearType.ICE_AXE):
			result["warnings"].append("Glacier on this mountain: without an axe you cannot probe or climb out of a crevasse")
		elif not loadout.has_item(GameEnums.GearType.CRAMPONS):
			result["warnings"].append("Glacier on this mountain: crampons for its bare ice and its crevasse walls")

	# Today's avalanche bulletin
	var avalanches := ServiceLocator.get_service("AvalancheService") as AvalancheService
	if avalanches != null:
		var today := avalanches.today(mountain.id)
		if today != null and today.get_max_danger() >= 3:
			if not loadout.has_item(GameEnums.GearType.TRANSCEIVER) or not loadout.has_item(GameEnums.GearType.SHOVEL_PROBE):
				result["warnings"].append("%s avalanche danger today: carry a transceiver, shovel and probe" % AvalancheConditions.LEVEL_NAMES[today.get_max_danger()])

	# Technical sections warnings
	if mountain.technical_sections > 2:
		if not loadout.has_item(GameEnums.GearType.HELMET):
			result["warnings"].append("Helmet recommended for technical terrain")

	return result


func get_weight_assessment(weight: float) -> Dictionary:
	## Assess loadout weight
	## Returns {rating: String, color: Color, description: String}

	if weight < 4.0:
		return {
			"rating": "Ultralight",
			"color": Color(0.3, 0.8, 0.4),
			"description": "Very fast but potentially risky"
		}
	elif weight < 8.0:
		return {
			"rating": "Light",
			"color": Color(0.5, 0.8, 0.3),
			"description": "Good balance of speed and safety"
		}
	elif weight < 12.0:
		return {
			"rating": "Standard",
			"color": Color(0.8, 0.7, 0.2),
			"description": "Solid loadout with good options"
		}
	elif weight < 16.0:
		return {
			"rating": "Heavy",
			"color": Color(0.8, 0.5, 0.2),
			"description": "Well prepared but slower"
		}
	else:
		return {
			"rating": "Very Heavy",
			"color": Color(0.8, 0.3, 0.2),
			"description": "Maximum safety, minimum speed"
		}
