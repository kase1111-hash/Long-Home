class_name AudioInitializer
extends Node
## Initializes the complete audio system with placeholder or real audio
## Add this node to your main scene to automatically set up audio

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Settings")
## Use procedural placeholder audio (for development)
@export var use_placeholder_audio: bool = true
## Audio config resource (for production with real audio files)
@export var audio_config: AudioConfig

# =============================================================================
# CHILDREN
# =============================================================================

var audio_service: AudioService
var ambient_manager: AmbientAudioManager
var player_audio: PlayerAudioManager
var ui_audio: UIAudioManager
var gear_audio: GearAudioManager
var placeholder_loader: PlaceholderAudioLoader


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	print("[AudioInitializer] Setting up audio system...")

	_create_audio_nodes()
	_setup_audio_buses()

	# Load audio after a frame to ensure all nodes are ready
	await get_tree().process_frame
	_load_audio()

	print("[AudioInitializer] Audio system ready")


func _create_audio_nodes() -> void:
	# Create AudioService
	audio_service = AudioService.new()
	audio_service.name = "AudioService"
	add_child(audio_service)

	# Create AmbientAudioManager
	ambient_manager = AmbientAudioManager.new()
	ambient_manager.name = "AmbientAudioManager"
	add_child(ambient_manager)

	# Create PlayerAudioManager
	player_audio = PlayerAudioManager.new()
	player_audio.name = "PlayerAudioManager"
	add_child(player_audio)

	# Create UIAudioManager
	ui_audio = UIAudioManager.new()
	ui_audio.name = "UIAudioManager"
	add_child(ui_audio)

	# Create GearAudioManager
	gear_audio = GearAudioManager.new()
	gear_audio.name = "GearAudioManager"
	add_child(gear_audio)

	# Create PlaceholderAudioLoader
	placeholder_loader = PlaceholderAudioLoader.new()
	placeholder_loader.name = "PlaceholderAudioLoader"
	add_child(placeholder_loader)

	# Link managers to audio service
	audio_service.ambient_manager = ambient_manager
	audio_service.player_audio = player_audio
	audio_service.ui_audio = ui_audio
	audio_service.gear_audio = gear_audio


func _setup_audio_buses() -> void:
	# Create audio buses if they don't exist
	# Note: In production, these should be defined in project settings
	_ensure_bus_exists("Ambient")
	_ensure_bus_exists("Player")
	_ensure_bus_exists("Effects")
	_ensure_bus_exists("UI")


func _ensure_bus_exists(bus_name: String) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		# Bus doesn't exist, create it
		var new_idx := AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(new_idx, bus_name)
		AudioServer.set_bus_send(new_idx, "Master")
		print("[AudioInitializer] Created audio bus: %s" % bus_name)


func _load_audio() -> void:
	if use_placeholder_audio:
		_load_placeholder_audio()
	elif audio_config:
		_load_config_audio()
	else:
		push_warning("[AudioInitializer] No audio source configured")


func _load_placeholder_audio() -> void:
	print("[AudioInitializer] Loading placeholder audio...")

	# Generate all placeholder audio
	placeholder_loader.load_all_audio()

	# Apply to managers
	placeholder_loader.apply_to_ambient_manager(ambient_manager)
	placeholder_loader.apply_to_player_audio(player_audio)

	# Notify that audio is ready
	EventBus.audio_ready.emit()


func _load_config_audio() -> void:
	print("[AudioInitializer] Loading audio from config...")

	# Apply config to ambient manager
	ambient_manager.wind_base_stream = audio_config.wind_base
	ambient_manager.wind_gust_stream = audio_config.wind_gust
	ambient_manager.wind_altitude_stream = audio_config.wind_altitude
	ambient_manager.wind_howl_stream = audio_config.wind_howl
	ambient_manager.ice_ambient_stream = audio_config.ice_crack
	ambient_manager.snow_settle_stream = audio_config.snow_settle
	ambient_manager.avalanche_distant_stream = audio_config.avalanche_distant

	# Apply config to player audio
	player_audio.breathing_calm_stream = audio_config.breathing_calm
	player_audio.breathing_exerted_stream = audio_config.breathing_exerted
	player_audio.breathing_heavy_stream = audio_config.breathing_heavy
	player_audio.breathing_critical_stream = audio_config.breathing_critical

	player_audio.footstep_snow_firm = audio_config.footstep_snow_firm
	player_audio.footstep_snow_soft = audio_config.footstep_snow_soft
	player_audio.footstep_ice = audio_config.footstep_ice
	player_audio.footstep_rock = audio_config.footstep_rock
	player_audio.footstep_scree = audio_config.footstep_scree

	player_audio.crampon_scrape_stream = audio_config.crampon_scrape
	player_audio.rope_handling_stream = audio_config.rope_handling
	player_audio.gear_rustle_stream = audio_config.gear_rustle

	player_audio.slide_snow_stream = audio_config.slide_snow
	player_audio.slide_ice_stream = audio_config.slide_ice
	player_audio.tumble_stream = audio_config.tumble

	player_audio.gasp_stream = audio_config.gasp
	player_audio.relief_exhale_stream = audio_config.relief_exhale

	EventBus.audio_ready.emit()


# =============================================================================
# PUBLIC API
# =============================================================================

## Get the audio service
func get_audio_service() -> AudioService:
	return audio_service


## Get the ambient manager
func get_ambient_manager() -> AmbientAudioManager:
	return ambient_manager


## Get the player audio manager
func get_player_audio() -> PlayerAudioManager:
	return player_audio


## Get the UI audio manager
func get_ui_audio() -> UIAudioManager:
	return ui_audio


## Get the gear audio manager
func get_gear_audio() -> GearAudioManager:
	return gear_audio


## Reload audio (useful for hot-reloading during development)
func reload_audio() -> void:
	print("[AudioInitializer] Reloading audio...")

	# Stop all current audio
	ambient_manager.stop_ambient()
	player_audio.disable()

	# Reload
	_load_audio()

	# Restart if game is active
	var game_state := GameStateManager.current_state
	if game_state == GameEnums.GameState.DESCENT:
		ambient_manager.start_ambient()
		player_audio.enable()
