class_name SlopeAnalyzer
extends RefCounted
## Analyzes terrain slope, aspect, and curvature
## Provides methods for calculating terrain geometry from heightmap data

# =============================================================================
# ANALYSIS RESULTS
# =============================================================================

class SlopeData:
	var angle: float = 0.0          # Slope angle in degrees
	var direction: Vector3 = Vector3.ZERO  # Downhill direction
	var aspect: float = 0.0         # Compass direction (0-360)
	var normal: Vector3 = Vector3.UP
	var curvature: float = 0.0      # Terrain curvature
	var is_convex: bool = false     # Ridge
	var is_concave: bool = false    # Gully


# =============================================================================
# CONFIGURATION
# =============================================================================

## Cell size for gradient calculations
var cell_size: float = 2.0

## Threshold for considering terrain flat (degrees)
var flat_threshold: float = 3.0

## Curvature threshold for ridge/gully classification
var curvature_threshold: float = 0.1


# =============================================================================
# SINGLE POINT ANALYSIS
# =============================================================================

## Analyze slope at a single point given surrounding heights
## heights: Dictionary with keys 'n', 's', 'e', 'w', 'c', 'ne', 'nw', 'se', 'sw'
func analyze_point(heights: Dictionary) -> SlopeData:
	var data := SlopeData.new()

	# Use 3x3 Sobel operator for smooth gradient
	var dx := _calculate_dx(heights)
	var dz := _calculate_dz(heights)

	# Gradient magnitude
	var gradient := sqrt(dx * dx + dz * dz)

	# Slope angle
	data.angle = rad_to_deg(atan(gradient))

	# Normal vector (perpendicular to surface)
	data.normal = Vector3(-dx, 1.0, -dz).normalized()

	# Slope direction (downhill, horizontal)
	if gradient > 0.001:
		data.direction = Vector3(dx, 0.0, dz).normalized()
	else:
		data.direction = Vector3.ZERO

	# Aspect (compass direction the slope faces)
	if gradient > 0.001:
		data.aspect = rad_to_deg(atan2(dx, -dz))
		if data.aspect < 0:
			data.aspect += 360.0

	# Curvature (second derivative)
	data.curvature = _calculate_curvature(heights)
	data.is_convex = data.curvature > curvature_threshold
	data.is_concave = data.curvature < -curvature_threshold

	return data


## Calculate x-gradient using Sobel operator
func _calculate_dx(h: Dictionary) -> float:
	# Sobel x-kernel weights
	# [-1  0  1]
	# [-2  0  2]
	# [-1  0  1]

	var dx := 0.0
	if h.has("nw") and h.has("ne"):
		dx += -h.get("nw", h.c) + h.get("ne", h.c)
	if h.has("w") and h.has("e"):
		dx += -2.0 * h.w + 2.0 * h.e
	if h.has("sw") and h.has("se"):
		dx += -h.get("sw", h.c) + h.get("se", h.c)

	# Fallback to simple gradient if diagonals not available
	if not h.has("nw"):
		dx = (h.get("e", h.c) - h.get("w", h.c)) / (2.0 * cell_size)
	else:
		dx /= (8.0 * cell_size)

	return dx


## Calculate z-gradient using Sobel operator
func _calculate_dz(h: Dictionary) -> float:
	# Sobel z-kernel weights
	# [-1 -2 -1]
	# [ 0  0  0]
	# [ 1  2  1]

	var dz := 0.0
	if h.has("nw") and h.has("sw"):
		dz += -h.get("nw", h.c) + h.get("sw", h.c)
	if h.has("n") and h.has("s"):
		dz += -2.0 * h.n + 2.0 * h.s
	if h.has("ne") and h.has("se"):
		dz += -h.get("ne", h.c) + h.get("se", h.c)

	# Fallback to simple gradient
	if not h.has("nw"):
		dz = (h.get("s", h.c) - h.get("n", h.c)) / (2.0 * cell_size)
	else:
		dz /= (8.0 * cell_size)

	return dz


## Calculate curvature (Laplacian)
func _calculate_curvature(h: Dictionary) -> float:
	var center := h.get("c", 0.0)

	# Second derivatives
	var d2x := (h.get("e", center) + h.get("w", center) - 2.0 * center)
	var d2z := (h.get("n", center) + h.get("s", center) - 2.0 * center)

	# Mean curvature
	return (d2x + d2z) / (2.0 * cell_size * cell_size)


# =============================================================================
# TERRAIN ZONE CLASSIFICATION
# =============================================================================

## Get terrain zone from slope angle
func get_terrain_zone(slope_angle: float) -> GameEnums.TerrainZone:
	return GameEnums.get_terrain_zone(slope_angle)


## Check if slope is slideable
func is_slideable_slope(slope_angle: float) -> bool:
	return (
		slope_angle >= GameEnums.SLOPE_THRESHOLDS.slide_min and
		slope_angle <= GameEnums.SLOPE_THRESHOLDS.slide_max
	)


## Check if rope is required
func requires_rope(slope_angle: float) -> bool:
	return slope_angle >= GameEnums.SLOPE_THRESHOLDS.rappel_min


## Check if this is a cliff
func is_cliff(slope_angle: float) -> bool:
	return slope_angle >= GameEnums.SLOPE_THRESHOLDS.cliff_min


# =============================================================================
# ASPECT ANALYSIS
# =============================================================================

## Get compass direction name from aspect
func get_aspect_name(aspect: float) -> String:
	if aspect < 22.5 or aspect >= 337.5:
		return "North"
	elif aspect < 67.5:
		return "Northeast"
	elif aspect < 112.5:
		return "East"
	elif aspect < 157.5:
		return "Southeast"
	elif aspect < 202.5:
		return "South"
	elif aspect < 247.5:
		return "Southwest"
	elif aspect < 292.5:
		return "West"
	else:
		return "Northwest"


## Check if aspect faces the sun (simplified)
## sun_angle: 0-360 degrees (where the sun is coming from)
func faces_sun(aspect: float, sun_angle: float) -> bool:
	# Slope faces sun if aspect is roughly opposite to sun direction
	var facing := fmod(aspect + 180.0, 360.0)
	var diff := absf(facing - sun_angle)

	if diff > 180.0:
		diff = 360.0 - diff

	return diff < 45.0


## Calculate sun exposure factor (0-1)
## Higher = more sun exposure
func calculate_sun_exposure(aspect: float, slope_angle: float, sun_altitude: float, sun_azimuth: float) -> float:
	if slope_angle < flat_threshold:
		# Flat terrain gets uniform exposure based on sun altitude
		return clampf(sin(deg_to_rad(sun_altitude)), 0.0, 1.0)

	# Calculate angle between surface normal and sun direction
	var sun_dir := Vector3(
		cos(deg_to_rad(sun_azimuth)) * cos(deg_to_rad(sun_altitude)),
		sin(deg_to_rad(sun_altitude)),
		sin(deg_to_rad(sun_azimuth)) * cos(deg_to_rad(sun_altitude))
	).normalized()

	var normal := Vector3(
		sin(deg_to_rad(slope_angle)) * sin(deg_to_rad(aspect)),
		cos(deg_to_rad(slope_angle)),
		sin(deg_to_rad(slope_angle)) * cos(deg_to_rad(aspect))
	).normalized()

	var exposure := normal.dot(sun_dir)
	return clampf(exposure, 0.0, 1.0)


# =============================================================================
# HAZARD DETECTION
# =============================================================================

## Calculate transition danger (slope change during slide)
func calculate_transition_danger(
	current_slope: float,
	next_slope: float,
	current_speed: float
) -> float:
	var slope_change := next_slope - current_slope

	if slope_change <= 0:
		# Getting flatter - generally safer
		return 0.0

	# Steeper ahead - danger increases with speed and slope change
	var danger := (slope_change / 20.0) * (current_speed / 10.0)
	return clampf(danger, 0.0, 1.0)


## Detect cliff edges in a chunk
func detect_cliff_edges(chunk: TerrainChunk) -> Array[Vector2i]:
	var cliff_edges: Array[Vector2i] = []

	for x in range(chunk.resolution):
		for z in range(chunk.resolution):
			var cell := chunk.get_cell(Vector2i(x, z))

			# Check if this cell is a cliff edge (cliff next to non-cliff)
			if cell.is_cliff:
				var has_non_cliff_neighbor := false

				for dx in range(-1, 2):
					for dz in range(-1, 2):
						if dx == 0 and dz == 0:
							continue

						var neighbor := chunk.get_cell(Vector2i(x + dx, z + dz))
						if neighbor and not neighbor.is_cliff:
							has_non_cliff_neighbor = true
							break
					if has_non_cliff_neighbor:
						break

				if has_non_cliff_neighbor:
					cliff_edges.append(Vector2i(x, z))

	return cliff_edges


# =============================================================================
# SLIDE PATH PREDICTION
# =============================================================================

## Predict slide trajectory from a starting point
## Returns array of positions along predicted path
func predict_slide_path(
	start_pos: Vector3,
	start_velocity: Vector3,
	chunk: TerrainChunk,
	max_steps: int = 100,
	step_distance: float = 1.0
) -> PackedVector3Array:
	var path := PackedVector3Array()
	path.append(start_pos)

	var pos := start_pos
	var velocity := start_velocity

	for i in range(max_steps):
		var cell := chunk.get_cell_at_world(pos)
		if cell == null:
			break

		# Check if we've stopped
		if cell.slope_angle < GameEnums.SLOPE_THRESHOLDS.slide_min:
			break

		# Check for cliff
		if cell.is_cliff:
			path.append(pos + cell.slope_direction * 10.0)  # Indicate fall direction
			break

		# Move along slope direction
		var move_dir := cell.slope_direction
		if move_dir.length() < 0.1:
			break

		pos += move_dir * step_distance
		pos.y = chunk.get_height_at_world(pos)
		path.append(pos)

	return path
