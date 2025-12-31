class_name DEMLoader
extends RefCounted
## Loads terrain data from various DEM (Digital Elevation Model) formats
## Supports PNG heightmaps, raw binary files, and mountain manifest files

# =============================================================================
# CONSTANTS
# =============================================================================

## Default no-data value in DEM files
const NODATA_VALUE := -9999.0

## Supported file extensions
const SUPPORTED_HEIGHTMAP_EXTENSIONS := [".png", ".r16", ".raw", ".bin"]

# =============================================================================
# CONFIGURATION
# =============================================================================

## Base path for mountain data
var mountains_data_path: String = "res://data/mountains/"

## Height scale factor (converts raw values to world units)
var height_scale: float = 1.0

## Height offset (added to all values)
var height_offset: float = 0.0

## Whether to flip the Y axis (some DEM formats are flipped)
var flip_y: bool = false

# =============================================================================
# MOUNTAIN MANIFEST
# =============================================================================

## Load mountain manifest from JSON
func load_mountain_manifest(mountain_id: String) -> Dictionary:
	var manifest_path := mountains_data_path + mountain_id + "/manifest.json"

	if not FileAccess.file_exists(manifest_path):
		push_warning("[DEMLoader] No manifest found at: %s" % manifest_path)
		return {}

	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		push_error("[DEMLoader] Failed to open manifest: %s" % manifest_path)
		return {}

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var error := json.parse(json_text)
	if error != OK:
		push_error("[DEMLoader] Failed to parse manifest JSON: %s" % json.get_error_message())
		return {}

	return json.data


## Check if mountain data exists
func mountain_exists(mountain_id: String) -> bool:
	var manifest_path := mountains_data_path + mountain_id + "/manifest.json"
	return FileAccess.file_exists(manifest_path)


# =============================================================================
# HEIGHTMAP LOADING
# =============================================================================

## Load heightmap data for a mountain chunk
## Returns PackedFloat32Array of elevation values, or empty if failed
func load_heightmap(mountain_id: String, chunk_coords: Vector2i = Vector2i.ZERO) -> Dictionary:
	var manifest := load_mountain_manifest(mountain_id)
	if manifest.is_empty():
		return {"error": "No manifest found"}

	# Get heightmap configuration from manifest
	var heightmap_config: Dictionary = manifest.get("heightmap", {})
	var format: String = heightmap_config.get("format", "png")
	var resolution: int = heightmap_config.get("resolution", 512)
	height_scale = heightmap_config.get("height_scale", 1.0)
	height_offset = heightmap_config.get("height_offset", 0.0)
	flip_y = heightmap_config.get("flip_y", false)

	# Determine file path
	var file_path: String
	var chunks_config: Dictionary = manifest.get("chunks", {})

	if chunks_config.get("enabled", false):
		# Multi-chunk terrain
		var chunk_pattern: String = chunks_config.get("pattern", "chunk_{x}_{y}")
		var chunk_name := chunk_pattern.replace("{x}", str(chunk_coords.x)).replace("{y}", str(chunk_coords.y))
		file_path = mountains_data_path + mountain_id + "/chunks/" + chunk_name + "." + format
	else:
		# Single heightmap for entire terrain
		var filename: String = heightmap_config.get("filename", "heightmap")
		file_path = mountains_data_path + mountain_id + "/" + filename + "." + format

	# Load based on format
	var heightmap_data: PackedFloat32Array
	match format:
		"png":
			heightmap_data = _load_png_heightmap(file_path)
		"r16", "raw":
			heightmap_data = _load_raw16_heightmap(file_path, resolution)
		"r32", "bin":
			heightmap_data = _load_raw32_heightmap(file_path, resolution)
		_:
			push_error("[DEMLoader] Unsupported format: %s" % format)
			return {"error": "Unsupported format: %s" % format}

	if heightmap_data.is_empty():
		return {"error": "Failed to load heightmap"}

	# Apply scale and offset
	for i in range(heightmap_data.size()):
		heightmap_data[i] = heightmap_data[i] * height_scale + height_offset

	return {
		"data": heightmap_data,
		"resolution": _get_resolution_from_size(heightmap_data.size()),
		"manifest": manifest
	}


## Load heightmap from PNG (16-bit grayscale or 8-bit)
func _load_png_heightmap(file_path: String) -> PackedFloat32Array:
	if not FileAccess.file_exists(file_path):
		push_warning("[DEMLoader] PNG file not found: %s" % file_path)
		return PackedFloat32Array()

	var image := Image.new()
	var error := image.load(file_path)
	if error != OK:
		push_error("[DEMLoader] Failed to load PNG: %s (error: %d)" % [file_path, error])
		return PackedFloat32Array()

	var width := image.get_width()
	var height := image.get_height()
	var format := image.get_format()

	var result := PackedFloat32Array()
	result.resize(width * height)

	# Determine value range based on format
	var max_value: float = 255.0
	if format == Image.FORMAT_L8:
		max_value = 255.0
	elif format == Image.FORMAT_LA8:
		max_value = 255.0
	elif format == Image.FORMAT_R8:
		max_value = 255.0
	elif format == Image.FORMAT_RF:
		max_value = 1.0
	elif format == Image.FORMAT_RH:
		max_value = 1.0
	else:
		# Convert to a format we can read
		image.convert(Image.FORMAT_RF)
		max_value = 1.0

	for y in range(height):
		var row_y := (height - 1 - y) if flip_y else y
		for x in range(width):
			var pixel := image.get_pixel(x, row_y)
			# Use red channel (or luminance for grayscale)
			var value := pixel.r
			result[y * width + x] = value * max_value

	print("[DEMLoader] Loaded PNG: %dx%d, format: %d" % [width, height, format])
	return result


## Load raw 16-bit heightmap (unsigned short, little-endian)
func _load_raw16_heightmap(file_path: String, expected_resolution: int) -> PackedFloat32Array:
	if not FileAccess.file_exists(file_path):
		push_warning("[DEMLoader] RAW file not found: %s" % file_path)
		return PackedFloat32Array()

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("[DEMLoader] Failed to open RAW file: %s" % file_path)
		return PackedFloat32Array()

	var expected_size := expected_resolution * expected_resolution * 2  # 2 bytes per sample
	var file_size := file.get_length()

	if file_size != expected_size:
		push_warning("[DEMLoader] File size mismatch. Expected %d, got %d" % [expected_size, file_size])
		# Try to infer resolution
		expected_resolution = int(sqrt(file_size / 2))

	var result := PackedFloat32Array()
	result.resize(expected_resolution * expected_resolution)

	for i in range(result.size()):
		var value := file.get_16()
		result[i] = float(value)

	file.close()

	print("[DEMLoader] Loaded R16: %dx%d" % [expected_resolution, expected_resolution])
	return result


## Load raw 32-bit float heightmap
func _load_raw32_heightmap(file_path: String, expected_resolution: int) -> PackedFloat32Array:
	if not FileAccess.file_exists(file_path):
		push_warning("[DEMLoader] RAW file not found: %s" % file_path)
		return PackedFloat32Array()

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("[DEMLoader] Failed to open RAW file: %s" % file_path)
		return PackedFloat32Array()

	var expected_size := expected_resolution * expected_resolution * 4  # 4 bytes per float
	var file_size := file.get_length()

	if file_size != expected_size:
		push_warning("[DEMLoader] File size mismatch. Expected %d, got %d" % [expected_size, file_size])
		expected_resolution = int(sqrt(file_size / 4))

	var result := PackedFloat32Array()
	result.resize(expected_resolution * expected_resolution)

	for i in range(result.size()):
		result[i] = file.get_float()

	file.close()

	print("[DEMLoader] Loaded R32: %dx%d" % [expected_resolution, expected_resolution])
	return result


func _get_resolution_from_size(data_size: int) -> int:
	return int(sqrt(data_size))


# =============================================================================
# TERRAIN METADATA
# =============================================================================

## Get terrain bounds from manifest
func get_terrain_bounds(mountain_id: String) -> Dictionary:
	var manifest := load_mountain_manifest(mountain_id)
	if manifest.is_empty():
		return {}

	var bounds: Dictionary = manifest.get("bounds", {})
	return {
		"min_x": bounds.get("min_x", 0.0),
		"max_x": bounds.get("max_x", 1000.0),
		"min_z": bounds.get("min_z", 0.0),
		"max_z": bounds.get("max_z", 1000.0),
		"min_elevation": bounds.get("min_elevation", 0.0),
		"max_elevation": bounds.get("max_elevation", 5000.0)
	}


## Get chunk configuration from manifest
func get_chunk_config(mountain_id: String) -> Dictionary:
	var manifest := load_mountain_manifest(mountain_id)
	if manifest.is_empty():
		return {}

	var chunks: Dictionary = manifest.get("chunks", {})
	return {
		"enabled": chunks.get("enabled", false),
		"count_x": chunks.get("count_x", 1),
		"count_z": chunks.get("count_z", 1),
		"chunk_size": chunks.get("chunk_size", 64.0),
		"chunk_resolution": chunks.get("chunk_resolution", 32)
	}


## Get list of available mountains
func get_available_mountains() -> Array[String]:
	var mountains: Array[String] = []

	var dir := DirAccess.open(mountains_data_path)
	if dir == null:
		return mountains

	dir.list_dir_begin()
	var dir_name := dir.get_next()

	while dir_name != "":
		if dir.current_is_dir() and not dir_name.begins_with("."):
			var manifest_path := mountains_data_path + dir_name + "/manifest.json"
			if FileAccess.file_exists(manifest_path):
				mountains.append(dir_name)
		dir_name = dir.get_next()

	dir.list_dir_end()

	return mountains


# =============================================================================
# SURFACE DATA
# =============================================================================

## Load surface type overlay if available
func load_surface_overlay(mountain_id: String) -> Dictionary:
	var manifest := load_mountain_manifest(mountain_id)
	if manifest.is_empty():
		return {}

	var surface_config: Dictionary = manifest.get("surfaces", {})
	if not surface_config.get("has_overlay", false):
		return {}

	var overlay_path := mountains_data_path + mountain_id + "/" + surface_config.get("filename", "surfaces.png")

	if not FileAccess.file_exists(overlay_path):
		return {}

	var image := Image.new()
	var error := image.load(overlay_path)
	if error != OK:
		return {}

	# Surface types are encoded as colors in the overlay
	var color_map: Dictionary = surface_config.get("color_map", {})

	return {
		"image": image,
		"color_map": color_map
	}


# =============================================================================
# HAZARD DATA
# =============================================================================

## Load hazard markers from manifest
func load_hazards(mountain_id: String) -> Array[Dictionary]:
	var manifest := load_mountain_manifest(mountain_id)
	if manifest.is_empty():
		return []

	var hazards_data: Array = manifest.get("hazards", [])
	var result: Array[Dictionary] = []

	for hazard in hazards_data:
		result.append({
			"type": hazard.get("type", "unknown"),
			"position": Vector3(
				hazard.get("x", 0.0),
				hazard.get("y", 0.0),
				hazard.get("z", 0.0)
			),
			"radius": hazard.get("radius", 10.0),
			"severity": hazard.get("severity", 0.5)
		})

	return result


## Load route waypoints if available
func load_routes(mountain_id: String) -> Array[Dictionary]:
	var manifest := load_mountain_manifest(mountain_id)
	if manifest.is_empty():
		return []

	var routes_data: Array = manifest.get("routes", [])
	var result: Array[Dictionary] = []

	for route in routes_data:
		var waypoints: PackedVector3Array = PackedVector3Array()
		for point in route.get("waypoints", []):
			waypoints.append(Vector3(
				point.get("x", 0.0),
				point.get("y", 0.0),
				point.get("z", 0.0)
			))

		result.append({
			"name": route.get("name", "Unknown Route"),
			"difficulty": route.get("difficulty", "moderate"),
			"waypoints": waypoints
		})

	return result
