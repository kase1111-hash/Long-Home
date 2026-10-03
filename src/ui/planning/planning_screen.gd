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
##
## Planning happens at the hut, on paper: the topo map, the guidebook (lines
## graded and timed, pitch-by-pitch topos), the forecast and the clock. The
## guidebook's lines are inked on the paper map only; nothing is ever marked
## on the mountain itself. On a full route the ascent and the descent are
## planned as two legs, with a turnaround time.

# =============================================================================
# SIGNALS
# =============================================================================

signal planning_complete(route: PackedVector3Array)
signal planning_cancelled()
signal route_updated(analysis: RoutePlanner.RouteAnalysis)

# =============================================================================
# CONSTANTS
# =============================================================================

## Below this knowledge only the printed guide is known; hut-book lines come
## from having been on the mountain
const HUT_BOOK_KNOWLEDGE := GameEnums.KnowledgeLevel.ATTEMPTED

## Safety margin kept before sunset when working out the turnaround (hours)
const TURNAROUND_MARGIN := 1.0

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

var leg_bar: HBoxContainer
var ascent_button: Button
var descent_button: Button
var guide_list: VBoxContainer
var guide_card: VBoxContainer
var follow_button: Button
var guide_note: Label

# =============================================================================
# STATE
# =============================================================================

## Route planner
var route_planner: RoutePlanner

## Current route analysis (the leg being edited)
var current_analysis: RoutePlanner.RouteAnalysis

## Book measurement of each planned leg (RunPhase -> RouteMetrics.Result)
var leg_metrics: Dictionary = {}

## Terrain service reference
var terrain_service: TerrainService

## Weather service reference
var weather_service: WeatherService

## Current run context
var run_context: RunContext

## Is route valid for descent
var route_valid: bool = false

## Descent only, or the full route (two legs)
var route_mode: GameEnums.RouteMode = GameEnums.RouteMode.DESCENT

## The guidebook for the loaded mountain
var guide_routes: Array[RouteSurvey.GuideRoute] = []

## Guidebook line being read (index into guide_routes, -1 = none)
var selected_guide: int = -1

## Guidebook line copied onto each leg's plan (RunPhase -> route id)
var followed_guide: Dictionary = {}


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
		_refresh_all.call_deferred()
	)
	ServiceLocator.get_service_async("WeatherService", func(w):
		weather_service = w
		_update_weather_display()
	)

	_connect_signals()
	_setup_ui()
	_update_weather_display()


func _on_terrain_loaded(_mountain_id: String) -> void:
	followed_guide.clear()
	selected_guide = -1
	_refresh_all.call_deferred()


## Re-evaluate the route and forecast (called by Main whenever the screen is shown)
func refresh() -> void:
	_refresh_all()


func _refresh_all() -> void:
	_read_route_mode()
	_refresh_guidebook()
	_analyze_current_route()
	_update_weather_display()


func _resolve_nodes() -> void:
	map_display = get_node_or_null("MapContainer/TopoMapDisplay") as TopoMapDisplay
	route_info_panel = find_child("PlanContent", true, false) as Control
	if route_info_panel == null:
		route_info_panel = get_node_or_null("InfoPanel") as Control
	elevation_profile = get_node_or_null("ElevationProfile") as Control
	controls_panel = get_node_or_null("ControlsPanel") as Control
	weather_panel = find_child("WeatherPanel", true, false) as Control
	confirm_button = get_node_or_null("ControlsPanel/ConfirmButton") as Button
	clear_button = get_node_or_null("ControlsPanel/ClearButton") as Button
	back_button = get_node_or_null("ControlsPanel/BackButton") as Button
	leg_bar = find_child("LegBar", true, false) as HBoxContainer
	ascent_button = find_child("AscentLegButton", true, false) as Button
	descent_button = find_child("DescentLegButton", true, false) as Button
	guide_list = find_child("GuideList", true, false) as VBoxContainer
	guide_card = find_child("GuideCard", true, false) as VBoxContainer
	follow_button = find_child("FollowButton", true, false) as Button
	guide_note = find_child("GuideNote", true, false) as Label


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

	if ascent_button:
		ascent_button.pressed.connect(_on_leg_pressed.bind(GameEnums.RunPhase.ASCENT))
	if descent_button:
		descent_button.pressed.connect(_on_leg_pressed.bind(GameEnums.RunPhase.DESCENT))
	if follow_button:
		follow_button.pressed.connect(_on_follow_pressed)


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
		map_display.clear_all_waypoints()

	current_analysis = null
	route_valid = false
	followed_guide.clear()
	if confirm_button:
		confirm_button.disabled = true

	_update_route_info()
	_update_weather_display()


## The planned line for a leg (default: the descent)
func get_planned_route(leg: int = GameEnums.RunPhase.DESCENT) -> PackedVector3Array:
	if map_display:
		return map_display.get_planned_route_3d(leg)
	return PackedVector3Array()


## Guidebook line the descent plan was copied from ("" = own line)
func get_selected_guide_id() -> String:
	return str(followed_guide.get(GameEnums.RunPhase.DESCENT, ""))


## The leg being edited
func get_active_leg() -> int:
	if map_display != null:
		return map_display.active_leg
	return GameEnums.RunPhase.DESCENT


# =============================================================================
# ROUTE MODE AND LEGS
# =============================================================================

func _read_route_mode() -> void:
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	route_mode = mountain_db.get_route_mode() if mountain_db != null else GameEnums.RouteMode.DESCENT
	var full := route_mode == GameEnums.RouteMode.FULL_ROUTE
	if map_display != null:
		map_display.set_full_route(full)
		if full and map_display.active_leg != GameEnums.RunPhase.ASCENT and map_display.get_planned_route(GameEnums.RunPhase.ASCENT).size() <= 2:
			map_display.set_active_leg(GameEnums.RunPhase.ASCENT)
	if leg_bar != null:
		leg_bar.visible = full
	if confirm_button != null:
		confirm_button.text = "Leave Base Camp" if full else "Begin Descent"
	_update_leg_buttons()


func _update_leg_buttons() -> void:
	var leg := get_active_leg()
	if ascent_button != null:
		ascent_button.button_pressed = leg == GameEnums.RunPhase.ASCENT
	if descent_button != null:
		descent_button.button_pressed = leg == GameEnums.RunPhase.DESCENT


func _on_leg_pressed(leg: GameEnums.RunPhase) -> void:
	if map_display != null:
		map_display.set_active_leg(leg)
	_update_leg_buttons()
	_show_guide_card()
	_analyze_current_route()


# =============================================================================
# GUIDEBOOK
# =============================================================================

func _refresh_guidebook() -> void:
	if guide_list == null:
		return
	for child in guide_list.get_children():
		child.queue_free()
	guide_routes.clear()
	if terrain_service == null or terrain_service.chunks.is_empty():
		_set_guide_note("The guidebook is on the shelf: waiting for the map.")
		return

	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain_id := terrain_service.current_mountain
	var knowledge := mountain_db.get_knowledge_level(mountain_id) if mountain_db != null else GameEnums.KnowledgeLevel.UNKNOWN

	var hidden := 0
	for route in RouteSurvey.survey(terrain_service):
		if not route.published and knowledge < HUT_BOOK_KNOWLEDGE:
			hidden += 1
			continue
		guide_routes.append(route)

	var lines: Array[Dictionary] = []
	for i in range(guide_routes.size()):
		var route := guide_routes[i]
		lines.append({"points": route.line, "color": route.color})
		var button := Button.new()
		button.name = "Guide_" + route.id
		button.toggle_mode = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		var climbed := mountain_db != null and mountain_db.has_climbed_route(mountain_id, route.id)
		var source := "" if route.published else "  (hut book)"
		button.text = "%s%s   %s · %s%s" % [
			"✓ " if climbed else "", route.name, route.metrics.get_full_grade(),
			RouteMetrics.format_minutes(route.metrics.minutes), source
		]
		button.add_theme_color_override("font_color", route.color.lightened(0.45))
		button.pressed.connect(_on_guide_pressed.bind(i))
		guide_list.add_child(button)

	if hidden > 0:
		_set_guide_note("Other lines are talked about at the hut. Get to know the mountain and you will hear of them.")
	else:
		_set_guide_note("")

	if selected_guide >= guide_routes.size():
		selected_guide = -1
	if map_display != null:
		map_display.set_guide_lines(lines, selected_guide)
	_show_guide_card()


func _set_guide_note(text: String) -> void:
	if guide_note != null:
		guide_note.text = text
		guide_note.visible = not text.is_empty()


func _on_guide_pressed(index: int) -> void:
	selected_guide = index if selected_guide != index else -1
	if map_display != null:
		map_display.set_highlighted_guide(selected_guide)
	_show_guide_card()


## Fill the route card for the line being read (ascent wording on the up leg)
func _show_guide_card() -> void:
	if guide_list != null:
		for i in range(guide_list.get_child_count()):
			var button := guide_list.get_child(i) as Button
			if button != null:
				button.button_pressed = i == selected_guide
	if guide_card == null:
		return
	if selected_guide < 0 or selected_guide >= guide_routes.size():
		for child in guide_card.get_children():
			child.queue_free()
		var hint := Label.new()
		hint.text = "Pick a line to read its description. Lines are inked on your map; nothing is marked on the mountain."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_color_override("font_color", RouteCard.SCREEN_DIM)
		guide_card.add_child(hint)
		if follow_button != null:
			follow_button.disabled = true
			follow_button.text = "Follow this line"
		return

	var route := guide_routes[selected_guide]
	var climbing := get_active_leg() == GameEnums.RunPhase.ASCENT and route_mode == GameEnums.RouteMode.FULL_ROUTE
	var metrics := route.get_ascent_metrics(terrain_service) if climbing else route.metrics
	RouteCard.fill(guide_card, route.name, metrics, {
		"description": route.description,
		"ascending": climbing,
	})
	if follow_button != null:
		var blocked := climbing and metrics.ascent_blocked
		follow_button.disabled = blocked
		if route_mode == GameEnums.RouteMode.FULL_ROUTE:
			follow_button.text = "Climb this line" if climbing else "Descend this line"
		else:
			follow_button.text = "Follow this line"
		if blocked:
			follow_button.text = "No way up this line on foot"


## Copy the line being read onto the plan for the leg being edited
func _on_follow_pressed() -> void:
	if selected_guide < 0 or selected_guide >= guide_routes.size() or map_display == null:
		return
	var route := guide_routes[selected_guide]
	var leg := get_active_leg()
	var points := route.waypoints
	if leg == GameEnums.RunPhase.ASCENT:
		points = route.waypoints.duplicate()
		points.reverse()
	map_display.set_waypoints(points, leg)
	followed_guide[leg] = route.id
	_analyze_current_route()


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_waypoint_placed(_world_pos: Vector2) -> void:
	# Your own pencil marks: the plan is no longer the book's line
	followed_guide.erase(get_active_leg())
	_analyze_current_route()


func _on_waypoint_removed(_index: int) -> void:
	followed_guide.erase(get_active_leg())
	_analyze_current_route()


func _on_map_clicked(world_pos: Vector2) -> void:
	# Show info about clicked location
	_show_location_info(world_pos)


func _on_confirm_pressed() -> void:
	if not route_valid:
		return

	var route := get_planned_route(GameEnums.RunPhase.DESCENT)
	planning_complete.emit(route)

	# Transition to descent
	GameStateManager.transition_to(GameEnums.GameState.DESCENT)


func _on_clear_pressed() -> void:
	if map_display:
		map_display.clear_waypoints()
	followed_guide.erase(get_active_leg())

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
	if terrain_service == null or confirm_button == null:
		return

	var route := get_planned_route(get_active_leg())
	if route.size() < 2:
		current_analysis = null
		route_valid = false
		confirm_button.disabled = true
		_update_route_info()
		return

	current_analysis = route_planner.analyze_route(route, terrain_service)

	# Book measurement of every leg that will be travelled, for this pack
	var options := _pack_options()
	leg_metrics.clear()
	leg_metrics[GameEnums.RunPhase.DESCENT] = RouteMetrics.measure(get_planned_route(GameEnums.RunPhase.DESCENT), terrain_service, options)
	if route_mode == GameEnums.RouteMode.FULL_ROUTE:
		leg_metrics[GameEnums.RunPhase.ASCENT] = RouteMetrics.measure(get_planned_route(GameEnums.RunPhase.ASCENT), terrain_service, options)

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
	var day_label := _get_or_create_label(route_info_panel, "DayPlanLabel")
	var distance_label := _get_or_create_label(route_info_panel, "DistanceLabel")
	var elevation_label := _get_or_create_label(route_info_panel, "ElevationLabel")
	var time_label := _get_or_create_label(route_info_panel, "TimeLabel")
	var grade_label := _get_or_create_label(route_info_panel, "GradeLabel")
	var risk_label := _get_or_create_label(route_info_panel, "RiskLabel")
	var warnings_label := _get_or_create_label(route_info_panel, "WarningsLabel")
	var recommendations_label := _get_or_create_label(route_info_panel, "RecommendationsLabel")
	var logbook_label := _get_or_create_label(route_info_panel, "LogbookLabel")

	logbook_label.text = _logbook_text()

	if current_analysis == null:
		day_label.text = ""
		distance_label.text = "Distance: --"
		elevation_label.text = "Elevation: --"
		time_label.text = "Book time: --"
		grade_label.text = "Grade: --"
		risk_label.text = "Risk: --"
		warnings_label.text = ""
		recommendations_label.text = "Waiting for terrain..."
		return

	var leg := get_active_leg()
	var metrics: RouteMetrics.Result = leg_metrics.get(leg)
	var climbing := leg == GameEnums.RunPhase.ASCENT and route_mode == GameEnums.RouteMode.FULL_ROUTE

	# Update stats
	distance_label.text = "Distance: %.0fm" % current_analysis.total_distance
	if climbing:
		elevation_label.text = "Ascent: %.0fm" % (metrics.get_vertical() if metrics != null else current_analysis.total_elevation_change)
	else:
		elevation_label.text = "Descent: %.0fm" % current_analysis.total_elevation_change
	if metrics != null:
		time_label.text = "Book time: %s" % RouteMetrics.format_minutes(metrics.minutes)
		grade_label.text = "Grade: %s (%s)" % [metrics.get_full_grade(), AlpineGrade.grade_word(metrics.grade_value)]
		grade_label.add_theme_color_override("font_color", AlpineGrade.grade_color(metrics.grade_value).lightened(0.2))
	else:
		time_label.text = "Book time: %s" % RoutePlanner.format_time(current_analysis.estimated_total_time)
		grade_label.text = "Grade: --"

	day_label.text = _day_plan_text()

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
	var warnings: Array[String] = []
	warnings.assign(current_analysis.warnings)
	if climbing and metrics != null and metrics.ascent_blocked:
		warnings.append("The planned way up crosses a cliff band that cannot be climbed on foot.")
	if not climbing and metrics != null and metrics.rope_required:
		var rope := _carried_rope_length()
		if rope <= 0.0:
			warnings.append("This line needs %d abseil%s and you have no rope." % [metrics.rappels, "" if metrics.rappels == 1 else "s"])
		elif rope < metrics.min_rope_length:
			warnings.append("Your %d m rope is short for a %d m abseil." % [roundi(rope), roundi(metrics.longest_rappel)])
	if warnings.size() > 0:
		warnings_label.text = "Warnings:\n" + "\n".join(warnings)
	else:
		warnings_label.text = ""

	# Recommendations
	var notes: Array[String] = []
	notes.append("Double-click the map to add waypoints, or follow a line from the guidebook.")
	if route_mode == GameEnums.RouteMode.FULL_ROUTE:
		notes.append("Plan both legs: the way up from base camp and the way down from the summit.")
	for recommendation in current_analysis.recommendations:
		notes.append(str(recommendation))
	recommendations_label.text = "\n".join(notes)

	# Viability
	if not current_analysis.is_viable:
		warnings_label.text += "\n\n⚠ " + current_analysis.viability_reason
		warnings_label.text += "\nYou can still commit to this line."


## Start, arrival, sunset and (full route) turnaround, from the book times
func _day_plan_text() -> String:
	var conditions := StartConditions.create_moderate()
	conditions.apply_route_mode(route_mode)
	var start := conditions.time_of_day
	var sunset := conditions.calculate_sunset()
	var down: RouteMetrics.Result = leg_metrics.get(GameEnums.RunPhase.DESCENT)
	if down == null:
		return ""
	var lines: Array[String] = []
	if route_mode == GameEnums.RouteMode.FULL_ROUTE:
		var up: RouteMetrics.Result = leg_metrics.get(GameEnums.RunPhase.ASCENT)
		if up == null:
			return ""
		var summit_at := start + up.minutes / 60.0
		var home_at := summit_at + down.minutes / 60.0
		lines.append("Alpine start %s · summit ~%s · back ~%s" % [_clock(start), _clock(summit_at), _clock(home_at)])
		lines.append("Sunset %s · %s of daylight to spare" % [_clock(sunset), _hours_text(sunset - home_at)])
		# Turn around in time to get down at book pace with a margin, padded
		# for a tired descent
		var turnaround := sunset - TURNAROUND_MARGIN - down.minutes / 60.0 * 1.5
		lines.append("Turnaround: %s. Not on top by then? Go down." % _clock(maxf(turnaround, start)))
	else:
		var home_at := start + down.minutes / 60.0
		lines.append("Start %s · back ~%s · sunset %s" % [_clock(start), _clock(home_at), _clock(sunset)])
		lines.append("%s of daylight to spare" % _hours_text(sunset - home_at).capitalize())
	return "\n".join(lines)


func _clock(hours: float) -> String:
	var h := fposmod(hours, 24.0)
	return "%02d:%02d" % [int(h), int(fmod(h * 60.0, 60.0))]


func _hours_text(hours: float) -> String:
	if hours <= 0.0:
		return "none"
	return RouteMetrics.format_minutes(hours * 60.0)


func _carried_rope_length() -> float:
	return _current_loadout().get_rope_length()


## The pack chosen on the loadout screen (the standard pack before that)
func _current_loadout() -> GearState:
	var main := get_tree().current_scene if is_inside_tree() else null
	var loadout_screen = main.get("loadout_config_screen") if main != null else null
	if loadout_screen != null and loadout_screen.has_method("get_loadout"):
		var loadout: GearState = loadout_screen.get_loadout()
		if loadout != null:
			return loadout.duplicate_state()
	return GearState.create_standard_loadout().duplicate_state()


## Book-time options for this pack (the same ones the scorer uses)
func _pack_options() -> Dictionary:
	var loadout := _current_loadout()
	var options := {
		"has_crampons": loadout.has_crampons(),
		"weight_modifier": loadout.get_weight_modifier(),
	}
	if loadout.get_rope_length() > 0.0:
		options["rope_length"] = loadout.get_rope_length()
	return options


func _logbook_text() -> String:
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db == null or terrain_service == null:
		return ""
	var progress := mountain_db.get_progress(terrain_service.current_mountain)
	if progress.logbook.is_empty():
		return "Logbook: no entries on this mountain yet."
	var best := progress.best_full_score if route_mode == GameEnums.RouteMode.FULL_ROUTE else progress.best_score
	var last: Dictionary = progress.logbook[0]
	var route_name: String = last.get("route", "")
	if route_name.is_empty():
		route_name = "own line"
	return "Logbook: best %d pts · last %s, %s, %d pts" % [best, route_name, last.get("grade", "?"), int(last.get("total", 0))]


func _get_or_create_label(parent: Control, label_name: String) -> Label:
	var existing := parent.get_node_or_null(label_name)
	if existing:
		return existing as Label

	var label := Label.new()
	label.name = label_name
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _update_elevation_profile() -> void:
	if elevation_profile == null or terrain_service == null:
		return

	if current_analysis == null:
		return

	var route := get_planned_route(get_active_leg())
	var profile_data := route_planner.get_elevation_profile(route, terrain_service)

	# Store data for custom drawing
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
	var zone := GameEnums.get_terrain_zone(slope)

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
	map_container.offset_right = -400  # Leave room for panels
	map_container.offset_bottom = -160  # Leave room for the elevation profile
	add_child(map_container)

	# Topo map display
	var topo_display := TopoMapDisplay.new()
	topo_display.name = "TopoMapDisplay"
	topo_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_container.add_child(topo_display)

	# Info panel (right side): title, legs, then the plan and the guidebook
	var info_panel := VBoxContainer.new()
	info_panel.name = "InfoPanel"
	info_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	info_panel.offset_left = -390
	info_panel.offset_right = -10
	info_panel.offset_top = 10
	info_panel.offset_bottom = -190
	add_child(info_panel)

	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "Route Planning"
	title.add_theme_font_size_override("font_size", 24)
	info_panel.add_child(title)

	var legs := HBoxContainer.new()
	legs.name = "LegBar"
	legs.visible = false
	info_panel.add_child(legs)
	var up := Button.new()
	up.name = "AscentLegButton"
	up.text = "Ascent"
	up.toggle_mode = true
	up.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legs.add_child(up)
	var down := Button.new()
	down.name = "DescentLegButton"
	down.text = "Descent"
	down.toggle_mode = true
	down.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legs.add_child(down)

	var tabs := TabContainer.new()
	tabs.name = "Tabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_panel.add_child(tabs)

	# --- Plan tab ---
	var plan_scroll := ScrollContainer.new()
	plan_scroll.name = "Plan"
	plan_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(plan_scroll)
	var plan := VBoxContainer.new()
	plan.name = "PlanContent"
	plan.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plan_scroll.add_child(plan)

	# Forecast (typical conditions before the run, live weather during it)
	var weather := VBoxContainer.new()
	weather.name = "WeatherPanel"
	plan.add_child(weather)
	var weather_label := Label.new()
	weather_label.name = "WeatherLabel"
	weather_label.text = "Weather: --"
	weather.add_child(weather_label)

	plan.add_child(HSeparator.new())

	var day := Label.new()
	day.name = "DayPlanLabel"
	day.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	plan.add_child(day)

	plan.add_child(HSeparator.new())

	for label_name in ["DistanceLabel", "ElevationLabel", "TimeLabel", "GradeLabel", "RiskLabel"]:
		var label := Label.new()
		label.name = label_name
		label.text = label_name.replace("Label", "") + ": --"
		plan.add_child(label)

	plan.add_child(HSeparator.new())

	var warnings := Label.new()
	warnings.name = "WarningsLabel"
	warnings.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	plan.add_child(warnings)

	var recommendations := Label.new()
	recommendations.name = "RecommendationsLabel"
	recommendations.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	plan.add_child(recommendations)

	plan.add_child(HSeparator.new())

	var logbook := Label.new()
	logbook.name = "LogbookLabel"
	logbook.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	logbook.add_theme_color_override("font_color", RouteCard.SCREEN_DIM)
	plan.add_child(logbook)

	# --- Guidebook tab ---
	var guide_scroll := ScrollContainer.new()
	guide_scroll.name = "Guidebook"
	guide_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(guide_scroll)
	var guide := VBoxContainer.new()
	guide.name = "GuideContent"
	guide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	guide.add_theme_constant_override("separation", 6)
	guide_scroll.add_child(guide)

	var guide_list_box := VBoxContainer.new()
	guide_list_box.name = "GuideList"
	guide.add_child(guide_list_box)

	var note := Label.new()
	note.name = "GuideNote"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", RouteCard.SCREEN_DIM)
	guide.add_child(note)

	guide.add_child(HSeparator.new())

	var card := VBoxContainer.new()
	card.name = "GuideCard"
	card.add_theme_constant_override("separation", 3)
	guide.add_child(card)

	var follow := Button.new()
	follow.name = "FollowButton"
	follow.text = "Follow this line"
	follow.disabled = true
	guide.add_child(follow)

	# Elevation profile (bottom)
	var elevation := Control.new()
	elevation.name = "ElevationProfile"
	elevation.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	elevation.offset_top = -150
	elevation.offset_left = 10
	elevation.offset_right = -410
	elevation.offset_bottom = -60
	add_child(elevation)

	# Controls panel (bottom right)
	var controls := VBoxContainer.new()
	controls.name = "ControlsPanel"
	controls.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	controls.offset_left = -390
	controls.offset_right = -10
	controls.offset_top = -170
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
