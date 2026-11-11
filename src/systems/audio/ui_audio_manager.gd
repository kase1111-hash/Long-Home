class_name UIAudioManager
extends Node
## Manages UI sound effects
## Handles menu sounds, map interactions, and feedback audio
##
## Design Philosophy:
## - UI sounds are subtle and unobtrusive
## - Critical actions get confirmation sounds
## - Map/gear sounds are diegetic (in-world)
##
## Screens do not ask for their button sounds: every button that enters the
## scene tree is given them here, so a new screen has sound without any code.

# =============================================================================
# CONFIGURATION
# =============================================================================

## Audio bus for UI sounds
const UI_BUS := "UI"

## Volume levels
const VOLUME_DEFAULT := -8.0
const VOLUME_SUBTLE := -14.0
const VOLUME_FEEDBACK := -6.0

## Sound definitions: what the screens call a sound -> the library id, its
## volume and how much its pitch may wander
const UI_SOUNDS := {
	# Menu sounds
	"menu_hover": {"id": "ui_hover", "volume": VOLUME_SUBTLE, "pitch_range": Vector2(0.97, 1.03)},
	"menu_select": {"id": "ui_select", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(0.98, 1.02)},
	"menu_confirm": {"id": "ui_confirm", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(1.0, 1.0)},
	"menu_back": {"id": "ui_back", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(0.97, 1.0)},
	"menu_error": {"id": "ui_error", "volume": VOLUME_FEEDBACK, "pitch_range": Vector2(0.95, 1.0)},
	"menu_toggle": {"id": "ui_toggle", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(0.97, 1.03)},

	# Map sounds
	"map_open": {"id": "map_unfold", "volume": VOLUME_FEEDBACK, "pitch_range": Vector2(0.97, 1.03)},
	"map_close": {"id": "map_fold", "volume": VOLUME_FEEDBACK, "pitch_range": Vector2(0.96, 1.02)},
	"map_rustle": {"id": "map_rustle", "volume": VOLUME_SUBTLE, "pitch_range": Vector2(0.92, 1.08)},
	"page_turn": {"id": "page_turn", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(0.95, 1.05)},

	# Gear sounds
	"watch_check": {"id": "watch_check", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(1.0, 1.0)},
	"compass_open": {"id": "compass_open", "volume": VOLUME_DEFAULT, "pitch_range": Vector2(0.98, 1.02)},
}

## Words on a button that mean going back, and going ahead
const BACK_WORDS: Array[String] = ["back", "return", "cancel", "close", "abandon", "quit"]
const CONFIRM_WORDS: Array[String] = ["begin", "start", "continue", "confirm", "new descent", "resume", "retry", "select"]

## Seconds within which a second hover makes no sound (sweeping across a list)
const HOVER_GAP := 0.06

## Seconds after the map unfolds that the compass lid is flipped open
const COMPASS_DELAY := 0.45

## Pool size
const POOL_SIZE := 4

## Marks a button that already has its sounds
const WIRED_META := &"ui_sound_wired"

# =============================================================================
# STATE
# =============================================================================

## Pool of audio players for one-shots
var player_pool: Array[AudioStreamPlayer] = []

## Current pool index
var pool_index: int = 0

## Is initialized
var is_initialized: bool = false

var _library: SoundLibrary
var _last_hover_msec: int = 0
var _next_map_rustle: float = 4.0
var _map_open: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	# Menus are used while the game is paused
	process_mode = Node.PROCESS_MODE_ALWAYS
	_library = ServiceLocator.get_service("SoundLibrary") as SoundLibrary
	_create_player_pool()
	_connect_signals()
	is_initialized = true
	print("[UIAudioManager] Initialized with %d sounds" % UI_SOUNDS.size())


func _create_player_pool() -> void:
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = UI_BUS
		add_child(player)
		player_pool.append(player)


func _connect_signals() -> void:
	# Every button, wherever it is and whenever it appears
	get_tree().node_added.connect(_on_node_added)
	_wire_buttons_under(get_tree().root)

	EventBus.map_opened.connect(_on_map_opened)
	EventBus.map_closed.connect(_on_map_closed)


func _process(delta: float) -> void:
	# An open map is paper in the wind
	if not _map_open or get_tree().paused:
		return
	_next_map_rustle -= delta
	if _next_map_rustle <= 0.0:
		_next_map_rustle = AudioService.roll_range(2.5, 6.0)
		play_map_rustle()


# =============================================================================
# BUTTONS
# =============================================================================

func _wire_buttons_under(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_wire_buttons_under(child)


func _on_node_added(node: Node) -> void:
	# A node that leaves the tree and comes back is "added" again: wire it once
	if node.has_meta(WIRED_META):
		return
	# The tabs of the planning screen are pages of the guidebook
	if node is TabContainer:
		node.set_meta(WIRED_META, true)
		(node as TabContainer).tab_clicked.connect(_on_tab_clicked)
		return
	var button := node as BaseButton
	if button == null:
		return
	button.set_meta(WIRED_META, true)
	button.pressed.connect(_on_button_pressed.bind(button))
	button.mouse_entered.connect(_on_button_hovered.bind(button))


func _on_tab_clicked(_tab: int) -> void:
	play_sound("page_turn")


func _on_button_pressed(button: BaseButton) -> void:
	if not is_instance_valid(button):
		return
	play_sound(sound_for_button(button))


func _on_button_hovered(button: BaseButton) -> void:
	if not is_instance_valid(button) or button.disabled or not button.is_visible_in_tree():
		return
	var now := Time.get_ticks_msec()
	if now - _last_hover_msec < int(HOVER_GAP * 1000.0):
		return
	_last_hover_msec = now
	play_sound("menu_hover")


## Which sound a button makes when pressed, judged by what kind it is and
## what it says
func sound_for_button(button: BaseButton) -> String:
	if button.toggle_mode:
		return "menu_toggle"
	var label := ""
	if button is Button:
		label = (button as Button).text.to_lower()
	label += " " + str(button.name).to_lower()
	for word in BACK_WORDS:
		if label.contains(word):
			return "menu_back"
	for word in CONFIRM_WORDS:
		if label.contains(word):
			return "menu_confirm"
	return "menu_select"


# =============================================================================
# PLAYBACK
# =============================================================================

## Play a UI sound by name (a key of UI_SOUNDS, or a library id)
func play_sound(sound_name: String) -> void:
	if not is_initialized or _library == null:
		return

	var sound_data: Dictionary = UI_SOUNDS.get(sound_name, {})
	var id: String = sound_data.get("id", sound_name)
	var stream := _library.get_stream(id)
	if stream == null:
		return

	# Get player from pool
	var player := _get_next_player()

	# Configure player
	player.stream = stream
	player.volume_db = sound_data.get("volume", VOLUME_DEFAULT)

	# Apply pitch variation
	var pitch_range: Vector2 = sound_data.get("pitch_range", Vector2(1.0, 1.0))
	player.pitch_scale = AudioService.roll_range(pitch_range.x, pitch_range.y)

	player.play()


## Play menu navigation sound
func play_menu_select() -> void:
	play_sound("menu_select")


## Play menu confirmation sound
func play_menu_confirm() -> void:
	play_sound("menu_confirm")


## Play menu back/cancel sound
func play_menu_back() -> void:
	play_sound("menu_back")


## Play error/invalid action sound
func play_menu_error() -> void:
	play_sound("menu_error")


## Play map opening sound
func play_map_open() -> void:
	play_sound("map_open")
	# The compass comes out with the map, when there is one in the pack
	var run := GameStateManager.get_current_run()
	if run != null and run.gear_state != null and run.gear_state.has_item(GameEnums.GearType.COMPASS):
		get_tree().create_timer(COMPASS_DELAY).timeout.connect(func() -> void: play_sound("compass_open"))


## Play map closing sound
func play_map_close() -> void:
	play_sound("map_close")


## Play map rustle (while viewing)
func play_map_rustle() -> void:
	play_sound("map_rustle")


## Play watch check sound
func play_watch_check() -> void:
	play_sound("watch_check")


func _get_next_player() -> AudioStreamPlayer:
	var player := player_pool[pool_index]
	pool_index = (pool_index + 1) % POOL_SIZE
	return player


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

## The map makes its own unfold and fold sounds as it opens and closes
## (PhysicalMap asks AudioService); these only track that it is out
func _on_map_opened() -> void:
	_map_open = true
	_next_map_rustle = AudioService.roll_range(2.5, 5.0)


func _on_map_closed() -> void:
	_map_open = false
