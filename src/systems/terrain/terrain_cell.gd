class_name TerrainCell
extends RefCounted
## Represents analyzed data for a single terrain cell/vertex
## Contains all computed properties needed for gameplay queries

# =============================================================================
# POSITION & GEOMETRY
# =============================================================================

## World position of this cell
var position: Vector3 = Vector3.ZERO

## Grid coordinates (x, z indices in the terrain grid)
var grid_coords: Vector2i = Vector2i.ZERO

## Elevation in meters
var elevation: float = 0.0

## Slope angle in degrees (0 = flat, 90 = vertical)
var slope_angle: float = 0.0

## Slope direction as normalized vector (downhill direction)
var slope_direction: Vector3 = Vector3.ZERO

## Aspect angle in degrees (0-360, compass direction the slope faces)
## 0 = North, 90 = East, 180 = South, 270 = West
var aspect: float = 0.0

## Surface normal
var normal: Vector3 = Vector3.UP

## Curvature (-1 = concave/gully, 0 = flat, 1 = convex/ridge)
var curvature: float = 0.0

# =============================================================================
# TERRAIN CLASSIFICATION
# =============================================================================

## The terrain zone based on slope angle
var terrain_zone: GameEnums.TerrainZone = GameEnums.TerrainZone.WALKABLE

## The surface type at this cell
var surface_type: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM

## Surface firmness (0 = very soft, 1 = rock hard)
var surface_firmness: float = 0.5

## Friction coefficient for this surface
var friction: float = 0.5

# =============================================================================
# HAZARD DATA
# =============================================================================

## Distance to nearest cliff edge in meters
var distance_to_cliff: float = 1000.0

## Direction to nearest cliff
var cliff_direction: Vector3 = Vector3.ZERO

## Is this cell part of a cliff/vertical face
var is_cliff: bool = false

## Is this cell a potential exit zone for sliding
var is_exit_zone: bool = false

## Exit zone quality (0-1, how good of a stopping point)
var exit_zone_quality: float = 0.0

## Drainage value (0 = ridge, 1 = deep gully)
var drainage: float = 0.0

## Is this cell near water/wet rock
var is_wet: bool = false

# =============================================================================
# ENVIRONMENTAL
# =============================================================================

## Sun exposure factor (0 = always shaded, 1 = always exposed)
var sun_exposure: float = 0.5

## Wind exposure factor (0 = sheltered, 1 = fully exposed)
var wind_exposure: float = 0.5

## Snow depth in meters (if applicable)
var snow_depth: float = 0.0

## Ice probability (0-1)
var ice_probability: float = 0.0

# =============================================================================
# NAVIGATION
# =============================================================================

## Can be walked on
var is_walkable: bool = true

## Requires rope to safely traverse
var requires_rope: bool = false

## Can initiate a slide here
var is_slideable: bool = false

## Slide risk if sliding through here (0 = safe, 1 = terminal)
var slide_risk: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(pos: Vector3 = Vector3.ZERO, coords: Vector2i = Vector2i.ZERO) -> void:
	position = pos
	grid_coords = coords
	elevation = pos.y


## Calculate derived properties after basic values are set
func calculate_derived_properties() -> void:
	# Terrain zone from slope
	terrain_zone = GameEnums.get_terrain_zone(slope_angle)

	# Friction from surface
	friction = GameEnums.get_surface_friction(surface_type)

	# Navigation flags
	is_cliff = slope_angle >= GameEnums.SLOPE_THRESHOLDS.cliff_min
	is_walkable = terrain_zone in [
		GameEnums.TerrainZone.WALKABLE,
		GameEnums.TerrainZone.STEEP
	]
	requires_rope = terrain_zone in [
		GameEnums.TerrainZone.RAPPEL_REQUIRED,
		GameEnums.TerrainZone.CLIFF
	]
	is_slideable = (
		slope_angle >= GameEnums.SLOPE_THRESHOLDS.slide_min and
		slope_angle < GameEnums.SLOPE_THRESHOLDS.downclimb_min and
		surface_type in [
			GameEnums.SurfaceType.SNOW_FIRM,
			GameEnums.SurfaceType.SNOW_SOFT,
			GameEnums.SurfaceType.SNOW_POWDER,
			GameEnums.SurfaceType.SCREE
		]
	)

	# Exit zone detection (slope reduction + good surface)
	is_exit_zone = (
		slope_angle < GameEnums.SLOPE_THRESHOLDS.slide_min and
		curvature < 0.2 and  # Concave or flat
		not is_cliff and
		distance_to_cliff > 10.0
	)

	if is_exit_zone:
		# Quality based on how flat and far from danger
		exit_zone_quality = 1.0 - (slope_angle / GameEnums.SLOPE_THRESHOLDS.slide_min)
		exit_zone_quality *= clampf(distance_to_cliff / 50.0, 0.0, 1.0)

	# Slide risk calculation
	if is_slideable:
		slide_risk = 0.0
		# Steeper = more risk
		slide_risk += (slope_angle - GameEnums.SLOPE_THRESHOLDS.slide_min) / 15.0 * 0.3
		# Close to cliff = more risk
		if distance_to_cliff < 50.0:
			slide_risk += (1.0 - distance_to_cliff / 50.0) * 0.5
		# Icy = more risk
		slide_risk += ice_probability * 0.2
		slide_risk = clampf(slide_risk, 0.0, 1.0)


## Get a risk summary for this cell
func get_risk_summary() -> Dictionary:
	return {
		"slope_angle": slope_angle,
		"terrain_zone": terrain_zone,
		"surface_type": surface_type,
		"distance_to_cliff": distance_to_cliff,
		"is_slideable": is_slideable,
		"slide_risk": slide_risk,
		"requires_rope": requires_rope,
		"is_exit_zone": is_exit_zone
	}


## Check if this cell is dangerous
func is_dangerous() -> bool:
	return (
		is_cliff or
		requires_rope or
		slide_risk > 0.7 or
		distance_to_cliff < 5.0
	)


## Get descriptive text for this cell (for UI/debug)
func get_description() -> String:
	var lines: Array[String] = []

	lines.append("Elevation: %.0fm" % elevation)
	lines.append("Slope: %.1f°" % slope_angle)

	match terrain_zone:
		GameEnums.TerrainZone.WALKABLE:
			lines.append("Terrain: Walkable")
		GameEnums.TerrainZone.STEEP:
			lines.append("Terrain: Steep")
		GameEnums.TerrainZone.SLIDEABLE:
			lines.append("Terrain: Slideable")
		GameEnums.TerrainZone.DOWNCLIMB:
			lines.append("Terrain: Downclimb required")
		GameEnums.TerrainZone.RAPPEL_REQUIRED:
			lines.append("Terrain: Rope required")
		GameEnums.TerrainZone.CLIFF:
			lines.append("Terrain: CLIFF")

	match surface_type:
		GameEnums.SurfaceType.SNOW_FIRM:
			lines.append("Surface: Firm snow")
		GameEnums.SurfaceType.SNOW_SOFT:
			lines.append("Surface: Soft snow")
		GameEnums.SurfaceType.ICE:
			lines.append("Surface: Ice")
		GameEnums.SurfaceType.ROCK_DRY:
			lines.append("Surface: Dry rock")
		GameEnums.SurfaceType.ROCK_WET:
			lines.append("Surface: Wet rock")
		GameEnums.SurfaceType.SCREE:
			lines.append("Surface: Scree")

	if distance_to_cliff < 20.0:
		lines.append("WARNING: Cliff nearby (%.0fm)" % distance_to_cliff)

	return "\n".join(lines)
