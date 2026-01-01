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

@onready var map_display: TopoMapDisplay = $MapContainer/TopoMapDisplay
@onready var route_info_panel: Control = $InfoPanel
@onready var elevation_profile: Control = $ElevationProfile
@onready var controls_panel: Control = $ControlsPanel
@onready var weather_panel: Control = $WeatherPanel
@onready var confirm_button: Button = $ControlsPanel/ConfirmButton
@onready var clear_button: Button = $ControlsPanel/ClearButton
@onready var back_button: Button = $ControlsPanel/BackButton

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

	ServiceLocator.get_service_async("TerrainService", func(t): terrain_service = t)
	ServiceLocator.get_service_async("WeatherService", func(w):
		weather_service = w
		_update_weather_display()
	)

	_connect_signals()
	_setup_ui()


func _connect_signals() -> void:
	if map_display:
		map_display.waypoint_placed.connect(_on_waypoint_placed)
		map_display.waypoint_removed.connect(_on_waypoint_removed)
		map_display.map_clicked.connect(_on_map_clicked)

	if confirm_button:
		confirm_button.pressed.connect(_on_confirm_pressed)

	if clear_button:
		clear_button.pressed.connect(_on_clear_pressed)

	if back_button:
		back_button.pressed.connect(_on_back_pressed)


func _setup_ui() -> void:
	# Initial state
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

	current_analysis = null
	route_valid = false
	confirm_button.disabled = true

	_update_route_info()


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
	route_valid = current_analysis.is_viable
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
		recommendations_label.text = "Double-click to place waypoints"
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
	if current_analysis.recommendations.size() > 0:
		recommendations_label.text = "Notes:\n" + "\n".join(current_analysis.recommendations)
	else:
		recommendations_label.text = ""

	# Viability
	if not current_analysis.is_viable:
		warnings_label.text += "\n\n⚠ " + current_analysis.viability_reason


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
	if weather_panel == null or weather_service == null:
		return

	var weather_label := _get_or_create_label(weather_panel, "WeatherLabel")
	var conditions := weather_service.get_conditions_summary()

	var weather_text := "Weather: %s\n" % conditions.get("state", "Unknown")
	weather_text += "Temp: %.0f°C\n" % conditions.get("temperature", 0)
	weather_text += "Wind: %s" % conditions.get("wind_strength", "Unknown")

	weather_label.text = weather_text


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

	var profile_data = elevation_profile.get_meta("profile_data", null)
	if profile_data == null:
		return

	var distances: PackedFloat32Array = profile_data.get("distances", PackedFloat32Array())
	var elevations: PackedFloat32Array = profile_data.get("elevations", PackedFloat32Array())

	if distances.size() < 2:
		return

	# Calculate bounds
	var min_elev := elevations.min()
	var max_elev := elevations.max()
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

	# Map container
	var map_container := Control.new()
	map_container.name = "MapContainer"
	map_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_container.offset_right = -300  # Leave room for panels
	screen.add_child(map_container)

	# Topo map display
	var map_display := TopoMapDisplay.new()
	map_display.name = "TopoMapDisplay"
	map_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_container.add_child(map_display)

	# Info panel (right side)
	var info_panel := VBoxContainer.new()
	info_panel.name = "InfoPanel"
	info_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	info_panel.offset_left = -290
	info_panel.offset_right = -10
	info_panel.offset_top = 10
	info_panel.offset_bottom = -200
	screen.add_child(info_panel)

	# Add info labels
	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "Route Planning"
	title.add_theme_font_size_override("font_size", 24)
	info_panel.add_child(title)

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
	screen.add_child(elevation)

	# Controls panel (bottom right)
	var controls := VBoxContainer.new()
	controls.name = "ControlsPanel"
	controls.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	controls.offset_left = -290
	controls.offset_right = -10
	controls.offset_top = -180
	controls.offset_bottom = -10
	screen.add_child(controls)

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

	# Weather panel (top right)
	var weather := VBoxContainer.new()
	weather.name = "WeatherPanel"
	weather.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	weather.offset_left = -150
	weather.offset_right = -10
	weather.offset_top = 10
	weather.offset_bottom = 100
	screen.add_child(weather)

	var weather_label := Label.new()
	weather_label.name = "WeatherLabel"
	weather_label.text = "Weather: --"
	weather.add_child(weather_label)

	return screen
