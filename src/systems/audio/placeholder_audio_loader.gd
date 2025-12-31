class_name PlaceholderAudioLoader
extends Node
## Loads or generates placeholder audio streams for testing
## Provides all audio assets needed by the audio system
##
## In production, this would load real audio files
## For development, it generates procedural placeholders

# =============================================================================
# SIGNALS
# =============================================================================

signal audio_loaded()
signal loading_progress(percent: float)

# =============================================================================
# AUDIO STREAMS
# =============================================================================

# Wind
var wind_base: AudioStream
var wind_gust: AudioStream
var wind_altitude: AudioStream
var wind_howl: AudioStream

# Breathing
var breathing_calm: AudioStream
var breathing_exerted: AudioStream
var breathing_heavy: AudioStream
var breathing_critical: AudioStream

# Footsteps
var footstep_snow_firm: AudioStream
var footstep_snow_soft: AudioStream
var footstep_ice: AudioStream
var footstep_rock: AudioStream
var footstep_scree: AudioStream

# Gear
var crampon_scrape: AudioStream
var rope_handling: AudioStream
var gear_rustle: AudioStream
var ice_axe: AudioStream

# Sliding
var slide_snow: AudioStream
var slide_ice: AudioStream
var tumble: AudioStream

# Reactions
var gasp: AudioStream
var relief_exhale: AudioStream
var pain_grunt: AudioStream

# Environment
var ice_crack: AudioStream
var snow_settle: AudioStream
var avalanche_distant: AudioStream

# =============================================================================
# STATE
# =============================================================================

var is_loaded: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("PlaceholderAudioLoader", self)


## Load all placeholder audio (call this at game start)
func load_all_audio() -> void:
	print("[PlaceholderAudioLoader] Generating placeholder audio...")

	var total_assets := 22
	var loaded := 0

	# Wind sounds
	wind_base = ProceduralAudio.create_wind_stream(4.0, 0.5)
	_set_loop(wind_base)
	loaded += 1
	loading_progress.emit(float(loaded) / total_assets)

	wind_gust = ProceduralAudio.create_wind_gust_stream(2.0)
	loaded += 1

	wind_altitude = ProceduralAudio.create_wind_stream(4.0, 0.3)
	_set_loop(wind_altitude)
	loaded += 1

	wind_howl = ProceduralAudio.create_wind_howl_stream(3.0)
	_set_loop(wind_howl)
	loaded += 1
	loading_progress.emit(float(loaded) / total_assets)

	# Breathing sounds
	breathing_calm = ProceduralAudio.create_breathing_calm_stream(4.0)
	_set_loop(breathing_calm)
	loaded += 1

	breathing_exerted = ProceduralAudio.create_breathing_exerted_stream(3.0)
	_set_loop(breathing_exerted)
	loaded += 1

	breathing_heavy = ProceduralAudio.create_breathing_heavy_stream(2.5)
	_set_loop(breathing_heavy)
	loaded += 1

	breathing_critical = ProceduralAudio.create_breathing_heavy_stream(2.0)
	_set_loop(breathing_critical)
	loaded += 1
	loading_progress.emit(float(loaded) / total_assets)

	# Footsteps
	footstep_snow_firm = ProceduralAudio.create_footstep_snow_stream()
	loaded += 1

	footstep_snow_soft = ProceduralAudio.create_footstep_snow_stream()
	loaded += 1

	footstep_ice = ProceduralAudio.create_footstep_ice_stream()
	loaded += 1

	footstep_rock = ProceduralAudio.create_footstep_rock_stream()
	loaded += 1

	footstep_scree = ProceduralAudio.create_footstep_scree_stream()
	loaded += 1
	loading_progress.emit(float(loaded) / total_assets)

	# Gear
	crampon_scrape = ProceduralAudio.create_crampon_scrape_stream()
	loaded += 1

	rope_handling = ProceduralAudio.create_rope_handling_stream()
	loaded += 1

	gear_rustle = ProceduralAudio.create_gear_rustle_stream()
	loaded += 1

	ice_axe = ProceduralAudio.create_crampon_scrape_stream()  # Similar sound
	loaded += 1
	loading_progress.emit(float(loaded) / total_assets)

	# Sliding
	slide_snow = ProceduralAudio.create_slide_snow_stream(2.0)
	_set_loop(slide_snow)
	loaded += 1

	slide_ice = ProceduralAudio.create_slide_ice_stream(2.0)
	_set_loop(slide_ice)
	loaded += 1

	tumble = ProceduralAudio.create_tumble_stream()
	loaded += 1
	loading_progress.emit(float(loaded) / total_assets)

	# Reactions
	gasp = ProceduralAudio.create_gasp_stream()
	loaded += 1

	relief_exhale = ProceduralAudio.create_relief_exhale_stream()
	loaded += 1

	pain_grunt = ProceduralAudio.create_gasp_stream()  # Similar for now
	loaded += 1

	# Environment
	ice_crack = ProceduralAudio.create_ice_crack_stream()
	loaded += 1

	snow_settle = ProceduralAudio.create_snow_settle_stream()
	loaded += 1

	avalanche_distant = ProceduralAudio.create_slide_snow_stream(4.0)
	loaded += 1

	is_loaded = true
	loading_progress.emit(1.0)
	audio_loaded.emit()

	print("[PlaceholderAudioLoader] Generated %d placeholder audio streams" % loaded)


## Set loop mode on AudioStreamWAV
func _set_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2  # 16-bit samples


# =============================================================================
# APPLY TO AUDIO MANAGERS
# =============================================================================

## Apply loaded audio to AmbientAudioManager
func apply_to_ambient_manager(manager: AmbientAudioManager) -> void:
	if not is_loaded:
		push_warning("[PlaceholderAudioLoader] Audio not loaded yet")
		return

	manager.wind_base_stream = wind_base
	manager.wind_gust_stream = wind_gust
	manager.wind_altitude_stream = wind_altitude
	manager.wind_howl_stream = wind_howl
	manager.ice_ambient_stream = ice_crack
	manager.snow_settle_stream = snow_settle
	manager.avalanche_distant_stream = avalanche_distant

	print("[PlaceholderAudioLoader] Applied audio to AmbientAudioManager")


## Apply loaded audio to PlayerAudioManager
func apply_to_player_audio(manager: PlayerAudioManager) -> void:
	if not is_loaded:
		push_warning("[PlaceholderAudioLoader] Audio not loaded yet")
		return

	# Breathing
	manager.breathing_calm_stream = breathing_calm
	manager.breathing_exerted_stream = breathing_exerted
	manager.breathing_heavy_stream = breathing_heavy
	manager.breathing_critical_stream = breathing_critical

	# Footsteps
	manager.footstep_snow_firm = footstep_snow_firm
	manager.footstep_snow_soft = footstep_snow_soft
	manager.footstep_ice = footstep_ice
	manager.footstep_rock = footstep_rock
	manager.footstep_scree = footstep_scree

	# Gear
	manager.crampon_scrape_stream = crampon_scrape
	manager.rope_handling_stream = rope_handling
	manager.gear_rustle_stream = gear_rustle
	manager.ice_axe_stream = ice_axe

	# Sliding
	manager.slide_snow_stream = slide_snow
	manager.slide_ice_stream = slide_ice
	manager.tumble_stream = tumble

	# Reactions
	manager.gasp_stream = gasp
	manager.relief_exhale_stream = relief_exhale
	manager.pain_grunt_stream = pain_grunt

	print("[PlaceholderAudioLoader] Applied audio to PlayerAudioManager")


## Create and return an AudioConfig resource with all placeholder audio
func create_audio_config() -> AudioConfig:
	if not is_loaded:
		load_all_audio()

	var config := AudioConfig.new()

	# Wind
	config.wind_base = wind_base
	config.wind_gust = wind_gust
	config.wind_altitude = wind_altitude
	config.wind_howl = wind_howl

	# Breathing
	config.breathing_calm = breathing_calm
	config.breathing_exerted = breathing_exerted
	config.breathing_heavy = breathing_heavy
	config.breathing_critical = breathing_critical

	# Footsteps
	config.footstep_snow_firm = footstep_snow_firm
	config.footstep_snow_soft = footstep_snow_soft
	config.footstep_ice = footstep_ice
	config.footstep_rock = footstep_rock
	config.footstep_scree = footstep_scree

	# Gear
	config.crampon_scrape = crampon_scrape
	config.rope_handling = rope_handling
	config.gear_rustle = gear_rustle

	# Sliding
	config.slide_snow = slide_snow
	config.slide_ice = slide_ice
	config.tumble = tumble

	# Reactions
	config.gasp = gasp
	config.relief_exhale = relief_exhale

	# Environment
	config.ice_crack = ice_crack
	config.snow_settle = snow_settle
	config.avalanche_distant = avalanche_distant

	return config


# =============================================================================
# QUERIES
# =============================================================================

func is_audio_loaded() -> bool:
	return is_loaded


func get_audio_stream(name: String) -> AudioStream:
	match name:
		# Wind
		"wind_base": return wind_base
		"wind_gust": return wind_gust
		"wind_altitude": return wind_altitude
		"wind_howl": return wind_howl
		# Breathing
		"breathing_calm": return breathing_calm
		"breathing_exerted": return breathing_exerted
		"breathing_heavy": return breathing_heavy
		"breathing_critical": return breathing_critical
		# Footsteps
		"footstep_snow_firm": return footstep_snow_firm
		"footstep_snow_soft": return footstep_snow_soft
		"footstep_ice": return footstep_ice
		"footstep_rock": return footstep_rock
		"footstep_scree": return footstep_scree
		# Gear
		"crampon_scrape": return crampon_scrape
		"rope_handling": return rope_handling
		"gear_rustle": return gear_rustle
		"ice_axe": return ice_axe
		# Sliding
		"slide_snow": return slide_snow
		"slide_ice": return slide_ice
		"tumble": return tumble
		# Reactions
		"gasp": return gasp
		"relief_exhale": return relief_exhale
		"pain_grunt": return pain_grunt
		# Environment
		"ice_crack": return ice_crack
		"snow_settle": return snow_settle
		"avalanche_distant": return avalanche_distant
		_:
			push_warning("[PlaceholderAudioLoader] Unknown audio: %s" % name)
			return null
