class_name ReplayScreen
extends Control
## The controls of a replay on the mountain: play and pause, speed, camera, a
## timeline to wind along, and the day's moments and highlights to jump to.
##
## ReplayPlayer is the clock and the rules; this screen only asks it for
## things and shows what it allows:
##   screen.open(player, run, highlights)
##   screen.close_requested        # Main puts the mountain away again
##   screen.map_replay_requested   # "the rest of the day is on the map"
##
## While a fatal run's fatal moments are shown there is nothing on the screen
## but the mountain (SPEC-SHEET 11: one continuous take, no text, no marker).

signal close_requested()
signal map_replay_requested()

const BAR_COLOR := Color(0.06, 0.07, 0.09, 0.82)
const TEXT_COLOR := Color(0.92, 0.91, 0.88)
const DIM_COLOR := Color(0.66, 0.67, 0.72)
const HIGHLIGHT_COLOR := Color(0.95, 0.82, 0.45)
const MARGIN := 24.0
const LIST_WIDTH := 400.0

var player: ReplayPlayer = null
var run: RunContext = null

var play_button: Button
var speed_button: Button
var camera_button: Button
var list_button: Button
var close_button: Button
var map_button: Button
var timeline: HSlider
var time_label: Label
var note_label: Label
var list_panel: PanelContainer
var list_box: VBoxContainer

var _bar: PanelContainer
var _top: HBoxContainer
var _marks: Control
## Moments and highlights as [seconds, label, is_highlight, end seconds]
var _entries: Array = []
var _setting_timeline: bool = false
## The replay was playing when the timeline was taken hold of
var _resume_after_drag: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build_ui()


# =============================================================================
# OPEN AND CLOSE
# =============================================================================

## Show the controls for a replay that ReplayPlayer has open
func open(replay_player: ReplayPlayer, of_run: RunContext, highlights: Array = []) -> void:
	_disconnect()
	player = replay_player
	run = of_run
	player.timestamp_changed.connect(_on_timestamp_changed)
	player.controls_changed.connect(_refresh_controls)
	player.playback_started.connect(_refresh_controls)
	player.playback_paused.connect(_refresh_controls)
	player.playback_completed.connect(_on_playback_completed)
	player.fatal_boundary_reached.connect(_on_fatal_boundary)

	_setting_timeline = true
	timeline.min_value = player.get_start()
	timeline.max_value = maxf(player.get_end(), player.get_start() + 0.1)
	timeline.step = 0.05
	timeline.value = player.current_timestamp
	_setting_timeline = false
	_collect_entries(highlights)
	_fill_list()
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	var mountain: MountainDatabase.MountainData = mountain_db.get_mountain(run.mountain_id) if mountain_db != null and run != null else null
	(_top.get_node("Title") as Label).text = "Replay  ·  %s" % mountain.name if mountain != null else "Replay"
	note_label.text = ""
	map_button.visible = false
	list_panel.visible = false
	visible = true
	_refresh_controls()
	_on_timestamp_changed(player.current_timestamp)
	UIFocus.take(play_button)


func close() -> void:
	_disconnect()
	visible = false
	player = null
	run = null


func _disconnect() -> void:
	if player == null:
		return
	for pair in [
		[player.timestamp_changed, _on_timestamp_changed], [player.controls_changed, _refresh_controls],
		[player.playback_started, _refresh_controls], [player.playback_paused, _refresh_controls],
		[player.playback_completed, _on_playback_completed], [player.fatal_boundary_reached, _on_fatal_boundary],
	]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])


func _input(event: InputEvent) -> void:
	if not visible or player == null:
		return
	if event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()


# =============================================================================
# BUILDING
# =============================================================================

func _build_ui() -> void:
	# Top: what this is, and the way out
	_top = HBoxContainer.new()
	_top.name = "Top"
	_top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top.offset_left = MARGIN
	_top.offset_right = -MARGIN
	_top.offset_top = MARGIN
	_top.add_theme_constant_override("separation", 12)
	add_child(_top)
	var title := Label.new()
	title.name = "Title"
	title.text = "Replay"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", TEXT_COLOR)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	title.add_theme_constant_override("outline_size", 4)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top.add_child(title)
	list_button = _button("ListButton", "Moments", "The day's moments and highlights, to jump to")
	list_button.toggle_mode = true
	list_button.toggled.connect(func(on: bool) -> void: list_panel.visible = on)
	_top.add_child(list_button)
	close_button = _button("CloseButton", "Close", "Back to the day's summary")
	close_button.pressed.connect(func() -> void: close_requested.emit())
	_top.add_child(close_button)

	# Right: the moments and highlights
	list_panel = PanelContainer.new()
	list_panel.name = "ListPanel"
	list_panel.add_theme_stylebox_override("panel", _panel_style())
	list_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	list_panel.offset_left = -(LIST_WIDTH + MARGIN)
	list_panel.offset_right = -MARGIN
	list_panel.offset_top = MARGIN + 56.0
	list_panel.offset_bottom = -(MARGIN + 110.0)
	list_panel.visible = false
	add_child(list_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	list_panel.add_child(scroll)
	list_box = VBoxContainer.new()
	list_box.name = "List"
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.add_theme_constant_override("separation", 4)
	scroll.add_child(list_box)

	# Bottom: the controls and the timeline
	_bar = PanelContainer.new()
	_bar.name = "Bar"
	_bar.add_theme_stylebox_override("panel", _panel_style())
	_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_bar.offset_left = MARGIN
	_bar.offset_right = -MARGIN
	_bar.offset_bottom = -MARGIN
	_bar.offset_top = -(MARGIN + 96.0)
	_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_bar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	_bar.add_child(column)

	_marks = Control.new()
	_marks.name = "Marks"
	_marks.custom_minimum_size = Vector2(0, 10)
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.draw.connect(_draw_marks)
	column.add_child(_marks)

	timeline = HSlider.new()
	timeline.name = "Timeline"
	timeline.custom_minimum_size = Vector2(0, 20)
	timeline.value_changed.connect(_on_timeline_moved)
	timeline.drag_started.connect(_on_timeline_held)
	timeline.drag_ended.connect(_on_timeline_let_go)
	column.add_child(timeline)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	column.add_child(row)
	play_button = _button("PlayButton", "Pause", "Play or pause")
	play_button.custom_minimum_size.x = 110
	play_button.pressed.connect(func() -> void:
		if player != null:
			player.toggle())
	row.add_child(play_button)
	speed_button = _button("SpeedButton", "Speed 1x", "Faster, then slower again")
	speed_button.custom_minimum_size.x = 130
	speed_button.pressed.connect(func() -> void:
		if player != null:
			player.cycle_speed())
	row.add_child(speed_button)
	camera_button = _button("CameraButton", "Camera", "The next camera")
	camera_button.custom_minimum_size.x = 260
	camera_button.pressed.connect(func() -> void:
		if player != null:
			player.cycle_camera())
	row.add_child(camera_button)
	note_label = Label.new()
	note_label.name = "Note"
	note_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note_label.add_theme_color_override("font_color", DIM_COLOR)
	row.add_child(note_label)
	map_button = _button("MapButton", "Replay on the map", "The whole day's path, on the map")
	map_button.visible = false
	map_button.pressed.connect(func() -> void: map_replay_requested.emit())
	row.add_child(map_button)
	time_label = Label.new()
	time_label.name = "Time"
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	time_label.custom_minimum_size.x = 250
	time_label.add_theme_color_override("font_color", TEXT_COLOR)
	row.add_child(time_label)


func _button(node_name: String, text: String, tooltip: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(0, 36)
	return button


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = BAR_COLOR
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	return style


# =============================================================================
# MOMENTS AND HIGHLIGHTS
# =============================================================================

## The day's key moments (RunMoments) and the highlights, on the run's clock.
## A fatal run lists only what came before control was lost.
func _collect_entries(highlights: Array) -> void:
	_entries.clear()
	var last := player.get_seek_end()
	for moment in RunMoments.collect(run):
		var seconds := float(moment["time"]) * 3600.0 / GameEnums.TIME_SCALE
		if seconds < player.get_start() or seconds > last:
			continue
		if int(moment["kind"]) == RunMoments.Kind.FATAL:
			continue
		_entries.append([seconds, "%s  %s" % [SpeedrunTimer.format_clock(seconds), moment["text"]], false, seconds])
	for item in highlights:
		var highlight := item as HighlightGenerator.Highlight
		if highlight == null or highlight.start_time > last:
			continue
		_entries.append([highlight.start_time, "%s  %s" % [SpeedrunTimer.format_clock(highlight.start_time), highlight.title], true,
			minf(highlight.end_time, last)])
	_entries.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_marks.queue_redraw()


func _fill_list() -> void:
	for child in list_box.get_children():
		list_box.remove_child(child)
		child.queue_free()
	var highlights := 0
	for entry in _entries:
		if entry[2]:
			highlights += 1
	var moments := _entries.size() - highlights
	var heading := Label.new()
	heading.text = "%d moment%s, %d highlight%s" % [moments, "" if moments == 1 else "s", highlights, "" if highlights == 1 else "s"] \
		if not _entries.is_empty() else "A quiet day: nothing to jump to."
	heading.add_theme_color_override("font_color", DIM_COLOR)
	list_box.add_child(heading)
	# As tall as what is in it, up to the room there is
	var room := get_viewport_rect().size.y - (MARGIN + 56.0) - (MARGIN + 110.0)
	list_panel.offset_bottom = list_panel.offset_top - get_viewport_rect().size.y + minf(64.0 + _entries.size() * 34.0, room)
	for entry in _entries:
		var button := Button.new()
		button.text = entry[1]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		button.custom_minimum_size = Vector2(LIST_WIDTH - 40.0, 30)
		if entry[2]:
			button.add_theme_color_override("font_color", HIGHLIGHT_COLOR)
			button.tooltip_text = "Play this highlight"
			button.pressed.connect(_play_highlight.bind(float(entry[0]), float(entry[3])))
		else:
			button.tooltip_text = "Go to this moment"
			button.pressed.connect(_go_to.bind(float(entry[0])))
		list_box.add_child(button)


## A moment: start a little before it, and play
func _go_to(seconds: float) -> void:
	if player == null or not player.can_seek():
		return
	player.seek(seconds - 3.0)
	player.play()


func _play_highlight(from: float, to: float) -> void:
	if player != null and player.can_seek():
		player.play_range(from, to)


## Ticks over the timeline: moments, and the stretch of each highlight
func _draw_marks() -> void:
	if player == null or player.get_duration() <= 0.0:
		return
	var width := _marks.size.x
	var start := player.get_start()
	var span := player.get_duration()
	for entry in _entries:
		var x := (float(entry[0]) - start) / span * width
		if entry[2]:
			var x_end := (float(entry[3]) - start) / span * width
			_marks.draw_rect(Rect2(x, 3.0, maxf(x_end - x, 2.0), 4.0), Color(HIGHLIGHT_COLOR, 0.8))
		else:
			_marks.draw_rect(Rect2(x - 1.0, 0.0, 2.0, 10.0), Color(TEXT_COLOR, 0.7))


# =============================================================================
# FOLLOWING THE PLAYER
# =============================================================================

func _on_timestamp_changed(timestamp: float) -> void:
	if player == null:
		return
	_setting_timeline = true
	timeline.value = timestamp
	_setting_timeline = false
	var played := timestamp - player.get_start()
	var text := "%s / %s" % [SpeedrunTimer.format_clock(played), SpeedrunTimer.format_clock(player.get_duration())]
	if run != null:
		text += "   %s" % RunMoments.clock(run, timestamp * GameEnums.TIME_SCALE / 3600.0)
	time_label.text = text


## The timeline was moved by hand: wind the replay there (the player decides
## how far it may go)
func _on_timeline_moved(value: float) -> void:
	if _setting_timeline or player == null:
		return
	player.seek(value)
	# Where the rules stopped it, if short of where it was dragged
	_on_timestamp_changed(player.current_timestamp)


## While the timeline is held the replay stands still (it would pull the
## handle out of the hand), and goes on from where it is let go
func _on_timeline_held() -> void:
	if player == null:
		return
	_resume_after_drag = player.is_playing()
	player.pause()


func _on_timeline_let_go(_moved: bool) -> void:
	var resume := _resume_after_drag
	_resume_after_drag = false
	# (not from the very end: Play there means "from the start again")
	if player != null and resume and not player.is_playing() and player.current_timestamp < player.get_visible_end() - 0.05:
		player.play()


## What the controls say and which of them there are, from what the player allows
func _refresh_controls() -> void:
	if player == null:
		return
	# The fatal moments: one continuous take, and nothing on the screen
	var alone := player.in_fatal_section
	_bar.visible = not alone
	_top.visible = not alone
	if alone:
		list_panel.visible = false
		list_button.set_pressed_no_signal(false)
	play_button.text = "Pause" if player.is_playing() else "Play"
	play_button.disabled = not player.can_pause()
	speed_button.visible = player.can_change_speed()
	speed_button.text = "Speed %sx" % _speed_text(player.playback_speed)
	camera_button.visible = player.can_change_camera()
	if player.stage != null:
		camera_button.text = ReplayStage.CAMERA_NAMES.get(player.stage.mode, "Camera")
	timeline.editable = player.can_seek()


func _speed_text(speed: float) -> String:
	return "%d" % int(speed) if is_equal_approx(speed, roundf(speed)) else "%.1f" % speed


func _on_playback_completed() -> void:
	_refresh_controls()
	if player != null and player.is_fatal_run:
		_show_map_offer()


func _on_fatal_boundary() -> void:
	_refresh_controls()
	_show_map_offer()


## Where a fatal run's replay ends: the rest of the day is its path
func _show_map_offer() -> void:
	note_label.text = "The rest of the day is on the map."
	map_button.visible = true
	UIFocus.take(map_button)
