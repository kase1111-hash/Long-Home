class_name ProceduralAudio
extends RefCounted
## Generates procedural placeholder audio for testing
## Creates simple waveforms that represent different sound types
##
## Usage:
##   var stream = ProceduralAudio.create_wind_stream()
##   audio_player.stream = stream

# =============================================================================
# CONSTANTS
# =============================================================================

const SAMPLE_RATE := 44100.0
const DEFAULT_DURATION := 2.0

# =============================================================================
# WIND SOUNDS
# =============================================================================

## Create a wind-like noise stream
static func create_wind_stream(duration: float = 4.0, intensity: float = 0.5) -> AudioStreamWAV:
	var samples := _generate_filtered_noise(duration, 200.0, 800.0, intensity * 0.3)
	return _create_wav_stream(samples)


## Create wind gust (rising and falling)
static func create_wind_gust_stream(duration: float = 2.0) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := sin(PI * t / duration)  # Rise and fall
		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope * 0.4

	return _create_wav_stream(_apply_lowpass(samples, 600.0))


## Create howling wind
static func create_wind_howl_stream(duration: float = 3.0) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		# Modulating frequency for howl effect
		var freq := 300.0 + sin(t * 2.0) * 100.0
		var wave := sin(2.0 * PI * freq * t) * 0.2
		var noise := randf_range(-0.1, 0.1)
		samples[i] = wave + noise

	return _create_wav_stream(samples)


# =============================================================================
# BREATHING SOUNDS
# =============================================================================

## Create calm breathing loop
static func create_breathing_calm_stream(duration: float = 4.0) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	var breath_cycle := 3.0  # seconds per breath

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var breath_phase := fmod(t, breath_cycle) / breath_cycle

		# Inhale (0-0.4), pause (0.4-0.5), exhale (0.5-0.9), pause (0.9-1.0)
		var envelope := 0.0
		if breath_phase < 0.4:
			envelope = sin(breath_phase / 0.4 * PI) * 0.15
		elif breath_phase > 0.5 and breath_phase < 0.9:
			envelope = sin((breath_phase - 0.5) / 0.4 * PI) * 0.2

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 400.0))


## Create exerted breathing
static func create_breathing_exerted_stream(duration: float = 3.0) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	var breath_cycle := 1.5  # Faster breathing

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var breath_phase := fmod(t, breath_cycle) / breath_cycle

		var envelope := 0.0
		if breath_phase < 0.35:
			envelope = sin(breath_phase / 0.35 * PI) * 0.25
		elif breath_phase > 0.45 and breath_phase < 0.85:
			envelope = sin((breath_phase - 0.45) / 0.4 * PI) * 0.3

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 500.0))


## Create heavy/gasping breathing
static func create_breathing_heavy_stream(duration: float = 2.5) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	var breath_cycle := 1.0  # Very fast

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var breath_phase := fmod(t, breath_cycle) / breath_cycle

		var envelope := 0.0
		if breath_phase < 0.3:
			envelope = sin(breath_phase / 0.3 * PI) * 0.4
		elif breath_phase > 0.4 and breath_phase < 0.8:
			envelope = sin((breath_phase - 0.4) / 0.4 * PI) * 0.45

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 600.0))


# =============================================================================
# FOOTSTEP SOUNDS
# =============================================================================

## Create snow crunch footstep
static func create_footstep_snow_stream() -> AudioStreamWAV:
	var duration := 0.3
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 15.0)  # Quick decay
		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope * 0.5

	return _create_wav_stream(_apply_lowpass(samples, 2000.0))


## Create ice step
static func create_footstep_ice_stream() -> AudioStreamWAV:
	var duration := 0.25
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 20.0)
		# Higher frequency for ice
		var freq := 2000.0 + randf_range(-500.0, 500.0)
		var wave := sin(2.0 * PI * freq * t)
		var noise := randf_range(-0.3, 0.3)
		samples[i] = (wave * 0.3 + noise) * envelope

	return _create_wav_stream(samples)


## Create rock step
static func create_footstep_rock_stream() -> AudioStreamWAV:
	var duration := 0.2
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 25.0)
		var noise := randf_range(-1.0, 1.0)
		# Add some mid-frequency content
		var mid := sin(2.0 * PI * 800.0 * t) * 0.2
		samples[i] = (noise * 0.4 + mid) * envelope

	return _create_wav_stream(_apply_lowpass(samples, 3000.0))


## Create scree step (loose rocks)
static func create_footstep_scree_stream() -> AudioStreamWAV:
	var duration := 0.5
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		# Multiple impacts
		var envelope := exp(-t * 8.0)
		if t > 0.1:
			envelope += exp(-(t - 0.1) * 15.0) * 0.5
		if t > 0.2:
			envelope += exp(-(t - 0.2) * 20.0) * 0.3

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope * 0.4

	return _create_wav_stream(_apply_lowpass(samples, 4000.0))


# =============================================================================
# GEAR SOUNDS
# =============================================================================

## Create crampon scrape
static func create_crampon_scrape_stream() -> AudioStreamWAV:
	var duration := 0.3
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 10.0)
		# High metallic scrape
		var freq := 3000.0 + sin(t * 50.0) * 500.0
		var wave := sin(2.0 * PI * freq * t) * 0.3
		var noise := randf_range(-0.2, 0.2)
		samples[i] = (wave + noise) * envelope

	return _create_wav_stream(samples)


## Create rope handling sound
static func create_rope_handling_stream() -> AudioStreamWAV:
	var duration := 0.8
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := sin(t / duration * PI) * 0.3
		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 800.0))


## Create gear rustle
static func create_gear_rustle_stream() -> AudioStreamWAV:
	var duration := 0.4
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 5.0) * 0.25
		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 1500.0))


# =============================================================================
# SLIDE SOUNDS
# =============================================================================

## Create snow sliding loop
static func create_slide_snow_stream(duration: float = 2.0) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var noise := randf_range(-1.0, 1.0)
		# Modulating intensity
		var mod := 0.3 + sin(t * 5.0) * 0.1
		samples[i] = noise * mod

	return _create_wav_stream(_apply_lowpass(samples, 1200.0))


## Create ice sliding loop
static func create_slide_ice_stream(duration: float = 2.0) -> AudioStreamWAV:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		# Higher pitched, more harsh
		var freq := 2500.0 + sin(t * 30.0) * 300.0
		var wave := sin(2.0 * PI * freq * t) * 0.2
		var noise := randf_range(-0.3, 0.3)
		samples[i] = wave + noise

	return _create_wav_stream(samples)


## Create tumble sound
static func create_tumble_stream() -> AudioStreamWAV:
	var duration := 1.5
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		# Multiple impacts with decay
		var envelope := 0.0
		for j in range(5):
			var impact_time := j * 0.25
			if t > impact_time:
				envelope += exp(-(t - impact_time) * 10.0) * (1.0 - j * 0.15)

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope * 0.4

	return _create_wav_stream(_apply_lowpass(samples, 2000.0))


# =============================================================================
# REACTION SOUNDS
# =============================================================================

## Create gasp sound
static func create_gasp_stream() -> AudioStreamWAV:
	var duration := 0.4
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		# Quick inhale
		var envelope := 0.0
		if t < 0.15:
			envelope = sin(t / 0.15 * PI / 2) * 0.5
		else:
			envelope = exp(-(t - 0.15) * 8.0) * 0.5

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 600.0))


## Create relief exhale
static func create_relief_exhale_stream() -> AudioStreamWAV:
	var duration := 1.0
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		# Slow exhale
		var envelope := 0.0
		if t < 0.8:
			envelope = sin(t / 0.8 * PI) * 0.3

		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 400.0))


# =============================================================================
# ENVIRONMENT SOUNDS
# =============================================================================

## Create ice crack sound
static func create_ice_crack_stream() -> AudioStreamWAV:
	var duration := 0.5
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 15.0)
		# Sharp crack with high frequency
		var freq := 4000.0 - t * 2000.0  # Descending pitch
		var wave := sin(2.0 * PI * freq * t) * 0.4
		var noise := randf_range(-0.2, 0.2)
		samples[i] = (wave + noise) * envelope

	return _create_wav_stream(samples)


## Create snow settle sound
static func create_snow_settle_stream() -> AudioStreamWAV:
	var duration := 2.0
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		var t := float(i) / SAMPLE_RATE
		var envelope := exp(-t * 2.0) * 0.2
		var noise := randf_range(-1.0, 1.0)
		samples[i] = noise * envelope

	return _create_wav_stream(_apply_lowpass(samples, 500.0))


# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

## Generate filtered noise
static func _generate_filtered_noise(duration: float, low_freq: float, high_freq: float, amplitude: float) -> PackedFloat32Array:
	var sample_count := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(sample_count)

	for i in range(sample_count):
		samples[i] = randf_range(-1.0, 1.0) * amplitude

	# Apply bandpass-like filtering (simple low-pass for now)
	return _apply_lowpass(samples, high_freq)


## Simple low-pass filter
static func _apply_lowpass(samples: PackedFloat32Array, cutoff: float) -> PackedFloat32Array:
	var filtered := PackedFloat32Array()
	filtered.resize(samples.size())

	var rc := 1.0 / (2.0 * PI * cutoff)
	var dt := 1.0 / SAMPLE_RATE
	var alpha := dt / (rc + dt)

	filtered[0] = samples[0]
	for i in range(1, samples.size()):
		filtered[i] = filtered[i - 1] + alpha * (samples[i] - filtered[i - 1])

	return filtered


## Create AudioStreamWAV from samples
static func _create_wav_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()

	# Convert float samples to 16-bit PCM
	var data := PackedByteArray()
	data.resize(samples.size() * 2)

	for i in range(samples.size()):
		var sample_16 := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		data[i * 2] = sample_16 & 0xFF
		data[i * 2 + 1] = (sample_16 >> 8) & 0xFF

	stream.data = data
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(SAMPLE_RATE)
	stream.stereo = false

	return stream
