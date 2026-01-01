class_name GearAudioManager
extends Node
## Manages gear interaction audio
## Handles rope, ice axe, crampons, and equipment sounds
##
## Design Philosophy:
## - Gear sounds are grounded and realistic
## - Metal on rock/ice is distinctive
## - Rope sounds indicate tension and safety

# =============================================================================
# CONFIGURATION
# =============================================================================

## Audio bus for gear sounds
const GEAR_BUS := "Effects"

## Base volumes
const VOLUME_QUIET := -16.0
const VOLUME_NORMAL := -10.0
const VOLUME_LOUD := -6.0

## Sound definitions
const GEAR_SOUNDS := {
	# Rope sounds
	"rope_deploy": {
		"volume": VOLUME_NORMAL,
		"duration": 0.8,
		"type": "rope",
	},
	"rope_tension": {
		"volume": VOLUME_QUIET,
		"duration": 0.4,
		"type": "rope",
	},
	"rope_slack": {
		"volume": VOLUME_QUIET,
		"duration": 0.3,
		"type": "rope",
	},
	"rope_catch": {
		"volume": VOLUME_LOUD,
		"duration": 0.2,
		"type": "rope",
	},

	# Ice axe sounds
	"axe_swing": {
		"volume": VOLUME_NORMAL,
		"duration": 0.3,
		"type": "metal",
	},
	"axe_ice_strike": {
		"volume": VOLUME_LOUD,
		"duration": 0.15,
		"type": "metal_ice",
	},
	"axe_rock_strike": {
		"volume": VOLUME_LOUD,
		"duration": 0.1,
		"type": "metal_rock",
	},
	"axe_self_arrest": {
		"volume": VOLUME_LOUD,
		"duration": 0.5,
		"type": "metal_ice",
	},

	# Crampon sounds
	"crampon_step_ice": {
		"volume": VOLUME_QUIET,
		"duration": 0.08,
		"type": "metal_ice",
	},
	"crampon_step_rock": {
		"volume": VOLUME_QUIET,
		"duration": 0.06,
		"type": "metal_rock",
	},
	"crampon_scrape": {
		"volume": VOLUME_NORMAL,
		"duration": 0.2,
		"type": "metal_rock",
	},

	# Carabiner sounds
	"carabiner_clip": {
		"volume": VOLUME_NORMAL,
		"duration": 0.1,
		"type": "metal",
	},
	"carabiner_unclip": {
		"volume": VOLUME_NORMAL,
		"duration": 0.08,
		"type": "metal",
	},

	# General gear
	"gear_rustle": {
		"volume": VOLUME_QUIET,
		"duration": 0.2,
		"type": "fabric",
	},
	"pack_adjust": {
		"volume": VOLUME_QUIET,
		"duration": 0.3,
		"type": "fabric",
	},
	"zipper": {
		"volume": VOLUME_QUIET,
		"duration": 0.25,
		"type": "metal",
	},
}

# =============================================================================
# STATE
# =============================================================================

## Audio streams by name
var audio_streams: Dictionary = {}

## Pool of 3D audio players
var player_pool_3d: Array[AudioStreamPlayer3D] = []

## Pool of 2D audio players
var player_pool_2d: Array[AudioStreamPlayer] = []

## Pool size
const POOL_SIZE := 6

## Current pool indices
var pool_index_3d: int = 0
var pool_index_2d: int = 0

## Is initialized
var is_initialized: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_create_player_pools()
	_generate_audio_streams()
	_connect_signals()
	is_initialized = true
	print("[GearAudioManager] Initialized with %d sounds" % audio_streams.size())


func _create_player_pools() -> void:
	# 3D players for positional audio
	for i in POOL_SIZE:
		var player := AudioStreamPlayer3D.new()
		player.bus = GEAR_BUS
		player.max_distance = 50.0
		player.unit_size = 5.0
		add_child(player)
		player_pool_3d.append(player)

	# 2D players for non-positional audio
	for i in POOL_SIZE / 2:
		var player := AudioStreamPlayer.new()
		player.bus = GEAR_BUS
		add_child(player)
		player_pool_2d.append(player)


func _generate_audio_streams() -> void:
	# Generate procedural placeholder sounds for each type
	for sound_name in GEAR_SOUNDS:
		var data: Dictionary = GEAR_SOUNDS[sound_name]
		var duration: float = data.get("duration", 0.2)
		var sound_type: String = data.get("type", "metal")

		audio_streams[sound_name] = _generate_sound(sound_type, duration)


func _connect_signals() -> void:
	# Connect to gear-related EventBus signals
	if EventBus.has_signal("rope_deployed"):
		EventBus.rope_deployed.connect(_on_rope_deployed)
	if EventBus.has_signal("rope_tension_changed"):
		EventBus.rope_tension_changed.connect(_on_rope_tension_changed)

	EventBus.slide_started.connect(_on_slide_started)

	if EventBus.has_signal("self_arrest_started"):
		EventBus.self_arrest_started.connect(_on_self_arrest)


# =============================================================================
# PLAYBACK
# =============================================================================

## Play a gear sound at a 3D position
func play_sound_3d(sound_name: String, position: Vector3) -> void:
	if not is_initialized:
		return

	if not audio_streams.has(sound_name):
		push_warning("[GearAudioManager] Unknown sound: %s" % sound_name)
		return

	var stream: AudioStream = audio_streams[sound_name]
	var sound_data: Dictionary = GEAR_SOUNDS.get(sound_name, {})

	var player := _get_next_player_3d()
	player.stream = stream
	player.volume_db = sound_data.get("volume", VOLUME_NORMAL)
	player.pitch_scale = randf_range(0.95, 1.05)
	player.global_position = position
	player.play()


## Play a gear sound (2D, no position)
func play_sound(sound_name: String) -> void:
	if not is_initialized:
		return

	if not audio_streams.has(sound_name):
		push_warning("[GearAudioManager] Unknown sound: %s" % sound_name)
		return

	var stream: AudioStream = audio_streams[sound_name]
	var sound_data: Dictionary = GEAR_SOUNDS.get(sound_name, {})

	var player := _get_next_player_2d()
	player.stream = stream
	player.volume_db = sound_data.get("volume", VOLUME_NORMAL)
	player.pitch_scale = randf_range(0.95, 1.05)
	player.play()


## Play rope deployment sound
func play_rope_deploy(position: Vector3) -> void:
	play_sound_3d("rope_deploy", position)


## Play rope catch sound (when rope stops fall)
func play_rope_catch(position: Vector3) -> void:
	play_sound_3d("rope_catch", position)


## Play ice axe strike
func play_axe_strike(position: Vector3, surface: GameEnums.SurfaceType) -> void:
	var sound := "axe_ice_strike" if surface == GameEnums.SurfaceType.ICE else "axe_rock_strike"
	play_sound_3d(sound, position)


## Play self-arrest sound
func play_self_arrest(position: Vector3) -> void:
	play_sound_3d("axe_self_arrest", position)


## Play crampon step
func play_crampon_step(position: Vector3, surface: GameEnums.SurfaceType) -> void:
	var sound := "crampon_step_ice" if surface == GameEnums.SurfaceType.ICE else "crampon_step_rock"
	play_sound_3d(sound, position)


## Play carabiner clip
func play_carabiner_clip(position: Vector3) -> void:
	play_sound_3d("carabiner_clip", position)


## Play gear rustle
func play_gear_rustle() -> void:
	play_sound("gear_rustle")


func _get_next_player_3d() -> AudioStreamPlayer3D:
	var player := player_pool_3d[pool_index_3d]
	pool_index_3d = (pool_index_3d + 1) % player_pool_3d.size()
	return player


func _get_next_player_2d() -> AudioStreamPlayer:
	var player := player_pool_2d[pool_index_2d]
	pool_index_2d = (pool_index_2d + 1) % player_pool_2d.size()
	return player


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_rope_deployed(position: Vector3) -> void:
	play_rope_deploy(position)


func _on_rope_tension_changed(tension: float, position: Vector3) -> void:
	if tension > 0.8:
		play_sound_3d("rope_tension", position)


func _on_slide_started(_entry_speed: float, _slope_angle: float) -> void:
	# Gear rustle when starting to slide
	play_gear_rustle()


func _on_self_arrest(position: Vector3) -> void:
	play_self_arrest(position)


# =============================================================================
# PROCEDURAL AUDIO GENERATION
# =============================================================================

func _generate_sound(sound_type: String, duration: float) -> AudioStreamWAV:
	match sound_type:
		"rope":
			return _generate_rope_sound(duration)
		"metal":
			return _generate_metal_sound(duration)
		"metal_ice":
			return _generate_metal_ice_sound(duration)
		"metal_rock":
			return _generate_metal_rock_sound(duration)
		"fabric":
			return _generate_fabric_sound(duration)
		_:
			return _generate_metal_sound(duration)


func _generate_rope_sound(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	var last_value := 0.0
	for i in samples:
		var t := float(i) / sample_rate
		var envelope := exp(-t * 4.0)

		# Rope is filtered noise with some tonal quality
		var noise := randf_range(-1.0, 1.0)
		var tone := sin(TAU * 120.0 * t) * 0.2
		last_value = last_value * 0.85 + (noise + tone) * 0.15
		var wave := last_value * envelope * 0.4

		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_metal_sound(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in samples:
		var t := float(i) / sample_rate
		var envelope := exp(-t * 20.0)

		# Metallic sound: high frequencies with quick decay
		var wave := sin(TAU * 2400.0 * t) * 0.5
		wave += sin(TAU * 3200.0 * t) * 0.3
		wave += sin(TAU * 4800.0 * t) * 0.2
		wave *= envelope * 0.3

		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_metal_ice_sound(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in samples:
		var t := float(i) / sample_rate
		var envelope := exp(-t * 15.0)

		# Metal on ice: crisp, high-pitched
		var wave := sin(TAU * 3500.0 * t) * 0.4
		wave += sin(TAU * 5200.0 * t) * 0.3
		wave += randf_range(-0.1, 0.1) * envelope  # Ice crackle
		wave *= envelope * 0.35

		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_metal_rock_sound(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i in samples:
		var t := float(i) / sample_rate
		var envelope := exp(-t * 25.0)

		# Metal on rock: harder, more percussive
		var wave := sin(TAU * 1800.0 * t) * 0.4
		wave += sin(TAU * 2800.0 * t) * 0.35
		wave += sin(TAU * 800.0 * t) * 0.25  # Lower thud
		wave *= envelope * 0.4

		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream


func _generate_fabric_sound(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)

	var last_value := 0.0
	for i in samples:
		var t := float(i) / sample_rate
		var envelope := sin(PI * t / duration)

		# Fabric is soft filtered noise
		var noise := randf_range(-1.0, 1.0)
		last_value = last_value * 0.92 + noise * 0.08
		var wave := last_value * envelope * 0.25

		var sample := int(wave * 32767)
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream
