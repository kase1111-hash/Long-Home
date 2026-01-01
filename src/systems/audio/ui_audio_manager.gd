class_name UIAudioManager
extends Node
## Manages UI sound effects
## Handles menu sounds, map interactions, and feedback audio
##
## Design Philosophy:
## - UI sounds are subtle and unobtrusive
## - Critical actions get confirmation sounds
## - Map/gear sounds are diegetic (in-world)

# =============================================================================
# CONFIGURATION
# =============================================================================

## Audio bus for UI sounds
const UI_BUS := "UI"

## Volume levels
const VOLUME_DEFAULT := -8.0
const VOLUME_SUBTLE := -14.0
const VOLUME_FEEDBACK := -6.0

## Sound definitions
const UI_SOUNDS := {
	# Menu sounds
	"menu_select": {
		"volume": VOLUME_SUBTLE,
		"pitch_range": Vector2(0.98, 1.02),
	},
	"menu_confirm": {
		"volume": VOLUME_DEFAULT,
		"pitch_range": Vector2(1.0, 1.0),
	},
	"menu_back": {
		"volume": VOLUME_SUBTLE,
		"pitch_range": Vector2(0.95, 1.0),
	},
	"menu_error": {
		"volume": VOLUME_FEEDBACK,
		"pitch_range": Vector2(0.9, 0.95),
	},

	# Map sounds
	"map_open": {
		"volume": VOLUME_DEFAULT,
		"pitch_range": Vector2(0.98, 1.02),
	},
	"map_close": {
		"volume": VOLUME_DEFAULT,
		"pitch_range": Vector2(0.95, 1.0),
	},
	"map_rustle": {
		"volume": VOLUME_SUBTLE,
		"pitch_range": Vector2(0.9, 1.1),
	},

	# Gear sounds
	"watch_check": {
		"volume": VOLUME_SUBTLE,
		"pitch_range": Vector2(1.0, 1.0),
	},
	"compass_open": {
		"volume": VOLUME_SUBTLE,
		"pitch_range": Vector2(0.98, 1.02),
	},

	# Feedback sounds
	"checkpoint": {
		"volume": VOLUME_FEEDBACK,
		"pitch_range": Vector2(1.0, 1.05),
	},
	"warning": {
		"volume": VOLUME_FEEDBACK,
		"pitch_range": Vector2(0.9, 0.95),
	},
}

# =============================================================================
# STATE
# =============================================================================

## Audio streams by name
var audio_streams: Dictionary = {}

## Pool of audio players for one-shots
var player_pool: Array[AudioStreamPlayer] = []

## Pool size
const POOL_SIZE := 4

## Current pool index
var pool_index: int = 0

## Is initialized
var is_initialized: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_create_player_pool()
	_load_audio_streams()
	_connect_signals()
	is_initialized = true
	print("[UIAudioManager] Initialized with %d sounds" % audio_streams.size())


func _create_player_pool() -> void:
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = UI_BUS
		add_child(player)
		player_pool.append(player)


func _load_audio_streams() -> void:
	# Get audio config if available
	var audio_service = ServiceLocator.get_service("AudioService")
	if audio_service and audio_service.has_method("get_audio_config"):
		var config = audio_service.get_audio_config()
		if config:
			_load_from_config(config)
			return

	# Fall back to procedural audio
	_generate_placeholder_streams()


func _load_from_config(config: Resource) -> void:
	# Load UI sounds from AudioConfig resource
	if config.get("ui_menu_select"):
		audio_streams["menu_select"] = config.ui_menu_select
	if config.get("ui_menu_confirm"):
		audio_streams["menu_confirm"] = config.ui_menu_confirm
	if config.get("ui_map_unfold"):
		audio_streams["map_open"] = config.ui_map_unfold
	if config.get("ui_map_fold"):
		audio_streams["map_close"] = config.ui_map_fold
	if config.get("ui_watch_check"):
		audio_streams["watch_check"] = config.ui_watch_check


func _generate_placeholder_streams() -> void:
	# Generate procedural placeholder sounds
	audio_streams["menu_select"] = _generate_click_sound(0.05, 800.0)
	audio_streams["menu_confirm"] = _generate_click_sound(0.08, 600.0)
	audio_streams["menu_back"] = _generate_click_sound(0.04, 500.0)
	audio_streams["menu_error"] = _generate_buzz_sound(0.1, 200.0)
	audio_streams["map_open"] = _generate_rustle_sound(0.3)
	audio_streams["map_close"] = _generate_rustle_sound(0.25)
	audio_streams["map_rustle"] = _generate_rustle_sound(0.15)
	audio_streams["watch_check"] = _generate_click_sound(0.03, 2000.0)
	audio_streams["compass_open"] = _generate_click_sound(0.05, 1200.0)
	audio_streams["checkpoint"] = _generate_tone_sound(0.2, 880.0)
	audio_streams["warning"] = _generate_tone_sound(0.15, 440.0)


func _connect_signals() -> void:
	# Connect to UI-related EventBus signals
	if EventBus.has_signal("ui_button_pressed"):
		EventBus.ui_button_pressed.connect(_on_ui_button_pressed)
	if EventBus.has_signal("map_opened"):
		EventBus.map_opened.connect(_on_map_opened)
	if EventBus.has_signal("map_closed"):
		EventBus.map_closed.connect(_on_map_closed)


# =============================================================================
# PLAYBACK
# =============================================================================

## Play a UI sound by name
func play_sound(sound_name: String) -> void:
	if not is_initialized:
		return

	if not audio_streams.has(sound_name):
		push_warning("[UIAudioManager] Unknown sound: %s" % sound_name)
		return

	var stream: AudioStream = audio_streams[sound_name]
	var sound_data: Dictionary = UI_SOUNDS.get(sound_name, {})

	# Get player from pool
	var player := _get_next_player()

	# Configure player
	player.stream = stream
	player.volume_db = sound_data.get("volume", VOLUME_DEFAULT)

	# Apply pitch variation
	var pitch_range: Vector2 = sound_data.get("pitch_range", Vector2(1.0, 1.0))
	player.pitch_scale = randf_range(pitch_range.x, pitch_range.y)

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

func _on_ui_button_pressed(button_type: String) -> void:
	match button_type:
		"select":
			play_menu_select()
		"confirm":
			play_menu_confirm()
		"back":
			play_menu_back()
		"error":
			play_menu_error()


func _on_map_opened() -> void:
	play_map_open()


func _on_map_closed() -> void:
	play_map_close()


# =============================================================================
# PROCEDURAL AUDIO GENERATION
# =============================================================================

func _generate_click_sound(duration: float, frequency: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in samples:
		var t := float(i) / sample_rate
		var envelope := exp(-t * 30.0)  # Quick decay
		var wave := sin(TAU * frequency * t) * envelope
		var sample := int(wave * 32767 * 0.5)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_buzz_sound(duration: float, frequency: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in samples:
		var t := float(i) / sample_rate
		var envelope := 1.0 - (t / duration)
		var wave := sin(TAU * frequency * t) + sin(TAU * frequency * 1.5 * t) * 0.5
		wave *= envelope * 0.3
		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_rustle_sound(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	var last_value := 0.0
	for i in samples:
		var t := float(i) / sample_rate
		var envelope := sin(PI * t / duration)  # Fade in/out
		var noise := randf_range(-1.0, 1.0)
		# Low-pass filter
		last_value = last_value * 0.7 + noise * 0.3
		var wave := last_value * envelope * 0.4
		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_tone_sound(duration: float, frequency: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in samples:
		var t := float(i) / sample_rate
		var envelope := sin(PI * t / duration)
		var wave := sin(TAU * frequency * t) * envelope * 0.3
		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream
