class_name RouteMemory
extends RefCounted
## Stores and recalls familiar routes the player has taken
## Enables route suggestions and familiarity bonuses
##
## Design Philosophy:
## - Familiarity reduces the unknown
## - Past routes inform future planning
## - Knowledge is earned through experience

# =============================================================================
# CONFIGURATION
# =============================================================================

const MAX_ROUTES_PER_MOUNTAIN := 10
const ROUTE_SIMILARITY_THRESHOLD := 50.0  # meters
const FAMILIARITY_BOOST_PER_SUCCESS := 0.15

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class StoredRoute:
	## Unique route ID
	var route_id: String

	## Mountain ID
	var mountain_id: String

	## Route waypoints
	var waypoints: PackedVector3Array

	## Times successfully completed
	var success_count: int = 0

	## Times attempted
	var attempt_count: int = 0

	## Best time on this route (seconds)
	var best_time: float = -1.0

	## First recorded timestamp
	var first_used: float = 0.0

	## Last used timestamp
	var last_used: float = 0.0

	## Route characteristics
	var total_distance: float = 0.0
	var total_descent: float = 0.0
	var max_slope: float = 0.0
	var rope_sections: int = 0

	## Player-assigned name (optional)
	var custom_name: String = ""

	## Is this marked as a favorite
	var is_favorite: bool = false

	func get_familiarity() -> float:
		## Returns 0-1 familiarity score
		if attempt_count == 0:
			return 0.0
		var success_rate := float(success_count) / float(attempt_count)
		var experience := minf(float(success_count) / 5.0, 1.0)  # Max at 5 successes
		return success_rate * 0.4 + experience * 0.6

	func get_success_rate() -> float:
		if attempt_count == 0:
			return 0.0
		return float(success_count) / float(attempt_count)

	func to_dict() -> Dictionary:
		var waypoints_array: Array = []
		for wp in waypoints:
			waypoints_array.append([wp.x, wp.y, wp.z])

		return {
			"route_id": route_id,
			"mountain_id": mountain_id,
			"waypoints": waypoints_array,
			"success_count": success_count,
			"attempt_count": attempt_count,
			"best_time": best_time,
			"first_used": first_used,
			"last_used": last_used,
			"total_distance": total_distance,
			"total_descent": total_descent,
			"max_slope": max_slope,
			"rope_sections": rope_sections,
			"custom_name": custom_name,
			"is_favorite": is_favorite
		}

	static func from_dict(data: Dictionary) -> StoredRoute:
		var route := StoredRoute.new()
		route.route_id = data.get("route_id", "")
		route.mountain_id = data.get("mountain_id", "")

		var waypoints_array: Array = data.get("waypoints", [])
		for wp in waypoints_array:
			route.waypoints.append(Vector3(wp[0], wp[1], wp[2]))

		route.success_count = data.get("success_count", 0)
		route.attempt_count = data.get("attempt_count", 0)
		route.best_time = data.get("best_time", -1.0)
		route.first_used = data.get("first_used", 0.0)
		route.last_used = data.get("last_used", 0.0)
		route.total_distance = data.get("total_distance", 0.0)
		route.total_descent = data.get("total_descent", 0.0)
		route.max_slope = data.get("max_slope", 0.0)
		route.rope_sections = data.get("rope_sections", 0)
		route.custom_name = data.get("custom_name", "")
		route.is_favorite = data.get("is_favorite", false)

		return route


# =============================================================================
# STATE
# =============================================================================

## All stored routes by mountain
var routes_by_mountain: Dictionary = {}  # mountain_id -> Array[StoredRoute]

## Route lookup by ID
var routes_by_id: Dictionary = {}  # route_id -> StoredRoute

## Hazard knowledge per mountain
var known_hazards: Dictionary = {}  # mountain_id -> Array[Vector3]

## Safe zones discovered
var known_safe_zones: Dictionary = {}  # mountain_id -> Array[Vector3]

# =============================================================================
# ROUTE STORAGE
# =============================================================================

func store_route(
	mountain_id: String,
	waypoints: PackedVector3Array,
	outcome: GameEnums.ResolutionType
) -> StoredRoute:
	# Check if this route is similar to an existing one
	var existing := find_similar_route(mountain_id, waypoints)

	if existing:
		# Update existing route
		existing.attempt_count += 1
		existing.last_used = Time.get_unix_time_from_system()

		if outcome <= GameEnums.ResolutionType.INJURED_RETURN:
			existing.success_count += 1

		return existing

	# Create new route entry
	var route := StoredRoute.new()
	route.route_id = _generate_route_id()
	route.mountain_id = mountain_id
	route.waypoints = waypoints
	route.first_used = Time.get_unix_time_from_system()
	route.last_used = route.first_used
	route.attempt_count = 1

	if outcome <= GameEnums.ResolutionType.INJURED_RETURN:
		route.success_count = 1

	# Calculate route characteristics
	_calculate_route_characteristics(route)

	# Store route
	if not routes_by_mountain.has(mountain_id):
		routes_by_mountain[mountain_id] = []

	routes_by_mountain[mountain_id].append(route)
	routes_by_id[route.route_id] = route

	# Trim to max routes
	_trim_routes(mountain_id)

	return route


func _generate_route_id() -> String:
	return "route_%d_%d" % [Time.get_unix_time_from_system(), randi()]


func _calculate_route_characteristics(route: StoredRoute) -> void:
	if route.waypoints.size() < 2:
		return

	var total_dist := 0.0
	var total_desc := 0.0
	var max_slope := 0.0

	for i in range(route.waypoints.size() - 1):
		var p1 := route.waypoints[i]
		var p2 := route.waypoints[i + 1]

		# Distance
		total_dist += p1.distance_to(p2)

		# Descent
		total_desc += maxf(0.0, p1.y - p2.y)

		# Slope
		var horiz_dist := Vector2(p1.x, p1.z).distance_to(Vector2(p2.x, p2.z))
		if horiz_dist > 0.1:
			var slope := rad_to_deg(atan2(absf(p1.y - p2.y), horiz_dist))
			max_slope = maxf(max_slope, slope)

	route.total_distance = total_dist
	route.total_descent = total_desc
	route.max_slope = max_slope


func _trim_routes(mountain_id: String) -> void:
	if not routes_by_mountain.has(mountain_id):
		return

	var mountain_routes: Array = routes_by_mountain[mountain_id]

	# Keep favorites and trim oldest non-favorites
	while mountain_routes.size() > MAX_ROUTES_PER_MOUNTAIN:
		var oldest_non_favorite: StoredRoute = null
		var oldest_index := -1

		for i in range(mountain_routes.size()):
			var route: StoredRoute = mountain_routes[i]
			if route.is_favorite:
				continue
			if oldest_non_favorite == null or route.last_used < oldest_non_favorite.last_used:
				oldest_non_favorite = route
				oldest_index = i

		if oldest_index >= 0:
			var removed: StoredRoute = mountain_routes[oldest_index]
			mountain_routes.remove_at(oldest_index)
			routes_by_id.erase(removed.route_id)
		else:
			break  # All routes are favorites


# =============================================================================
# ROUTE MATCHING
# =============================================================================

func find_similar_route(mountain_id: String, waypoints: PackedVector3Array) -> StoredRoute:
	if not routes_by_mountain.has(mountain_id):
		return null

	for route in routes_by_mountain[mountain_id]:
		if _routes_are_similar(route.waypoints, waypoints):
			return route

	return null


func _routes_are_similar(route_a: PackedVector3Array, route_b: PackedVector3Array) -> bool:
	# Simple similarity check: average distance between corresponding points
	if absf(route_a.size() - route_b.size()) > 3:
		return false  # Very different number of waypoints

	var total_dist := 0.0
	var comparisons := 0

	# Sample points along both routes and compare
	var samples := mini(route_a.size(), route_b.size())
	for i in range(samples):
		var t_a := float(i) / maxf(1.0, float(route_a.size() - 1))
		var t_b := float(i) / maxf(1.0, float(route_b.size() - 1))

		var idx_a := int(t_a * (route_a.size() - 1))
		var idx_b := int(t_b * (route_b.size() - 1))

		var dist := route_a[idx_a].distance_to(route_b[idx_b])
		total_dist += dist
		comparisons += 1

	if comparisons == 0:
		return false

	var avg_dist := total_dist / float(comparisons)
	return avg_dist < ROUTE_SIMILARITY_THRESHOLD


# =============================================================================
# QUERIES
# =============================================================================

func get_routes_for_mountain(mountain_id: String) -> Array[StoredRoute]:
	if not routes_by_mountain.has(mountain_id):
		return []
	var result: Array[StoredRoute] = []
	result.assign(routes_by_mountain[mountain_id])
	return result


func get_route_by_id(route_id: String) -> StoredRoute:
	return routes_by_id.get(route_id)


func get_best_route(mountain_id: String) -> StoredRoute:
	if not routes_by_mountain.has(mountain_id):
		return null

	var best: StoredRoute = null
	for route in routes_by_mountain[mountain_id]:
		if route.success_count == 0:
			continue
		if best == null or route.best_time < best.best_time:
			if route.best_time > 0:
				best = route

	return best


func get_favorite_routes(mountain_id: String) -> Array[StoredRoute]:
	var result: Array[StoredRoute] = []
	if not routes_by_mountain.has(mountain_id):
		return result

	for route in routes_by_mountain[mountain_id]:
		if route.is_favorite:
			result.append(route)

	return result


func get_most_familiar_route(mountain_id: String) -> StoredRoute:
	if not routes_by_mountain.has(mountain_id):
		return null

	var best: StoredRoute = null
	var best_familiarity := 0.0

	for route in routes_by_mountain[mountain_id]:
		var familiarity := route.get_familiarity()
		if familiarity > best_familiarity:
			best = route
			best_familiarity = familiarity

	return best


func get_familiarity_at_position(mountain_id: String, position: Vector3) -> float:
	## Returns 0-1 familiarity based on proximity to known routes
	if not routes_by_mountain.has(mountain_id):
		return 0.0

	var max_familiarity := 0.0

	for route in routes_by_mountain[mountain_id]:
		for waypoint in route.waypoints:
			var dist := position.distance_to(waypoint)
			if dist < 100.0:  # Within 100m of a waypoint
				var proximity := 1.0 - (dist / 100.0)
				var familiarity := route.get_familiarity() * proximity
				max_familiarity = maxf(max_familiarity, familiarity)

	return max_familiarity


# =============================================================================
# HAZARD KNOWLEDGE
# =============================================================================

func record_hazard(mountain_id: String, position: Vector3, hazard_type: String) -> void:
	if not known_hazards.has(mountain_id):
		known_hazards[mountain_id] = []

	# Check if already known
	for known in known_hazards[mountain_id]:
		if position.distance_to(known["position"]) < 20.0:
			return  # Already know about this hazard

	known_hazards[mountain_id].append({
		"position": position,
		"type": hazard_type,
		"discovered": Time.get_unix_time_from_system()
	})


func record_safe_zone(mountain_id: String, position: Vector3) -> void:
	if not known_safe_zones.has(mountain_id):
		known_safe_zones[mountain_id] = []

	# Check if already known
	for known in known_safe_zones[mountain_id]:
		if position.distance_to(known) < 30.0:
			return  # Already know about this zone

	known_safe_zones[mountain_id].append(position)


func get_known_hazards(mountain_id: String) -> Array:
	return known_hazards.get(mountain_id, [])


func get_known_safe_zones(mountain_id: String) -> Array:
	return known_safe_zones.get(mountain_id, [])


func is_hazard_known(mountain_id: String, position: Vector3) -> bool:
	if not known_hazards.has(mountain_id):
		return false

	for known in known_hazards[mountain_id]:
		if position.distance_to(known["position"]) < 30.0:
			return true

	return false


# =============================================================================
# ROUTE MANAGEMENT
# =============================================================================

func set_route_name(route_id: String, name: String) -> void:
	var route := get_route_by_id(route_id)
	if route:
		route.custom_name = name


func toggle_favorite(route_id: String) -> bool:
	var route := get_route_by_id(route_id)
	if route:
		route.is_favorite = not route.is_favorite
		return route.is_favorite
	return false


func delete_route(route_id: String) -> void:
	var route := get_route_by_id(route_id)
	if route:
		if routes_by_mountain.has(route.mountain_id):
			routes_by_mountain[route.mountain_id].erase(route)
		routes_by_id.erase(route_id)


# =============================================================================
# SERIALIZATION
# =============================================================================

func to_dict() -> Dictionary:
	var routes_data := {}
	for mountain_id in routes_by_mountain:
		var mountain_routes: Array = []
		for route in routes_by_mountain[mountain_id]:
			mountain_routes.append(route.to_dict())
		routes_data[mountain_id] = mountain_routes

	var hazards_data := {}
	for mountain_id in known_hazards:
		var serialized: Array = []
		for hazard in known_hazards[mountain_id]:
			serialized.append({
				"position": [hazard["position"].x, hazard["position"].y, hazard["position"].z],
				"type": hazard["type"],
				"discovered": hazard["discovered"]
			})
		hazards_data[mountain_id] = serialized

	var safe_zones_data := {}
	for mountain_id in known_safe_zones:
		var serialized: Array = []
		for pos in known_safe_zones[mountain_id]:
			serialized.append([pos.x, pos.y, pos.z])
		safe_zones_data[mountain_id] = serialized

	return {
		"routes": routes_data,
		"hazards": hazards_data,
		"safe_zones": safe_zones_data
	}


static func from_dict(data: Dictionary) -> RouteMemory:
	var memory := RouteMemory.new()

	var routes_data: Dictionary = data.get("routes", {})
	for mountain_id in routes_data:
		memory.routes_by_mountain[mountain_id] = []
		for route_data in routes_data[mountain_id]:
			var route := StoredRoute.from_dict(route_data)
			memory.routes_by_mountain[mountain_id].append(route)
			memory.routes_by_id[route.route_id] = route

	var hazards_data: Dictionary = data.get("hazards", {})
	for mountain_id in hazards_data:
		memory.known_hazards[mountain_id] = []
		for hazard in hazards_data[mountain_id]:
			memory.known_hazards[mountain_id].append({
				"position": Vector3(hazard["position"][0], hazard["position"][1], hazard["position"][2]),
				"type": hazard["type"],
				"discovered": hazard["discovered"]
			})

	var safe_zones_data: Dictionary = data.get("safe_zones", {})
	for mountain_id in safe_zones_data:
		memory.known_safe_zones[mountain_id] = []
		for pos in safe_zones_data[mountain_id]:
			memory.known_safe_zones[mountain_id].append(Vector3(pos[0], pos[1], pos[2]))

	return memory
