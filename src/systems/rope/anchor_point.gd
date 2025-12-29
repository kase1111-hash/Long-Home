class_name AnchorPoint
extends Resource
## Represents a potential or active anchor point in the terrain
##
## Design Philosophy:
## - Anchors are judged visually, not rated with numbers
## - Quality is hidden but affects outcomes
## - Players learn to read terrain over time
## - No "100% safe" indicator ever

# =============================================================================
# ENUMS
# =============================================================================

enum AnchorType {
	ROCK_HORN,       # Natural rock protrusion
	ROCK_CRACK,      # Crack for placing protection
	BOULDER,         # Large stable boulder
	ICE_SCREW,       # Placed in ice
	SNOW_STAKE,      # Placed in hard snow (least reliable)
	FIXED_ANCHOR,    # Pre-existing bolt or piton
	TREE             # Tree anchor (rare at altitude)
}


# =============================================================================
# PROPERTIES
# =============================================================================

## World position of anchor
@export var position: Vector3 = Vector3.ZERO

## Anchor type
@export var anchor_type: AnchorType = AnchorType.ROCK_HORN

## Base quality (0-1, hidden from player)
@export var base_quality: float = 0.7

## Direction anchor can hold load (normalized)
@export var load_direction: Vector3 = Vector3.DOWN

## Maximum load angle deviation from ideal (degrees)
@export var load_angle_tolerance: float = 45.0

## Is this anchor currently in use
@export var is_active: bool = false

## Has this anchor been tested
@export var is_tested: bool = false


# =============================================================================
# ENVIRONMENTAL MODIFIERS (set by detector)
# =============================================================================

## Rock type modifier (0.5-1.5)
var rock_type_modifier: float = 1.0

## Weather degradation modifier (0-1)
var weather_modifier: float = 1.0

## Ice coverage modifier (reduces rock quality)
var ice_coverage_modifier: float = 1.0

## Angle modifier (overhangs are worse)
var angle_modifier: float = 1.0


# =============================================================================
# DERIVED PROPERTIES
# =============================================================================

## Get effective quality (never shown to player)
func get_effective_quality() -> float:
	var quality := base_quality
	quality *= rock_type_modifier
	quality *= weather_modifier
	quality *= ice_coverage_modifier
	quality *= angle_modifier

	# Type-based adjustments
	match anchor_type:
		AnchorType.FIXED_ANCHOR:
			quality *= 1.2  # Most reliable
		AnchorType.ROCK_HORN:
			quality *= 1.1  # Very reliable
		AnchorType.BOULDER:
			quality *= 1.0  # Standard
		AnchorType.ROCK_CRACK:
			quality *= 0.9  # Depends on placement
		AnchorType.ICE_SCREW:
			quality *= 0.8  # Temperature dependent
		AnchorType.SNOW_STAKE:
			quality *= 0.6  # Least reliable
		AnchorType.TREE:
			quality *= 1.1  # Reliable if present

	return clampf(quality, 0.1, 1.0)


## Get failure probability for given load
func get_failure_probability(load_force: float, load_dir: Vector3) -> float:
	var quality := get_effective_quality()

	# Base failure from load
	var base_failure := load_force / 1000.0  # 1000N is reference load

	# Angle penalty
	var angle := rad_to_deg(load_dir.angle_to(load_direction))
	var angle_penalty := 0.0
	if angle > load_angle_tolerance:
		angle_penalty = (angle - load_angle_tolerance) / 90.0

	# Calculate probability
	var probability := base_failure * (1.0 - quality) + angle_penalty * 0.3

	return clampf(probability, 0.0, 1.0)


## Check if anchor holds under load (probabilistic)
func test_hold(load_force: float, load_dir: Vector3) -> bool:
	var failure_prob := get_failure_probability(load_force, load_dir)
	return randf() > failure_prob


## Get placement difficulty (for time calculation)
func get_placement_difficulty() -> float:
	match anchor_type:
		AnchorType.ROCK_HORN:
			return 0.2  # Just loop rope
		AnchorType.BOULDER:
			return 0.3  # Simple wrap
		AnchorType.FIXED_ANCHOR:
			return 0.1  # Clip and go
		AnchorType.TREE:
			return 0.2  # Simple wrap
		AnchorType.ROCK_CRACK:
			return 0.6  # Requires protection placement
		AnchorType.ICE_SCREW:
			return 0.7  # Technical placement
		AnchorType.SNOW_STAKE:
			return 0.5  # Dig and place
		_:
			return 0.5


## Get visual hint type for diegetic feedback
func get_visual_hint() -> String:
	match anchor_type:
		AnchorType.ROCK_HORN:
			return "rock_protrusion"
		AnchorType.BOULDER:
			return "large_rock"
		AnchorType.ROCK_CRACK:
			return "vertical_crack"
		AnchorType.ICE_SCREW:
			return "solid_ice"
		AnchorType.SNOW_STAKE:
			return "packed_snow"
		AnchorType.FIXED_ANCHOR:
			return "metal_bolt"
		AnchorType.TREE:
			return "stunted_tree"
		_:
			return ""


## Get audio hint for placement
func get_audio_hint() -> String:
	match anchor_type:
		AnchorType.ROCK_HORN, AnchorType.BOULDER, AnchorType.ROCK_CRACK:
			return "solid_tap"  # Tapping rock sounds solid
		AnchorType.ICE_SCREW:
			return "ice_crunch"
		AnchorType.SNOW_STAKE:
			return "snow_compress"
		AnchorType.FIXED_ANCHOR:
			return "metal_click"
		AnchorType.TREE:
			return "wood_creak"
		_:
			return ""


# =============================================================================
# OPERATIONS
# =============================================================================

## Activate this anchor
func activate() -> void:
	is_active = true


## Deactivate and mark as tested
func deactivate() -> void:
	is_active = false
	is_tested = true


## Apply environmental conditions
func apply_environment(temperature: float, has_ice: bool, is_wet: bool) -> void:
	# Ice on rock reduces grip
	if has_ice and anchor_type in [AnchorType.ROCK_HORN, AnchorType.BOULDER, AnchorType.ROCK_CRACK]:
		ice_coverage_modifier = 0.7

	# Cold affects ice anchors positively, warm negatively
	if anchor_type == AnchorType.ICE_SCREW:
		if temperature < -10.0:
			weather_modifier = 1.1  # Solid ice
		elif temperature > -2.0:
			weather_modifier = 0.5  # Melting
		else:
			weather_modifier = 0.9

	# Snow stakes worse in warm conditions
	if anchor_type == AnchorType.SNOW_STAKE:
		if temperature > -5.0:
			weather_modifier = 0.6


# =============================================================================
# FACTORY
# =============================================================================

static func create_rock_horn(pos: Vector3, quality: float = 0.8) -> AnchorPoint:
	var anchor := AnchorPoint.new()
	anchor.position = pos
	anchor.anchor_type = AnchorType.ROCK_HORN
	anchor.base_quality = quality
	anchor.load_direction = Vector3.DOWN
	return anchor


static func create_fixed(pos: Vector3) -> AnchorPoint:
	var anchor := AnchorPoint.new()
	anchor.position = pos
	anchor.anchor_type = AnchorType.FIXED_ANCHOR
	anchor.base_quality = 0.95
	anchor.load_direction = Vector3.DOWN
	return anchor


static func create_ice_placement(pos: Vector3, ice_quality: float = 0.7) -> AnchorPoint:
	var anchor := AnchorPoint.new()
	anchor.position = pos
	anchor.anchor_type = AnchorType.ICE_SCREW
	anchor.base_quality = ice_quality
	anchor.load_direction = Vector3(-0.3, -0.95, 0).normalized()
	return anchor
