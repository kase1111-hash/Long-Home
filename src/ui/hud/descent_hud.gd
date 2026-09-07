class_name DescentHUD
extends Control
## Minimal in-run HUD for the descent
##
## Three restrained elements, no bars or icons:
##   - a translucent top-left read-out (elevation, descended %, distance to
##     base camp, movement state, clock, temperature)
##   - a bottom-centre line of control hints that fades out after a while
##     (H toggles it back)
##   - a slot above the hints for EventBus.diegetic_message text
##
## The HUD finds every data source itself and tolerates any of them being
## missing or registering late; main.gd only instantiates and frees it.
## Values refresh a few times per second, never every frame, and freeze
## with the tree while the game is paused.

# =============================================================================
# SIGNALS
# =============================================================================

## Emitted when the control hints are shown or hidden (key press or auto-hide)
signal hints_visibility_changed(is_visible: bool)

# =============================================================================
# CONSTANTS
# =============================================================================

## Seconds between value refreshes (~4 Hz)
const REFRESH_INTERVAL := 0.25

## Seconds the control hints stay up after the HUD appears
const HINTS_AUTO_HIDE_DELAY := 15.0
## Fade-out duration of the automatic hide
const HINTS_FADE_TIME := 1.0
## Fade duration when hints are toggled by hand
const HINTS_TOGGLE_FADE_TIME := 0.2

## Diegetic message fade timings
const MESSAGE_FADE_IN := 0.3
const MESSAGE_FADE_OUT := 0.6

const HINTS_TEXT := "WASD move  ·  Mouse look  ·  Space slide  ·  R rope  ·  Q/E lean  ·  M map  ·  C self-check  ·  Esc pause  ·  H hints"

## Layout (design resolution is 1920x1080, viewport stretch)
const SCREEN_MARGIN := 24.0
const PANEL_PADDING := 12.0
const HINTS_PADDING_X := 14.0
const HINTS_PADDING_Y := 8.0
const PANEL_CORNER_RADIUS := 6
const ROW_SEPARATION := 4
const COLUMN_SEPARATION := 18
const BOTTOM_STACK_SEPARATION := 14

## Palette
const PANEL_COLOR := Color(0.08, 0.09, 0.12, 0.75)
const HINTS_PANEL_COLOR := Color(0.08, 0.09, 0.12, 0.5)
const VALUE_COLOR := Color(0.9, 0.9, 0.92)
const CAPTION_COLOR := Color(0.62, 0.64, 0.7)
const MESSAGE_COLOR := Color(0.95, 0.94, 0.9)
const MESSAGE_OUTLINE_COLOR := Color(0.02, 0.02, 0.04, 0.6)
const MESSAGE_SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.5)

## Type
const VALUE_FONT_SIZE := 20
const HINTS_FONT_SIZE := 18
const MESSAGE_FONT_SIZE := 26
const MESSAGE_OUTLINE_SIZE := 3
## Horizontal shear applied to the default font for an italic feel
const MESSAGE_SLANT := 0.18

## Shown when a value has no source yet
const UNKNOWN := "—"

## Human-readable names for GameEnums.PlayerMovementState
const STATE_NAMES := {
	GameEnums.PlayerMovementState.STANDING: "Standing",
	GameEnums.PlayerMovementState.WALKING: "Walking",
	GameEnums.PlayerMovementState.DOWNCLIMBING: "Downclimbing",
	GameEnums.PlayerMovementState.TRAVERSING: "Traversing",
	GameEnums.PlayerMovementState.SLIDING: "Sliding",
	GameEnums.PlayerMovementState.ROPING: "On rope",
	GameEnums.PlayerMovementState.FALLING: "Falling",
	GameEnums.PlayerMovementState.ARRESTED: "Self-arrest",
	GameEnums.PlayerMovementState.RESTING: "Resting",
	GameEnums.PlayerMovementState.INCAPACITATED: "Incapacitated",
}

# =============================================================================
# NODES
# =============================================================================

var _run_panel: PanelContainer
var _rows: GridContainer
var _elevation_value: Label
var _descended_value: Label
var _base_camp_value: Label
var _moving_value: Label
var _time_value: Label
var _temp_caption: Label
var _temp_value: Label

var _bottom_stack: VBoxContainer
var _message_label: Label
var _hints_panel: PanelContainer
var _hints_label: Label

# =============================================================================
# DATA SOURCES (resolved lazily, may be null at any time)
# =============================================================================

var _player: PlayerController
var _terrain: TerrainService
var _time_service: TimeService
var _temperature_system: TemperatureSystem

## Last movement state heard on the EventBus (fallback when no player)
var _movement_state: GameEnums.PlayerMovementState = GameEnums.PlayerMovementState.STANDING

## Latest air temperature and whether any source has provided one
var _temperature: float = 0.0
var _has_temperature: bool = false

# =============================================================================
# STATE
# =============================================================================

var _refresh_accumulator: float = 0.0

var _hints_visible: bool = true
## Seconds until the hints auto-hide; negative once cancelled or spent
var _hints_auto_hide_remaining: float = HINTS_AUTO_HIDE_DELAY
var _hints_tween: Tween
var _message_tween: Tween

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build_run_panel()
	_build_bottom_stack()
	_connect_signals()

	_update_visibility(GameStateManager.current_state)
	_refresh()
	print("[DescentHUD] Ready")


func _process(delta: float) -> void:
	if _hints_auto_hide_remaining > 0.0:
		_hints_auto_hide_remaining -= delta
		if _hints_auto_hide_remaining <= 0.0:
			_fade_hints(false, HINTS_FADE_TIME)

	_refresh_accumulator += delta
	if _refresh_accumulator >= REFRESH_INTERVAL:
		_refresh_accumulator = 0.0
		if visible:
			_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode != KEY_H and key.physical_keycode != KEY_H:
		return
	toggle_hints()
	get_viewport().set_input_as_handled()

# =============================================================================
# PUBLIC METHODS
# =============================================================================

## Show a diegetic message above the hints; replaces any message in progress
func show_message(message: String, duration: float) -> void:
	if _message_tween != null and _message_tween.is_valid():
		_message_tween.kill()

	_message_tween = create_tween()
	if message.strip_edges().is_empty():
		_message_tween.tween_property(_message_label, "modulate:a", 0.0, MESSAGE_FADE_OUT)
		return

	_message_label.text = message
	_message_tween.tween_property(_message_label, "modulate:a", 1.0, MESSAGE_FADE_IN)
	_message_tween.tween_interval(maxf(duration, 0.0))
	_message_tween.tween_property(_message_label, "modulate:a", 0.0, MESSAGE_FADE_OUT)


## Show or hide the control hints; cancels the automatic hide
func set_hints_visible(is_visible: bool, animate: bool = true) -> void:
	_hints_auto_hide_remaining = -1.0
	_fade_hints(is_visible, HINTS_TOGGLE_FADE_TIME if animate else 0.0)


## Flip the control hints; cancels the automatic hide
func toggle_hints() -> void:
	set_hints_visible(not _hints_visible)


## Whether the control hints are currently shown (or fading in)
func are_hints_visible() -> bool:
	return _hints_visible


## Update every value now instead of waiting for the next refresh tick
func refresh() -> void:
	_refresh_accumulator = 0.0
	_refresh()

# =============================================================================
# LAYOUT
# =============================================================================

func _build_run_panel() -> void:
	_run_panel = PanelContainer.new()
	_run_panel.name = "RunPanel"
	_run_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_run_panel.add_theme_stylebox_override("panel", _make_panel_style(PANEL_COLOR, PANEL_PADDING, PANEL_PADDING))
	_run_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_run_panel.position = Vector2(SCREEN_MARGIN, SCREEN_MARGIN)
	add_child(_run_panel)

	_rows = GridContainer.new()
	_rows.name = "Rows"
	_rows.columns = 2
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows.add_theme_constant_override("h_separation", COLUMN_SEPARATION)
	_rows.add_theme_constant_override("v_separation", ROW_SEPARATION)
	_run_panel.add_child(_rows)

	_elevation_value = _add_row("Elevation")
	_descended_value = _add_row("Descended")
	_base_camp_value = _add_row("Base camp")
	_moving_value = _add_row("Moving")
	_time_value = _add_row("Time")

	# Temperature row stays hidden until a source provides a value
	_temp_caption = _make_label("TempCaption", "Temp", VALUE_FONT_SIZE, CAPTION_COLOR)
	_temp_value = _make_label("TempValue", UNKNOWN, VALUE_FONT_SIZE, VALUE_COLOR)
	_temp_caption.visible = false
	_temp_value.visible = false
	_rows.add_child(_temp_caption)
	_rows.add_child(_temp_value)


## Add a caption/value pair to the read-out grid and return the value label
func _add_row(caption: String) -> Label:
	var caption_label := _make_label(caption.replace(" ", "") + "Caption", caption, VALUE_FONT_SIZE, CAPTION_COLOR)
	var value_label := _make_label(caption.replace(" ", "") + "Value", UNKNOWN, VALUE_FONT_SIZE, VALUE_COLOR)
	_rows.add_child(caption_label)
	_rows.add_child(value_label)
	return value_label


func _build_bottom_stack() -> void:
	_bottom_stack = VBoxContainer.new()
	_bottom_stack.name = "BottomStack"
	_bottom_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bottom_stack.add_theme_constant_override("separation", BOTTOM_STACK_SEPARATION)
	# Anchored to the bottom centre; grows upward and outward as content changes
	_bottom_stack.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bottom_stack.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bottom_stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bottom_stack.offset_left = 0.0
	_bottom_stack.offset_right = 0.0
	_bottom_stack.offset_top = -SCREEN_MARGIN
	_bottom_stack.offset_bottom = -SCREEN_MARGIN
	add_child(_bottom_stack)

	_message_label = _make_label("Message", "", MESSAGE_FONT_SIZE, MESSAGE_COLOR)
	_message_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_message_label.add_theme_font_override("font", _make_slanted_font())
	_message_label.add_theme_color_override("font_outline_color", MESSAGE_OUTLINE_COLOR)
	_message_label.add_theme_constant_override("outline_size", MESSAGE_OUTLINE_SIZE)
	_message_label.add_theme_color_override("font_shadow_color", MESSAGE_SHADOW_COLOR)
	_message_label.add_theme_constant_override("shadow_offset_x", 1)
	_message_label.add_theme_constant_override("shadow_offset_y", 2)
	_bottom_stack.add_child(_message_label)

	_hints_panel = PanelContainer.new()
	_hints_panel.name = "HintsPanel"
	_hints_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hints_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_hints_panel.add_theme_stylebox_override("panel", _make_panel_style(HINTS_PANEL_COLOR, HINTS_PADDING_X, HINTS_PADDING_Y))
	_bottom_stack.add_child(_hints_panel)

	_hints_label = _make_label("Hints", HINTS_TEXT, HINTS_FONT_SIZE, VALUE_COLOR)
	_hints_panel.add_child(_hints_label)


func _make_label(label_name: String, text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _make_panel_style(color: Color, padding_x: float, padding_y: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(PANEL_CORNER_RADIUS)
	style.content_margin_left = padding_x
	style.content_margin_right = padding_x
	style.content_margin_top = padding_y
	style.content_margin_bottom = padding_y
	return style


## The default font sheared sideways: reads as italic without a second typeface
func _make_slanted_font() -> FontVariation:
	var font := FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	# Same shear the docs give for fake italics: Transform2D(1, slant, 0, 1, 0, 0)
	font.variation_transform = Transform2D(Vector2(1.0, MESSAGE_SLANT), Vector2(0.0, 1.0), Vector2.ZERO)
	return font

# =============================================================================
# SIGNALS
# =============================================================================

func _connect_signals() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.map_opened.connect(_on_map_opened)
	EventBus.map_closed.connect(_on_map_closed)
	EventBus.player_movement_changed.connect(_on_player_movement_changed)
	EventBus.diegetic_message.connect(show_message)
	EventBus.temperature_changed.connect(_on_temperature_changed)


func _on_game_state_changed(_old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	_update_visibility(new_state)


func _on_player_movement_changed(_old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	_movement_state = new_state
	# Movement changes are worth showing right away
	_refresh_accumulator = REFRESH_INTERVAL


func _on_temperature_changed(temperature: float, _feels_like: float) -> void:
	_temperature = temperature
	_has_temperature = true

# =============================================================================
# VISIBILITY
# =============================================================================

func _update_visibility(state: GameEnums.GameState) -> void:
	var should_show := _is_hud_state(state)
	if should_show and not visible:
		_refresh()
	visible = should_show
	# The map check overlay owns the screen; the readout would show through it
	if _run_panel != null and state != GameEnums.GameState.MAP_CHECK and state != GameEnums.GameState.DESCENT:
		return
	if _run_panel != null:
		_run_panel.visible = state != GameEnums.GameState.MAP_CHECK


func _is_hud_state(state: GameEnums.GameState) -> bool:
	return state == GameEnums.GameState.DESCENT \
		or state == GameEnums.GameState.PAUSED \
		or state == GameEnums.GameState.MAP_CHECK

# =============================================================================
# VALUES
# =============================================================================

func _refresh() -> void:
	_resolve_services()
	var run: RunContext = GameStateManager.current_run

	_elevation_value.text = _elevation_text(run)
	_descended_value.text = _descended_text(run)
	_base_camp_value.text = _base_camp_text()
	_moving_value.text = _moving_text()
	_time_value.text = _time_text(run)
	_update_temperature_row()


## Pick up services that registered late (or were replaced) since last tick
func _resolve_services() -> void:
	if not is_instance_valid(_player):
		_player = ServiceLocator.get_service("PlayerController") as PlayerController
	if not is_instance_valid(_terrain):
		_terrain = ServiceLocator.get_service("TerrainService") as TerrainService
	if not is_instance_valid(_time_service):
		_time_service = ServiceLocator.get_service("TimeService") as TimeService
	if not is_instance_valid(_temperature_system):
		_temperature_system = ServiceLocator.get_service("TemperatureSystem") as TemperatureSystem


func _player_ready() -> bool:
	return is_instance_valid(_player) and _player.is_inside_tree()


func _elevation_text(run: RunContext) -> String:
	if _player_ready():
		return _format_metres(_player.global_position.y)
	if run != null:
		return _format_metres(run.current_elevation)
	return UNKNOWN


func _descended_text(run: RunContext) -> String:
	if run == null:
		return UNKNOWN
	# start_elevation is only set once the player has spawned
	if run.start_elevation <= run.target_elevation:
		return UNKNOWN
	return "%d %%" % roundi(run.get_descent_progress() * 100.0)


func _base_camp_text() -> String:
	if not _player_ready() or not is_instance_valid(_terrain):
		return UNKNOWN
	var goal := _terrain.goal_position
	if not _terrain.has_terrain_at(goal):
		return UNKNOWN
	var here := _player.global_position
	var distance := Vector2(here.x, here.z).distance_to(Vector2(goal.x, goal.z))
	if distance <= _terrain.goal_radius:
		return "Here"
	return _format_metres(distance)


func _moving_text() -> String:
	var state := _movement_state
	if is_instance_valid(_player):
		state = _player.current_state
	var state_name: String = STATE_NAMES.get(state, UNKNOWN)
	return state_name


func _time_text(run: RunContext) -> String:
	var hours_value := -1.0
	if is_instance_valid(_time_service):
		hours_value = _time_service.current_time
	elif run != null:
		hours_value = run.current_time
	if hours_value < 0.0:
		return UNKNOWN
	return _format_clock(hours_value)


func _update_temperature_row() -> void:
	if is_instance_valid(_temperature_system):
		_temperature = _temperature_system.air_temperature
		_has_temperature = true

	_temp_caption.visible = _has_temperature
	_temp_value.visible = _has_temperature
	if _has_temperature:
		_temp_value.text = "%d °C" % roundi(_temperature)

# =============================================================================
# FORMATTING
# =============================================================================

## "3 412 m" - whole metres with a thin group separator
func _format_metres(value: float) -> String:
	var whole := absi(roundi(value))
	var digits := str(whole)
	var grouped := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		grouped = digits[i] + grouped
		count += 1
		if count % 3 == 0 and i > 0:
			grouped = " " + grouped
	if value < 0.0 and whole > 0:
		grouped = "-" + grouped
	return grouped + " m"


## "08:24" from a 0-24 hour value
func _format_clock(hours_value: float) -> String:
	var total_minutes := floori(fposmod(hours_value, 24.0) * 60.0)
	var hours := total_minutes / 60
	var minutes := total_minutes % 60
	return "%02d:%02d" % [hours, minutes]

# =============================================================================
# HINTS
# =============================================================================

func _fade_hints(is_visible: bool, duration: float) -> void:
	if _hints_tween != null and _hints_tween.is_valid():
		_hints_tween.kill()

	var target := 1.0 if is_visible else 0.0
	if duration <= 0.0:
		_hints_panel.modulate = Color(1.0, 1.0, 1.0, target)
	else:
		_hints_tween = create_tween()
		_hints_tween.tween_property(_hints_panel, "modulate:a", target, duration)

	if _hints_visible != is_visible:
		_hints_visible = is_visible
		hints_visibility_changed.emit(is_visible)
		print("[DescentHUD] Hints %s" % ("shown" if is_visible else "hidden"))


## The physical map is held in the same corner; the readout steps aside
func _on_map_opened() -> void:
	if _run_panel != null:
		_run_panel.visible = false


func _on_map_closed() -> void:
	if _run_panel != null:
		_run_panel.visible = true
