class_name PhysicalMap
extends Control
## In-game physical map that player can pull out during descent
## Game continues while viewing - player must manage risk of stopping
##
## Design Philosophy:
## - Map is a physical tool, not a pause screen
## - Reading a map in a storm is hard
## - Stopping to check location has real costs

# =============================================================================
# SIGNALS
# =============================================================================

signal map_opened()
signal map_closed()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Time to pull out/put away map (seconds)
const TRANSITION_TIME := 0.4

## Base position uncertainty (meters)
const UNCERTAINTY_BASE := 15.0

## Storm position uncertainty (meters)
const UNCERTAINTY_STORM := 80.0

## Map shake intensity in wind
const WIND_SHAKE_INTENSITY := 3.0

## Visibility reduction in bad weather (0-1)
const STORM_VISIBILITY := 0.4

## Update interval for position (seconds)
const POSITION_UPDATE_INTERVAL := 0.25

# =============================================================================
# STATE
# =============================================================================

## Is map currently visible
var is_open: bool = false

## Is transitioning (opening/closing)
var is_transitioning: bool = false

## Current run context
var run_context: RunContext

## Terrain service reference
var terrain_service: TerrainService

## Topo map generator
var topo_generator: TopoMapGenerator

## Cached map texture
var map_texture: ImageTexture

## Map data
var map_data: TopoMapGenerator.TopoMapData

## Player position on map
var player_map_position: Vector2 = Vector2.ZERO

## Position uncertainty radius
var uncertainty_radius: float = UNCERTAINTY_BASE

## Time since last position update
var position_update_timer: float = 0.0

## Wind shake offset
var shake_offset: Vector2 = Vector2.ZERO

## Shake time accumulator
var shake_time: float = 0.0

# =============================================================================
# NODES
# =============================================================================

var map_container: Control
var map_background: TextureRect
var map_display: TextureRect
var position_marker: Control
var route_overlay: Control
var compass_indicator: Control
var condition_overlay: ColorRect
var info_label: Label

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	topo_generator = TopoMapGenerator.new()

	ServiceLocator.get_service_async("TerrainService", func(ts):
		terrain_service = ts
		_generate_map()
	)

	_build_ui()
	_connect_signals()


func _build_ui() -> void:
	# Main container - positioned in lower portion of screen
	map_container = Control.new()
	map_container.name = "MapContainer"
	map_container.set_anchors_preset(Control.PRESET_CENTER)
	map_container.custom_minimum_size = Vector2(500, 400)
	map_container.pivot_offset = Vector2(250, 400)  # Pivot at bottom center
	add_child(map_container)

	# Map paper background
	map_background = TextureRect.new()
	map_background.name = "MapBackground"
	map_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_background.modulate = Color(0.95, 0.92, 0.85)  # Paper color
	map_container.add_child(map_background)

	# Paper texture simulation
	var paper_style := StyleBoxFlat.new()
	paper_style.bg_color = Color(0.95, 0.92, 0.85)
	paper_style.border_width_left = 2
	paper_style.border_width_right = 2
	paper_style.border_width_top = 2
	paper_style.border_width_bottom = 2
	paper_style.border_color = Color(0.6, 0.55, 0.45)
	paper_style.shadow_size = 8
	paper_style.shadow_color = Color(0, 0, 0, 0.3)
	paper_style.shadow_offset = Vector2(4, 4)

	var paper_panel := Panel.new()
	paper_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	paper_panel.add_theme_stylebox_override("panel", paper_style)
	map_container.add_child(paper_panel)

	# Map margin
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 40)
	map_container.add_child(margin)

	var map_area := Control.new()
	map_area.name = "MapArea"
	margin.add_child(map_area)

	# Actual topo map display
	map_display = TextureRect.new()
	map_display.name = "MapDisplay"
	map_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_display.expand_mode = TextureRect.EXPAND_KEEP_ASPECT_CENTERED
	map_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_area.add_child(map_display)

	# Route overlay
	route_overlay = Control.new()
	route_overlay.name = "RouteOverlay"
	route_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	route_overlay.draw.connect(_on_route_overlay_draw)
	map_area.add_child(route_overlay)

	# Position marker
	position_marker = Control.new()
	position_marker.name = "PositionMarker"
	position_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	position_marker.draw.connect(_on_position_marker_draw)
	map_area.add_child(position_marker)

	# Compass indicator (top right corner)
	compass_indicator = Control.new()
	compass_indicator.name = "Compass"
	compass_indicator.custom_minimum_size = Vector2(40, 40)
	compass_indicator.position = Vector2(420, 10)
	compass_indicator.draw.connect(_on_compass_draw)
	map_container.add_child(compass_indicator)

	# Weather/condition overlay (affects visibility)
	condition_overlay = ColorRect.new()
	condition_overlay.name = "ConditionOverlay"
	condition_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	condition_overlay.color = Color(0.7, 0.75, 0.8, 0.0)  # Snow/fog overlay
	condition_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_container.add_child(condition_overlay)

	# Info label at bottom
	info_label = Label.new()
	info_label.name = "InfoLabel"
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	info_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	info_label.offset_top = -35
	info_label.add_theme_font_size_override("font_size", 12)
	info_label.add_theme_color_override("font_color", Color(0.3, 0.25, 0.2))
	map_container.add_child(info_label)


func _connect_signals() -> void:
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.wind_changed.connect(_on_wind_changed)


func _process(delta: float) -> void:
	if not is_open or is_transitioning:
		return

	# Update position periodically
	position_update_timer += delta
	if position_update_timer >= POSITION_UPDATE_INTERVAL:
		position_update_timer = 0.0
		_update_player_position()

	# Apply wind shake
	_update_shake(delta)

	# Update info
	_update_info_label()


# =============================================================================
# MAP GENERATION
# =============================================================================

func _generate_map() -> void:
	if terrain_service == null:
		return

	# Get terrain bounds
	var bounds_min := terrain_service.terrain_bounds_min
	var bounds_max := terrain_service.terrain_bounds_max

	# Generate topo map data
	var chunks := terrain_service.get_all_chunks()
	map_data = topo_generator.generate_map(chunks, bounds_min, bounds_max)

	# Render to image
	var resolution := Vector2i(600, 600)
	var image := topo_generator.render_to_image(map_data, resolution)

	# Create texture
	map_texture = ImageTexture.create_from_image(image)
	map_display.texture = map_texture


func _update_player_position() -> void:
	run_context = GameStateManager.get_current_run()
	if run_context == null:
		return

	var world_pos := run_context.position
	player_map_position = _world_to_map(Vector2(world_pos.x, world_pos.z))

	# Calculate uncertainty based on conditions
	_calculate_uncertainty()

	# Redraw markers
	position_marker.queue_redraw()
	route_overlay.queue_redraw()


func _calculate_uncertainty() -> void:
	uncertainty_radius = UNCERTAINTY_BASE

	if run_context == null:
		return

	# Weather increases uncertainty
	match run_context.current_weather:
		GameEnums.WeatherState.STORM:
			uncertainty_radius = UNCERTAINTY_STORM
		GameEnums.WeatherState.SNOW:
			uncertainty_radius = UNCERTAINTY_BASE * 3.0
		GameEnums.WeatherState.OVERCAST:
			uncertainty_radius = UNCERTAINTY_BASE * 1.5

	# Fatigue increases uncertainty
	if run_context.body_state:
		var fatigue := run_context.body_state.fatigue
		uncertainty_radius *= (1.0 + fatigue * 0.5)

	# Darkness increases uncertainty
	if run_context.is_dark():
		uncertainty_radius *= 2.0
	elif run_context.is_getting_dark():
		uncertainty_radius *= 1.3


func _world_to_map(world_pos: Vector2) -> Vector2:
	if map_data == null or map_display == null:
		return Vector2.ZERO

	var map_size := map_display.size
	var bounds_size := map_data.bounds_max - map_data.bounds_min

	if bounds_size.x == 0 or bounds_size.y == 0:
		return Vector2.ZERO

	var normalized := (world_pos - map_data.bounds_min) / bounds_size
	return normalized * map_size


# =============================================================================
# SHAKE EFFECT
# =============================================================================

func _update_shake(delta: float) -> void:
	if run_context == null:
		shake_offset = Vector2.ZERO
		return

	shake_time += delta * 10.0

	# Wind strength affects shake
	var wind_factor := 0.0
	match run_context.current_wind:
		GameEnums.WindStrength.MODERATE:
			wind_factor = 0.3
		GameEnums.WindStrength.STRONG:
			wind_factor = 0.7
		GameEnums.WindStrength.GALE:
			wind_factor = 1.0

	# Storm adds extra shake
	if run_context.current_weather >= GameEnums.WeatherState.STORM:
		wind_factor = maxf(wind_factor, 0.8)

	if wind_factor > 0:
		shake_offset = Vector2(
			sin(shake_time * 1.3) * WIND_SHAKE_INTENSITY * wind_factor,
			cos(shake_time * 0.9) * WIND_SHAKE_INTENSITY * wind_factor * 0.7
		)
		map_container.position = shake_offset
	else:
		shake_offset = Vector2.ZERO
		map_container.position = Vector2.ZERO


# =============================================================================
# DRAWING
# =============================================================================

func _on_position_marker_draw() -> void:
	if map_data == null:
		return

	var map_size := map_display.size

	# Draw uncertainty circle
	var uncertainty_pixels := (uncertainty_radius / (map_data.bounds_max.x - map_data.bounds_min.x)) * map_size.x
	position_marker.draw_arc(
		player_map_position,
		uncertainty_pixels,
		0, TAU, 32,
		Color(0.8, 0.3, 0.2, 0.3),
		2.0
	)

	# Draw position dot
	position_marker.draw_circle(player_map_position, 6, Color(0.8, 0.2, 0.1, 0.9))
	position_marker.draw_circle(player_map_position, 4, Color(1.0, 0.4, 0.3, 1.0))

	# Draw direction indicator if moving
	if run_context and run_context.velocity.length() > 0.5:
		var dir := Vector2(run_context.velocity.x, run_context.velocity.z).normalized()
		var arrow_end := player_map_position + dir * 20
		position_marker.draw_line(player_map_position, arrow_end, Color(0.8, 0.2, 0.1), 2.0)

		# Arrow head
		var perp := dir.orthogonal() * 5
		var head_base := arrow_end - dir * 8
		position_marker.draw_polygon(
			[arrow_end, head_base + perp, head_base - perp],
			[Color(0.8, 0.2, 0.1)]
		)


func _on_route_overlay_draw() -> void:
	if run_context == null or map_data == null:
		return

	# Draw planned route
	var planned_route = run_context.get_meta("planned_route", PackedVector3Array())
	if planned_route.size() >= 2:
		var points := PackedVector2Array()
		for wp in planned_route:
			var map_pos := _world_to_map(Vector2(wp.x, wp.z))
			points.append(map_pos)

		# Dashed line effect
		route_overlay.draw_polyline(points, Color(0.2, 0.2, 0.6, 0.5), 2.0)

	# Draw traveled path
	if run_context.path_history.size() >= 2:
		var points := PackedVector2Array()
		for pos in run_context.path_history:
			var map_pos := _world_to_map(Vector2(pos.x, pos.z))
			points.append(map_pos)

		route_overlay.draw_polyline(points, Color(0.6, 0.2, 0.2, 0.6), 1.5)


func _on_compass_draw() -> void:
	var center := Vector2(20, 20)
	var radius := 15.0

	# Compass circle
	compass_indicator.draw_arc(center, radius, 0, TAU, 32, Color(0.3, 0.25, 0.2), 1.0)

	# North indicator
	var north := center + Vector2(0, -radius + 2)
	compass_indicator.draw_line(center, north, Color(0.8, 0.2, 0.1), 2.0)

	# N label
	var font := ThemeDB.fallback_font
	compass_indicator.draw_string(font, Vector2(15, 8), "N", HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color(0.8, 0.2, 0.1))


# =============================================================================
# INFO DISPLAY
# =============================================================================

func _update_info_label() -> void:
	if run_context == null:
		info_label.text = ""
		return

	var elevation := run_context.current_elevation
	var time_str := "%02d:%02d" % [int(run_context.current_time), int(fmod(run_context.current_time, 1.0) * 60)]

	var uncertainty_str := ""
	if uncertainty_radius > UNCERTAINTY_BASE * 1.5:
		uncertainty_str = " (position uncertain)"

	info_label.text = "Elevation: %.0fm  |  Time: %s%s" % [elevation, time_str, uncertainty_str]


# =============================================================================
# WEATHER EFFECTS
# =============================================================================

func _on_weather_changed(_old_weather: GameEnums.WeatherState, _new_weather: GameEnums.WeatherState) -> void:
	_update_condition_overlay()


func _on_wind_changed(_strength: GameEnums.WindStrength, _direction: Vector3) -> void:
	# Wind affects shake, handled in _process
	pass


func _update_condition_overlay() -> void:
	if run_context == null:
		condition_overlay.color.a = 0.0
		return

	# Weather affects map visibility
	match run_context.current_weather:
		GameEnums.WeatherState.STORM:
			condition_overlay.color = Color(0.6, 0.65, 0.7, 0.5)
		GameEnums.WeatherState.SNOW:
			condition_overlay.color = Color(0.8, 0.82, 0.85, 0.3)
		GameEnums.WeatherState.OVERCAST:
			condition_overlay.color = Color(0.7, 0.72, 0.75, 0.1)
		_:
			condition_overlay.color.a = 0.0


# =============================================================================
# SHOW/HIDE
# =============================================================================

func open_map() -> void:
	if is_open or is_transitioning:
		return

	is_transitioning = true
	visible = true

	# Play map unfold sound
	var audio_service = ServiceLocator.get_service("AudioService")
	if audio_service:
		audio_service.play_map_open()

	# Update data
	run_context = GameStateManager.get_current_run()
	_update_player_position()
	_update_condition_overlay()

	# Animate opening - slide up from bottom
	map_container.scale = Vector2(0.8, 0.0)
	map_container.modulate.a = 0.0

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(map_container, "scale", Vector2(1.0, 1.0), TRANSITION_TIME).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(map_container, "modulate:a", 1.0, TRANSITION_TIME * 0.7)
	tween.chain().tween_callback(func():
		is_transitioning = false
		is_open = true
		map_opened.emit()
	)


func close_map() -> void:
	if not is_open or is_transitioning:
		return

	is_transitioning = true

	# Play map fold sound
	var audio_service = ServiceLocator.get_service("AudioService")
	if audio_service:
		audio_service.play_map_close()

	# Animate closing - slide down
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(map_container, "scale", Vector2(0.9, 0.0), TRANSITION_TIME * 0.7).set_ease(Tween.EASE_IN)
	tween.tween_property(map_container, "modulate:a", 0.0, TRANSITION_TIME * 0.5)
	tween.chain().tween_callback(func():
		is_transitioning = false
		is_open = false
		visible = false
		map_closed.emit()
	)


func toggle_map() -> void:
	if is_open:
		close_map()
	else:
		open_map()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	# Close on escape or map button
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("open_map"):
		close_map()
		get_viewport().set_input_as_handled()
