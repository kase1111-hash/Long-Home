class_name TopoReplayVisualization
extends Control
## The run on the map: the line you travelled drawn over the topo, where
## things happened, and a playhead to go through the day again.
##
## Design Philosophy:
## - Let players understand their journey
## - Highlight key moments without sensationalizing
## - Respect the weight of fatal outcomes
##
## Opened from the post-game screen ("Replay on the map"). Times here are
## game hours since the run started, the unit RunContext records in.

# =============================================================================
# SIGNALS
# =============================================================================

signal moment_selected(moment: Dictionary)
signal playback_complete()
signal close_requested()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Seconds the line takes to draw itself when the screen opens
const PATH_DRAW_DURATION := 5.0

## Seconds a whole run takes to play back at 1x, however long the day was
const REPLAY_SECONDS := 30.0

const PLAYHEAD_RADIUS := 8.0
const MARKER_RADIUS := 6.0
const TIMELINE_HEIGHT := 34.0
const PATH_WIDTH := 2.5

## Marker colours by kind of moment (RunMoments.Kind)
const MARKER_COLORS := {
	RunMoments.Kind.DECISION: Color(0.45, 0.6, 0.85, 0.95),
	RunMoments.Kind.SLIDE: Color(0.85, 0.65, 0.25, 0.95),
	RunMoments.Kind.ROPE: Color(0.45, 0.75, 0.55, 0.95),
	RunMoments.Kind.HAZARD: Color(0.9, 0.55, 0.3, 0.95),
	RunMoments.Kind.HURT: Color(0.85, 0.42, 0.34, 0.95),
	RunMoments.Kind.FATAL: Color(0.62, 0.3, 0.3, 0.9),
}

## The line is coloured by how each stretch was travelled (RouteMetrics.MODE_*)
const MODE_COLORS := {
	RouteMetrics.MODE_FOOT: Color(0.95, 0.82, 0.45),
	RouteMetrics.MODE_CLIMB: Color(0.95, 0.6, 0.3),
	RouteMetrics.MODE_ROPE: Color(0.45, 0.8, 0.55),
	RouteMetrics.MODE_GLIDE: Color(0.45, 0.72, 0.95),
	RouteMetrics.MODE_ADRIFT: Color(0.9, 0.36, 0.32),
}
const MODE_NAMES := {
	RouteMetrics.MODE_FOOT: "On foot",
	RouteMetrics.MODE_CLIMB: "Climbing",
	RouteMetrics.MODE_ROPE: "On the rope",
	RouteMetrics.MODE_GLIDE: "Sliding or skiing",
	RouteMetrics.MODE_ADRIFT: "Out of control",
}

# =============================================================================
# STATE
# =============================================================================

## Run being shown
var run_context: RunContext

## Recording data (if available; not used by the map)
var recording_data: Dictionary

## The travelled line: world positions, game hours, travel modes
var path_points_3d: PackedVector3Array
var path_timestamps: PackedFloat64Array
var path_modes: PackedByteArray

## The same line on the map, for the rectangle the map is drawn in now
var path_points_2d: PackedVector2Array
var _points_rect: Rect2 = Rect2()

## Key moments (RunMoments)
var moments: Array[Dictionary] = []

var topo_texture: ImageTexture
var map_bounds_min: Vector2
var map_bounds_max: Vector2

## Playback, in game hours
var is_playing: bool = false
var playback_time: float = 0.0
var playback_speed: float = 1.0
var total_duration: float = 0.0
var playhead_position: Vector2 = Vector2.ZERO

## Selected moment index (-1 = none)
var selected_moment: int = -1

## The line drawing itself when the screen opens (0-1)
var path_draw_progress: float = 0.0
var is_drawing_path: bool = false

var _scrubbing: bool = false

# =============================================================================
# NODES
# =============================================================================

var background: ColorRect
var title_label: Label
var map_panel: Panel
var map_display: Control
var timeline_track: Control
var play_button: Button
var speed_button: Button
var time_label: Label
var legend: HBoxContainer
var moments_list: VBoxContainer
var close_button: Button

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	visible = false
	_build_ui()


func _build_ui() -> void:
	background = ColorRect.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.05, 0.05, 0.08)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 30)
	margin.add_child(columns)

	_build_map_column(columns)
	_build_moments_column(columns)


func _build_map_column(parent: Control) -> void:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_stretch_ratio = 2.2
	column.add_theme_constant_override("separation", 10)
	parent.add_child(column)

	title_label = Label.new()
	title_label.text = "YOUR LINE"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 20)
	title_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.8))
	column.add_child(title_label)

	map_panel = Panel.new()
	map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1)
	style.set_border_width_all(2)
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_corner_radius_all(4)
	map_panel.add_theme_stylebox_override("panel", style)
	column.add_child(map_panel)

	map_display = Control.new()
	map_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_display.clip_contents = true
	map_display.draw.connect(_on_map_draw)
	map_display.gui_input.connect(_on_map_input)
	map_panel.add_child(map_display)

	legend = HBoxContainer.new()
	legend.alignment = BoxContainer.ALIGNMENT_CENTER
	legend.add_theme_constant_override("separation", 18)
	column.add_child(legend)

	timeline_track = Control.new()
	timeline_track.custom_minimum_size = Vector2(0, TIMELINE_HEIGHT)
	timeline_track.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	timeline_track.draw.connect(_on_timeline_draw)
	timeline_track.gui_input.connect(_on_timeline_input)
	column.add_child(timeline_track)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 10)
	column.add_child(controls)

	play_button = Button.new()
	play_button.text = "Play"
	play_button.custom_minimum_size = Vector2(90, 32)
	play_button.pressed.connect(_on_play_pressed)
	controls.add_child(play_button)

	speed_button = Button.new()
	speed_button.text = "1x"
	speed_button.custom_minimum_size = Vector2(50, 32)
	speed_button.pressed.connect(_on_speed_pressed)
	controls.add_child(speed_button)

	time_label = Label.new()
	time_label.add_theme_font_size_override("font_size", 14)
	time_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.84))
	controls.add_child(time_label)


func _build_moments_column(parent: Control) -> void:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.custom_minimum_size = Vector2(300, 0)
	column.add_theme_constant_override("separation", 15)
	parent.add_child(column)

	var title := Label.new()
	title.text = "KEY MOMENTS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.8))
	column.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	moments_list = VBoxContainer.new()
	moments_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	moments_list.add_theme_constant_override("separation", 4)
	scroll.add_child(moments_list)

	close_button = Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(0, 40)
	close_button.pressed.connect(_on_close_pressed)
	column.add_child(close_button)


func _process(delta: float) -> void:
	if not visible:
		return

	# The line draws itself first
	if is_drawing_path:
		path_draw_progress += delta / PATH_DRAW_DURATION
		if path_draw_progress >= 1.0:
			path_draw_progress = 1.0
			is_drawing_path = false
		map_display.queue_redraw()

	# Then the day can be played through
	if is_playing and not is_drawing_path:
		playback_time += delta * playback_speed * total_duration / REPLAY_SECONDS
		if playback_time >= total_duration:
			playback_time = total_duration
			is_playing = false
			play_button.text = "Play"
			playback_complete.emit()
		_refresh_playhead()


# =============================================================================
# SHOWING A RUN
# =============================================================================

func show_visualization(context: RunContext, recording: Dictionary = {}) -> void:
	run_context = context
	recording_data = recording

	visible = true
	is_drawing_path = true
	path_draw_progress = 0.0
	playback_time = 0.0
	playback_speed = 1.0
	is_playing = false
	selected_moment = -1
	play_button.text = "Play"
	speed_button.text = "1x"

	_extract_path_data()
	moments = RunMoments.collect(run_context)
	_generate_topo_map()
	_populate_legend()
	_populate_moments_list()

	title_label.text = "YOUR LINE ON %s" % _mountain_name().to_upper() if not _mountain_name().is_empty() else "YOUR LINE"
	_refresh_playhead()


func hide_visualization() -> void:
	visible = false
	is_playing = false


func _mountain_name() -> String:
	if run_context == null:
		return ""
	var database := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if database != null:
		var mountain := database.get_mountain(run_context.mountain_id)
		if mountain != null:
			return mountain.name
	return ""


func _extract_path_data() -> void:
	path_points_3d = run_context.path_history.duplicate()
	path_timestamps = run_context.path_timestamps.duplicate()
	path_modes = run_context.path_modes.duplicate()
	path_points_2d.clear()
	_points_rect = Rect2()

	if path_timestamps.size() > 0:
		total_duration = path_timestamps[path_timestamps.size() - 1]
	else:
		total_duration = 0.0
	# A run can go on after the last metre moved (waiting, a burial)
	total_duration = maxf(total_duration, run_context.game_time_elapsed)


func _generate_topo_map() -> void:
	topo_texture = null
	var terrain_service := ServiceLocator.get_service("TerrainService") as TerrainService
	if terrain_service == null:
		return

	# Map data and image are shared with the other map displays (generated
	# once per terrain load)
	var topo_generator := TopoMapGenerator.new()
	var map_data := topo_generator.get_terrain_map(terrain_service)
	if map_data == null:
		return
	map_bounds_min = map_data.bounds_min
	map_bounds_max = map_data.bounds_max
	var image := topo_generator.get_terrain_image(terrain_service, Vector2i(1024, 1024))
	if image != null:
		topo_texture = ImageTexture.create_from_image(image)


## Where the map is drawn: as large as fits, to scale, centred
func _map_rect() -> Rect2:
	var area := map_display.size
	var world := map_bounds_max - map_bounds_min
	if area.x <= 0.0 or area.y <= 0.0 or world.x <= 0.0 or world.y <= 0.0:
		return Rect2(Vector2.ZERO, area)
	var scale := minf(area.x / world.x, area.y / world.y)
	var drawn := world * scale
	return Rect2((area - drawn) * 0.5, drawn)


func _world_to_screen(world_pos: Vector2) -> Vector2:
	var rect := _map_rect()
	var world := map_bounds_max - map_bounds_min
	if world.x == 0.0 or world.y == 0.0:
		return rect.position
	return rect.position + (world_pos - map_bounds_min) / world * rect.size


## The line in map coordinates, redone whenever the map is laid out afresh
## (the first time this screen opens its size is not known yet)
func _ensure_path_2d() -> void:
	var rect := _map_rect()
	if rect == _points_rect and path_points_2d.size() == path_points_3d.size():
		return
	_points_rect = rect
	path_points_2d.resize(path_points_3d.size())
	for i in range(path_points_3d.size()):
		var point := path_points_3d[i]
		path_points_2d[i] = _world_to_screen(Vector2(point.x, point.z))
	playhead_position = _get_position_at_time(playback_time)


func _populate_legend() -> void:
	for child in legend.get_children():
		child.queue_free()
	var used := {}
	for mode in path_modes:
		used[int(mode)] = true
	if used.is_empty():
		used[RouteMetrics.MODE_FOOT] = true
	for mode in MODE_NAMES.keys():
		if not used.has(mode):
			continue
		var entry := HBoxContainer.new()
		entry.add_theme_constant_override("separation", 6)
		var chip := ColorRect.new()
		chip.custom_minimum_size = Vector2(18, 4)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.color = MODE_COLORS[mode]
		entry.add_child(chip)
		var label := Label.new()
		label.text = MODE_NAMES[mode]
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.76))
		entry.add_child(label)
		legend.add_child(entry)


func _populate_moments_list() -> void:
	for child in moments_list.get_children():
		child.queue_free()

	if moments.is_empty():
		var nothing := Label.new()
		nothing.text = "Nothing on this run needed a note."
		nothing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nothing.add_theme_font_size_override("font_size", 13)
		nothing.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		moments_list.add_child(nothing)
		return

	for i in moments.size():
		moments_list.add_child(_create_moment_entry(i, moments[i]))


func _create_moment_entry(index: int, moment: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var chip := ColorRect.new()
	chip.custom_minimum_size = Vector2(4, 22)
	chip.color = _get_moment_color(moment)
	row.add_child(chip)

	# One button per moment: press it to put the playhead there
	var button := Button.new()
	button.flat = true
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.clip_text = true
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = "%s   %s" % [RunMoments.clock(run_context, moment["time"]), moment["text"]]
	button.tooltip_text = moment["text"]
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(_on_moment_clicked.bind(index))
	row.add_child(button)
	return row


func _get_moment_color(moment: Dictionary) -> Color:
	return MARKER_COLORS.get(int(moment.get("kind", RunMoments.Kind.DECISION)), MARKER_COLORS[RunMoments.Kind.DECISION])


# =============================================================================
# DRAWING
# =============================================================================

func _on_map_draw() -> void:
	var rect := _map_rect()
	if topo_texture != null:
		map_display.draw_texture_rect(topo_texture, rect, false)

	_ensure_path_2d()
	if path_points_2d.size() < 2:
		var font := get_theme_default_font()
		map_display.draw_string(font, rect.position + Vector2(16, 28), "No line was recorded on this run.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.75, 0.75, 0.8))
		return

	_draw_path()
	_draw_moment_markers()
	_draw_playhead()


## The line, each stretch in the colour of how it was travelled
func _draw_path() -> void:
	var count := path_points_2d.size()
	var shown := clampi(int(ceil(count * path_draw_progress)), 2, count)

	# A dark casing keeps the line readable over contours
	map_display.draw_polyline(path_points_2d.slice(0, shown), Color(0.05, 0.05, 0.07, 0.75), PATH_WIDTH + 2.5, true)

	var start := 0
	while start < shown - 1:
		var mode := _mode_at(start)
		var end := start + 1
		while end < shown - 1 and _mode_at(end) == mode:
			end += 1
		map_display.draw_polyline(path_points_2d.slice(start, end + 1), MODE_COLORS.get(mode, MODE_COLORS[RouteMetrics.MODE_FOOT]),
			PATH_WIDTH, true)
		start = end

	# Where the day began, and where it ended
	map_display.draw_arc(path_points_2d[0], 5.0, 0.0, TAU, 20, Color(1, 1, 1, 0.9), 2.0, true)
	if shown == count:
		map_display.draw_circle(path_points_2d[count - 1], 4.0, Color(1, 1, 1, 0.95))


## The travel mode of the stretch that starts at a path sample
func _mode_at(index: int) -> int:
	if index + 1 < path_modes.size():
		return int(path_modes[index + 1])
	return RouteMetrics.MODE_FOOT


func _draw_moment_markers() -> void:
	for i in moments.size():
		var moment := moments[i]
		# Only once the line has reached it
		if is_drawing_path and float(moment["time"]) / maxf(total_duration, 0.0001) > path_draw_progress:
			continue
		var position_3d: Vector3 = moment["position"]
		var screen_pos := _world_to_screen(Vector2(position_3d.x, position_3d.z))
		var radius := MARKER_RADIUS
		if i == selected_moment:
			radius *= 1.5
			map_display.draw_circle(screen_pos, radius + 3.0, Color(1, 1, 1, 0.5))
		map_display.draw_circle(screen_pos, radius, _get_moment_color(moment))
		map_display.draw_arc(screen_pos, radius, 0.0, TAU, 20, Color(1, 1, 1, 0.75), 1.5, true)


func _draw_playhead() -> void:
	if is_drawing_path or path_points_2d.is_empty():
		return
	map_display.draw_circle(playhead_position, PLAYHEAD_RADIUS, Color(1.0, 0.95, 0.9, 0.95))
	map_display.draw_arc(playhead_position, PLAYHEAD_RADIUS, 0.0, TAU, 24, Color(0.2, 0.2, 0.25), 2.0, true)


func _on_timeline_draw() -> void:
	var size := timeline_track.size
	var bar := Rect2(0.0, size.y * 0.5 - 8.0, size.x, 16.0)
	timeline_track.draw_rect(bar, Color(0.15, 0.15, 0.18))

	var progress := clampf(playback_time / maxf(total_duration, 0.0001), 0.0, 1.0)
	timeline_track.draw_rect(Rect2(bar.position, Vector2(bar.size.x * progress, bar.size.y)), Color(0.4, 0.5, 0.6, 0.85))

	for moment in moments:
		var x: float = size.x * clampf(float(moment["time"]) / maxf(total_duration, 0.0001), 0.0, 1.0)
		timeline_track.draw_line(Vector2(x, bar.position.y - 3.0), Vector2(x, bar.end.y + 3.0), _get_moment_color(moment), 2.0)

	var playhead_x := size.x * progress
	timeline_track.draw_rect(Rect2(playhead_x - 2.0, bar.position.y - 6.0, 4.0, bar.size.y + 12.0), Color(1, 1, 1, 0.9))


# =============================================================================
# PLAYBACK
# =============================================================================

func _refresh_playhead() -> void:
	playhead_position = _get_position_at_time(playback_time)
	time_label.text = "%s / %s      %s" % [
		RunMoments.elapsed(playback_time), RunMoments.elapsed(total_duration), RunMoments.clock(run_context, playback_time)]
	map_display.queue_redraw()
	timeline_track.queue_redraw()


## Where on the map the climber was a number of game hours into the run
func _get_position_at_time(time: float) -> Vector2:
	if path_points_2d.is_empty():
		return Vector2.ZERO
	var last := mini(path_timestamps.size(), path_points_2d.size()) - 1
	if last < 1 or time <= path_timestamps[0]:
		return path_points_2d[0]
	if time >= path_timestamps[last]:
		return path_points_2d[last]

	# The first sample at or after the time
	var low := 0
	var high := last
	while high - low > 1:
		var middle := (low + high) / 2
		if path_timestamps[middle] < time:
			low = middle
		else:
			high = middle
	var span := path_timestamps[high] - path_timestamps[low]
	var t := 0.0 if span <= 0.0 else clampf((time - path_timestamps[low]) / span, 0.0, 1.0)
	return path_points_2d[low].lerp(path_points_2d[high], t)


func _on_play_pressed() -> void:
	if is_drawing_path:
		# The first press finishes drawing the line
		path_draw_progress = 1.0
		is_drawing_path = false
		map_display.queue_redraw()
		return

	is_playing = not is_playing
	if is_playing and playback_time >= total_duration:
		playback_time = 0.0
	play_button.text = "Pause" if is_playing else "Play"
	_refresh_playhead()


func _on_speed_pressed() -> void:
	if playback_speed == 1.0:
		playback_speed = 2.0
	elif playback_speed == 2.0:
		playback_speed = 4.0
	else:
		playback_speed = 1.0
	speed_button.text = "%dx" % int(playback_speed)


func _seek(time: float) -> void:
	if is_drawing_path:
		path_draw_progress = 1.0
		is_drawing_path = false
	playback_time = clampf(time, 0.0, total_duration)
	_refresh_playhead()


func _on_timeline_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_scrubbing = event.pressed
		if event.pressed:
			_seek(event.position.x / maxf(timeline_track.size.x, 1.0) * total_duration)
	elif event is InputEventMouseMotion and _scrubbing:
		_seek(event.position.x / maxf(timeline_track.size.x, 1.0) * total_duration)


func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# A click on a marker selects its moment
		for i in moments.size():
			var position_3d: Vector3 = moments[i]["position"]
			var screen_pos := _world_to_screen(Vector2(position_3d.x, position_3d.z))
			if event.position.distance_to(screen_pos) < MARKER_RADIUS * 2.0:
				_on_moment_clicked(i)
				return


func _on_moment_clicked(index: int) -> void:
	if index < 0 or index >= moments.size():
		return
	selected_moment = index
	_seek(float(moments[index]["time"]))
	moment_selected.emit(moments[index])


func _on_close_pressed() -> void:
	close_requested.emit()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_on_play_pressed()
		get_viewport().set_input_as_handled()
