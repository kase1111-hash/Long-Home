class_name PlanningService
extends Node
## Coordinates the planning phase
## Manages planned routes and integrates with game state
##
## Responsibilities:
## - Store and validate planned routes
## - Provide route data to descent systems
## - Track planning statistics

# =============================================================================
# SIGNALS
# =============================================================================

signal route_planned(route: PackedVector3Array, analysis: RoutePlanner.RouteAnalysis)
signal planning_started(mountain_id: String)
signal planning_ended(committed: bool)

# =============================================================================
# STATE
# =============================================================================

## Current planned route (world coordinates)
var planned_route: PackedVector3Array = PackedVector3Array()

## Current route analysis
var route_analysis: RoutePlanner.RouteAnalysis

## Waypoints placed by player
var waypoints: Array[Vector3] = []

## Summit position
var summit_position: Vector3 = Vector3.ZERO

## Base/safety position
var base_position: Vector3 = Vector3.ZERO

## Is planning active
var is_planning: bool = false

## Current mountain being planned
var current_mountain: String = ""

## Route planner instance
var route_planner: RoutePlanner

## Terrain service reference
var terrain_service: TerrainService

## Planning screen reference
var planning_screen: PlanningScreen


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("PlanningService", self)

	route_planner = RoutePlanner.new()

	ServiceLocator.get_service_async("TerrainService", func(t): terrain_service = t)

	_connect_events()
	print("[PlanningService] Initialized")


func _connect_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)


# =============================================================================
# PLANNING CONTROL
# =============================================================================

func start_planning(mountain_id: String, start_pos: Vector3, end_pos: Vector3) -> void:
	current_mountain = mountain_id
	summit_position = start_pos
	base_position = end_pos
	waypoints.clear()
	planned_route.clear()
	route_analysis = null
	is_planning = true

	planning_started.emit(mountain_id)
	print("[PlanningService] Planning started for: %s" % mountain_id)


func end_planning(commit: bool) -> void:
	is_planning = false

	if commit and planned_route.size() >= 2:
		route_planned.emit(planned_route, route_analysis)

	planning_ended.emit(commit)
	print("[PlanningService] Planning ended (committed: %s)" % commit)


# =============================================================================
# WAYPOINT MANAGEMENT
# =============================================================================

func add_waypoint(position: Vector3) -> int:
	waypoints.append(position)
	_rebuild_route()
	return waypoints.size() - 1


func remove_waypoint(index: int) -> void:
	if index >= 0 and index < waypoints.size():
		waypoints.remove_at(index)
		_rebuild_route()


func move_waypoint(index: int, new_position: Vector3) -> void:
	if index >= 0 and index < waypoints.size():
		waypoints[index] = new_position
		_rebuild_route()


func clear_waypoints() -> void:
	waypoints.clear()
	_rebuild_route()


func get_waypoint_count() -> int:
	return waypoints.size()


# =============================================================================
# ROUTE BUILDING
# =============================================================================

func _rebuild_route() -> void:
	planned_route.clear()

	# Build route: summit -> waypoints -> base
	planned_route.append(summit_position)

	for wp in waypoints:
		planned_route.append(wp)

	planned_route.append(base_position)

	# Analyze route
	if terrain_service:
		route_analysis = route_planner.analyze_route(planned_route, terrain_service)


func set_route_from_2d(points: Array[Vector2]) -> void:
	## Convert 2D points to 3D using terrain height

	waypoints.clear()

	# Skip first (summit) and last (base) - they're set separately
	for i in range(1, points.size() - 1):
		var pos_2d := points[i]
		var height := 0.0
		if terrain_service:
			height = terrain_service.get_height_at(Vector3(pos_2d.x, 0, pos_2d.y))
		waypoints.append(Vector3(pos_2d.x, height, pos_2d.y))

	_rebuild_route()


# =============================================================================
# ROUTE QUERIES
# =============================================================================

func get_planned_route() -> PackedVector3Array:
	return planned_route


func get_route_analysis() -> RoutePlanner.RouteAnalysis:
	return route_analysis


func is_route_valid() -> bool:
	return route_analysis != null and route_analysis.is_viable


func get_route_distance() -> float:
	if route_analysis:
		return route_analysis.total_distance
	return 0.0


func get_route_time() -> float:
	if route_analysis:
		return route_analysis.estimated_total_time
	return 0.0


func get_route_risk() -> float:
	if route_analysis:
		return route_analysis.overall_risk
	return 0.0


func get_rope_sections_needed() -> int:
	if route_analysis:
		return route_analysis.rope_sections
	return 0


# =============================================================================
# ELEVATION DATA
# =============================================================================

func get_elevation_profile(num_samples: int = 100) -> Dictionary:
	if terrain_service == null or planned_route.size() < 2:
		return {}

	return route_planner.get_elevation_profile(planned_route, terrain_service, num_samples)


func get_time_breakdown() -> Dictionary:
	if route_analysis == null:
		return {}

	return route_planner.get_time_breakdown(route_analysis)


# =============================================================================
# ROUTE SUGGESTIONS
# =============================================================================

func get_waypoint_suggestions(max_suggestions: int = 3) -> Array[Vector3]:
	if terrain_service == null:
		return []

	# Get suggestions between summit and base (or last waypoint and base)
	var from := summit_position
	if waypoints.size() > 0:
		from = waypoints[-1]

	return route_planner.suggest_waypoints(from, base_position, terrain_service, max_suggestions)


# =============================================================================
# SAVE/LOAD ROUTES
# =============================================================================

func save_route(route_name: String) -> String:
	var data := {
		"name": route_name,
		"mountain": current_mountain,
		"summit": [summit_position.x, summit_position.y, summit_position.z],
		"base": [base_position.x, base_position.y, base_position.z],
		"waypoints": []
	}

	for wp in waypoints:
		data["waypoints"].append([wp.x, wp.y, wp.z])

	if route_analysis:
		data["analysis"] = route_analysis.get_summary()

	var path := "user://routes/%s_%s.route" % [current_mountain, route_name]

	var dir := DirAccess.open("user://")
	if dir:
		dir.make_dir_recursive("routes")

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()
		return path

	return ""


func load_route(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()

	if error != OK:
		return false

	var data: Dictionary = json.data

	# Load positions
	var summit_arr: Array = data.get("summit", [0, 0, 0])
	summit_position = Vector3(summit_arr[0], summit_arr[1], summit_arr[2])

	var base_arr: Array = data.get("base", [0, 0, 0])
	base_position = Vector3(base_arr[0], base_arr[1], base_arr[2])

	# Load waypoints
	waypoints.clear()
	for wp_arr in data.get("waypoints", []):
		waypoints.append(Vector3(wp_arr[0], wp_arr[1], wp_arr[2]))

	current_mountain = data.get("mountain", "")

	_rebuild_route()
	return true


func get_saved_routes(mountain_id: String = "") -> Array[String]:
	var routes: Array[String] = []

	var dir := DirAccess.open("user://routes")
	if dir == null:
		return routes

	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if file_name.ends_with(".route"):
			if mountain_id.is_empty() or file_name.begins_with(mountain_id):
				routes.append("user://routes/" + file_name)
		file_name = dir.get_next()

	dir.list_dir_end()
	return routes


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.PLANNING:
			# Could auto-start planning here if we have context
			pass

		GameEnums.GameState.DESCENT:
			# Planning complete, route committed
			if is_planning:
				end_planning(true)

		GameEnums.GameState.MAIN_MENU:
			# Clear planning state
			if is_planning:
				end_planning(false)
			waypoints.clear()
			planned_route.clear()
			route_analysis = null


# =============================================================================
# QUERIES
# =============================================================================

func get_summary() -> Dictionary:
	return {
		"is_planning": is_planning,
		"mountain": current_mountain,
		"waypoints": waypoints.size(),
		"route_valid": is_route_valid(),
		"distance": get_route_distance(),
		"time": get_route_time(),
		"risk": get_route_risk(),
		"rope_sections": get_rope_sections_needed()
	}
