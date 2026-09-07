class_name PlanningScreen
extends Control
## Main planning phase UI screen
## Route planning on topo map before descent
##
## Design Philosophy:
## - Physical map interaction feel
## - Clear risk communication
## - Player agency in route choice
## - No hidden information

# =============================================================================
# SIGNALS
# =============================================================================

signal planning_complete(route: PackedVector3Array)
signal planning_cancelled()
signal route_updated(analysis: RoutePlanner.RouteAnalysis)

# =============================================================================
# NODES
# =============================================================================

var map_display: TopoMapDisplay
var route_info_panel: Control
var elevation_profile: Control
var controls_panel: Control
var weather_panel: Control
var confirm_button: Button
var clear_button: Button
var back_button: Button

# =============================================================================
# STATE
# =============================================================================

## Route planner
var route_planner: RoutePlanner

## Current route analysis
var current_analysis: RoutePlanner.RouteAnalysis

## Terrain service reference
var terrain_service: TerrainService

## Weather service reference
var weather_service: WeatherService

## Current run context
var run_context: RunContext

## Is route valid for descent
var route_valid: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	route_planner = RoutePlanner.new()

	# The .tscn is a bare root - build the UI structure if it isn't present
	if get_node_or_null("MapContainer/TopoMapDisplay") == null:
		_build_ui()
	_resolve_nodes()

	ServiceLocator.get_service_async("TerrainService", func(t):
		terrain_service = t
		# The map display (a child) regenerates first on terrain_loaded;
		# analyse after it so the summit/base markers are current
		if not terrain_service.terrain_loaded.is_connected(_on_terrain_loaded):
			terrain_service.terrain_loaded.connect(_on_terrain_loaded)
		_analyze_current_route.call_deferred()
	)
	ServiceLocator.get_service_async("WeatherService", func(w):
		weather_service = w
		_update_weather_display()
	)

	_connect_signals()
	_setup_ui()
	_update_weather_display()


func _on_terrain_loaded(_mountain_id: String) -> void:
	_analyze_current_route.call_deferred()


## Re-evaluate the route and forecast (called by Main whenever the screen is shown)
func refresh() -> void:
	_analyze_current_route()
	_update_weather_display()


func _resolve_nodes() -> void:
	map_display = get_node_or_null("MapContainer/TopoMapDisplay") as TopoMapDisplay
	route_info_panel = get_node_or_null("InfoPanel") as Control
	elevation_profile = get_node_or_null("ElevationProfile") as Control
	controls_panel = get_node_or_null("ControlsPanel") as Control
	weather_panel = get_node_or_null("InfoPanel/WeatherPanel") as Control
	if weather_panel == null:
		weather_panel = get_node_or_null("WeatherPanel") as Control
	confirm_button = get_node_or_null("ControlsPanel/ConfirmButton") as Button
	clear_button = get_node_or_null("ControlsPanel/ClearButton") as Button
	back_button = get_node_or_null("ControlsPanel/BackButton") as Button


func _connect_signals() -> void:
	if map_display:
		map_display.waypoint_placed.connect(_on_waypoint_placed)
		map_display.waypoint_removed.connect(_on_waypoint_removed)
		map_display.map_clicked.connect(_on_map_clicked)

	if elevation_profile:
		elevation_profile.draw.connect(_on_elevation_profile_draw)

	if confirm_button:
		confirm_button.pressed.connect(_on_confirm_pressed)

	if clear_button:
		clear_button.pressed.connect(_on_clear_pressed)

	if back_button:
		back_button.pressed.connect(_on_back_pressed)


func _setup_ui() -> void:
	# Initial state
	if confirm_button:
		confirm_button.disabled = true
	_update_route_info()


# =============================================================================
# PUBLIC INTERFACE
# =============================================================================

## Initialize planning for a specific mountain
func initialize(context: RunContext) -> void:
	run_context = context

	# Reset state
	if map_display:
		map_display.clear_waypoints()

	current_analysis = null
	route_valid = false
	if confirm_button:
		confirm_button.disabled = true

	_update_route_info()
	_update_weather_display()


## Get the planned route
func get_planned_route() -> PackedVector3Array:
	if map_display:
		return map_display.get_planned_route_3d()
	return PackedVector3Array()


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_waypoint_placed(world_pos: Vector2) -> void:
	_analyze_current_route()


func _on_waypoint_removed(index: int) -> void:
	_analyze_current_route()


func _on_map_clicked(world_pos: Vector2) -> void:
	# Show info about clicked location
	_show_location_info(world_pos)


func _on_confirm_pressed() -> void:
	if not route_valid:
		return

	var route := get_planned_route()
	planning_complete.emit(route)

	# Transition to descent
	GameStateManager.transition_to(GameEnums.GameState.DESCENT)


func _on_clear_pressed() -> void:
	if map_display:
		map_display.clear_waypoints()

	# The direct summit-to-base line is still a route: analyse it again
	if elevation_profile != null and elevation_profile.has_meta("profile_data"):
		elevation_profile.remove_meta("profile_data")
		elevation_profile.queue_redraw()
	_analyze_current_route()


func _on_back_pressed() -> void:
	planning_cancelled.emit()
	GameStateManager.transition_to(GameEnums.GameState.LOADOUT_CONFIG)


# =============================================================================
# ROUTE ANALYSIS
# =============================================================================

func _analyze_current_route() -> void:
	if terrain_service == null:
		return

	var route := get_planned_route()
	if route.size() < 2:
		current_analysis = null
		route_valid = false
		confirm_button.disabled = true
		_update_route_info()
		return

	current_analysis = route_planner.analyze_route(route, terrain_service)
	# Planning is advisory: the climber may commit to a risky line and live
	# with the consequences, so any analysed route can be started
	route_valid = current_analysis != null
	confirm_button.disabled = not route_valid

	_update_route_info()
	_update_elevation_profile()

	route_updated.emit(current_analysis)


# =============================================================================
# UI UPDATES
# =============================================================================

func _update_route_info() -> void:
	if route_info_panel == null:
		return

	# Find or create labels
	var distance_label := _get_or_create_label(route_info_panel, "DistanceLabel")
	var elevation_label := _get_or_create_label(route_info_panel, "ElevationLabel")
	var time_label := _get_or_create_label(route_info_panel, "TimeLabel")
	var risk_label := _get_or_create_label(route_info_panel, "RiskLabel")
	var warnings_label := _get_or_create_label(route_info_panel, "WarningsLabel")
	var recommendations_label := _get_or_create_label(route_info_panel, "RecommendationsLabel")

	if current_analysis == null:
		distance_label.text = "Distance: --"
		elevation_label.text = "Elevation: --"
		time_label.text = "Est. Time: --"
		risk_label.text = "Risk: --"
		warnings_label.text = ""
		recommendations_label.text = "Waiting for terrain..."
		return

	# Update stats
	distance_label.text = "Distance: %.0fm" % current_analysis.total_distance
	elevation_label.text = "Descent: %.0fm" % current_analysis.total_elevation_change
	time_label.text = "Est. Time: %s" % RoutePlanner.format_time(current_analysis.estimated_total_time)

	# Risk display with color
	var risk_percent := current_analysis.overall_risk * 100
	risk_label.text = "Risk: %.0f%%" % risk_percent
	if risk_percent < 30:
		risk_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
	elif risk_percent < 60:
		risk_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.2))
	else:
		risk_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.2))

	# Warnings
	if current_analysis.warnings.size() > 0:
		warnings_label.text = "Warnings:\n" + "\n".join(current_analysis.warnings)
	else:
		warnings_label.text = ""

	# Recommendations
	var notes: Array[String] = []
	notes.append("Double-click the map to add waypoints; the line runs summit to base camp.")
	for recommendation in current_analysis.recommendations:
		notes.append(str(recommendation))
	recommendations_label.text = "\n".join(notes)

	# Viability
	if not current_analysis.is_viable:
		warnings_label.text += "\n\n⚠ " + current_analysis.viability_reason
		warnings_label.text += "\nYou can still commit to this line."


func _get_or_create_label(parent: Control, label_name: String) -> Label:
	var existing := parent.get_node_or_null(label_name)
	if existing:
		return existing as Label

	var label := Label.new()
	label.name = label_name
	parent.add_child(label)
	return label


func _update_elevation_profile() -> void:
	if elevation_profile == null or terrain_service == null:
		return

	if current_analysis == null:
		return

	var route := get_planned_route()
	var profile_data := route_planner.get_elevation_profile(route, terrain_service)

	# Would draw elevation profile graph here
	# For now, store data for custom drawing
	elevation_profile.set_meta("profile_data", profile_data)
	elevation_profile.queue_redraw()


func _update_weather_display() -> void:
	if weather_panel == null:
		return

	var weather_label := _get_or_create_label(weather_panel, "WeatherLabel")

	# Live weather is only meaningful while a run is in progress (the
	# service keeps simulating between runs); otherwise show the mountain's
	# typical conditions as the forecast
	if weather_service != null and GameStateManager.is_run_active():
		var conditions := weather_service.get_conditions_summary()
		var weather_name: String = str(conditions.get("weather", "UNKNOWN")).capitalize()
		var wind_name: String = str(conditions.get("wind_strength", "UNKNOWN")).capitalize()
		var weather_text: String = "Weather: %s\n" % weather_name
		var temperature_system := ServiceLocator.get_service("TemperatureSystem") as TemperatureSystem
		if temperature_system != null:
			weather_text += "Temp: %.0f°C\n" % temperature_system.get_air_temperature()
		weather_text += "Wind: %s" % wind_name
		weather_label.text = weather_text
		return

	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain: MountainDatabase.MountainData = mountain_db.get_selected_mountain() if mountain_db else null
	if mountain == null:
		weather_label.text = "Forecast: unavailable"
		return

	var volatility := "stable"
	if mountain.weather_volatility > 0.66:
		volatility = "volatile"
	elif mountain.weather_volatility > 0.33:
		volatility = "changeable"
	var wind := "sheltered"
	if mountain.wind_exposure > 0.66:
		wind = "exposed"
	elif mountain.wind_exposure > 0.33:
		wind = "breezy"
	weather_label.text = "Forecast: %s\nSummit temp: %.0f°C\nWind: %s" % [
		volatility, mountain.typical_temperature, wind
	]


func _show_location_info(world_pos: Vector2) -> void:
	if terrain_service == null:
		return

	var pos_3d := Vector3(world_pos.x, 0, world_pos.y)
	var elevation := terrain_service.get_height_at(pos_3d)
	var slope := terrain_service.get_slope_at(pos_3d)
	var surface := terrain_service.get_surface_at(pos_3d)
	var zone := GameEnums.get_terrain_zone(slope)

	# Could show tooltip or info popup
	print("[Planning] Location: %.0f, %.0f | Elev: %.0fm | Slope: %.0f° | %s" % [
		world_pos.x, world_pos.y, elevation, slope,
		GameEnums.TerrainZone.keys()[zone]
	])


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel"):
		_on_back_pressed()


# =============================================================================
# DRAWING (Elevation Profile)
# =============================================================================

func _on_elevation_profile_draw() -> void:
	if elevation_profile == null:
		return

	if not elevation_profile.has_meta("profile_data"):
		return
	var profile_data: Dictionary = elevation_profile.get_meta("profile_data")
	if profile_data.is_empty():
		return

	var distances: PackedFloat32Array = profile_data.get("distances", PackedFloat32Array())
	var elevations: PackedFloat32Array = profile_data.get("elevations", PackedFloat32Array())

	if distances.size() < 2:
		return

	# Calculate bounds
	var min_elev := _packed_min(elevations)
	var max_elev := _packed_max(elevations)
	var total_dist: float = profile_data.get("total_distance", 1.0)

	var rect := elevation_profile.get_rect()
	var padding := 10.0

	# Draw background
	elevation_profile.draw_rect(Rect2(Vector2.ZERO, rect.size), Color(0.1, 0.1, 0.1, 0.8))

	# Draw elevation line
	var points := PackedVector2Array()
	for i in range(distances.size()):
		var x := padding + (distances[i] / total_dist) * (rect.size.x - padding * 2)
		var y := rect.size.y - padding - ((elevations[i] - min_elev) / maxf(1.0, max_elev - min_elev)) * (rect.size.y - padding * 2)
		points.append(Vector2(x, y))

	if points.size() >= 2:
		elevation_profile.draw_polyline(points, Color(0.2, 0.6, 1.0), 2.0)

	# Draw labels
	var font := ThemeDB.fallback_font
	var font_size := 12

	elevation_profile.draw_string(font, Vector2(padding, padding + font_size),
		"%.0fm" % max_elev, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
	elevation_profile.draw_string(font, Vector2(padding, rect.size.y - padding),
		"%.0fm" % min_elev, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


# =============================================================================
# SCENE SETUP
# =============================================================================

## Create the planning screen scene structure
static func create_scene() -> PlanningScreen:
	var screen := PlanningScreen.new()
	screen.name = "PlanningScreen"
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen._build_ui()
	return screen


## Build the UI structure as children of this node
func _build_ui() -> void:
	# Map container
	var map_container := Control.new()
	map_container.name = "MapContainer"
	map_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_container.offset_right = -300  # Leave room for panels
	map_container.offset_bottom = -160  # Leave room for the elevation profile
	add_child(map_container)

	# Topo map display
	var topo_display := TopoMapDisplay.new()
	topo_display.name = "TopoMapDisplay"
	topo_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_container.add_child(topo_display)

	# Info panel (right side)
	var info_panel := VBoxContainer.new()
	info_panel.name = "InfoPanel"
	info_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	info_panel.offset_left = -290
	info_panel.offset_right = -10
	info_panel.offset_top = 10
	info_panel.offset_bottom = -200
	add_child(info_panel)

	# Add info labels
	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "Route Planning"
	title.add_theme_font_size_override("font_size", 24)
	info_panel.add_child(title)

	info_panel.add_child(HSeparator.new())

	# Forecast (typical conditions before the run, live weather during it)
	var weather := VBoxContainer.new()
	weather.name = "WeatherPanel"
	info_panel.add_child(weather)

	info_panel.add_child(HSeparator.new())

	for label_name in ["DistanceLabel", "ElevationLabel", "TimeLabel", "RiskLabel"]:
		var label := Label.new()
		label.name = label_name
		label.text = label_name.replace("Label", "") + ": --"
		info_panel.add_child(label)

	info_panel.add_child(HSeparator.new())

	var warnings := Label.new()
	warnings.name = "WarningsLabel"
	warnings.autowrap_mode = TextServer.AUTOWRAP_WORD
	info_panel.add_child(warnings)

	var recommendations := Label.new()
	recommendations.name = "RecommendationsLabel"
	recommendations.autowrap_mode = TextServer.AUTOWRAP_WORD
	info_panel.add_child(recommendations)

	# Elevation profile (bottom)
	var elevation := Control.new()
	elevation.name = "ElevationProfile"
	elevation.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	elevation.offset_top = -150
	elevation.offset_left = 10
	elevation.offset_right = -310
	elevation.offset_bottom = -60
	add_child(elevation)

	# Controls panel (bottom right)
	var controls := VBoxContainer.new()
	controls.name = "ControlsPanel"
	controls.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	controls.offset_left = -290
	controls.offset_right = -10
	controls.offset_top = -180
	controls.offset_bottom = -10
	add_child(controls)

	var confirm := Button.new()
	confirm.name = "ConfirmButton"
	confirm.text = "Begin Descent"
	confirm.disabled = true
	controls.add_child(confirm)

	var clear := Button.new()
	clear.name = "ClearButton"
	clear.text = "Clear Route"
	controls.add_child(clear)

	var back := Button.new()
	back.name = "BackButton"
	back.text = "Back"
	controls.add_child(back)


	var weather_label := Label.new()
	weather_label.name = "WeatherLabel"
	weather_label.text = "Weather: --"
	weather.add_child(weather_label)


## Smallest value in a PackedFloat32Array (PackedFloat32Array has no min() in Godot 4.2)
func _packed_min(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var result: float = values[0]
	for value in values:
		result = minf(result, value)
	return result


## Largest value in a PackedFloat32Array (PackedFloat32Array has no max() in Godot 4.2)
func _packed_max(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var result: float = values[0]
	for value in values:
		result = maxf(result, value)
	return result
