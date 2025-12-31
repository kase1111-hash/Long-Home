class_name TerrainGenerator
extends Node3D
## Generates visual terrain meshes and collision shapes from terrain data
## Handles LOD and chunk-based rendering

# =============================================================================
# SIGNALS
# =============================================================================

signal chunk_mesh_generated(chunk_coords: Vector2i)
signal all_meshes_generated()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Material for terrain rendering
@export var terrain_material: Material

## Generate collision shapes
@export var generate_collision: bool = true

## LOD distances
@export var lod_distances: Array[float] = [50.0, 100.0, 200.0]

## LOD resolution multipliers (1.0 = full res, 0.5 = half, etc.)
@export var lod_resolutions: Array[float] = [1.0, 0.5, 0.25]

# =============================================================================
# STATE
# =============================================================================

## Reference to terrain service
var terrain_service: TerrainService

## Generated mesh instances (chunk_coords -> MeshInstance3D)
var chunk_meshes: Dictionary = {}

## LOD meshes per chunk (chunk_coords -> Array[ArrayMesh])
var chunk_lod_meshes: Dictionary = {}

## Current LOD level per chunk (chunk_coords -> int)
var chunk_current_lod: Dictionary = {}

## Generated collision shapes (chunk_coords -> StaticBody3D)
var chunk_colliders: Dictionary = {}

## Parent node for terrain meshes
var mesh_parent: Node3D

## Parent node for collision shapes
var collider_parent: Node3D

## Camera reference for LOD updates
var camera: Camera3D = null

## LOD update interval (seconds)
var lod_update_interval: float = 0.25

## Time since last LOD update
var lod_update_timer: float = 0.0


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	mesh_parent = Node3D.new()
	mesh_parent.name = "TerrainMeshes"
	add_child(mesh_parent)

	collider_parent = Node3D.new()
	collider_parent.name = "TerrainColliders"
	add_child(collider_parent)

	# Get terrain service
	ServiceLocator.get_service_async("TerrainService", _on_terrain_service_ready)


func _on_terrain_service_ready(service: Object) -> void:
	terrain_service = service as TerrainService
	terrain_service.terrain_loaded.connect(_on_terrain_loaded)
	terrain_service.chunk_loaded.connect(_on_chunk_loaded)

	print("[TerrainGenerator] Connected to TerrainService")


func _process(delta: float) -> void:
	# Periodically update LOD based on camera position
	lod_update_timer += delta
	if lod_update_timer >= lod_update_interval:
		lod_update_timer = 0.0
		_update_lod_from_camera()


func _update_lod_from_camera() -> void:
	# Find camera if not set
	if camera == null:
		camera = get_viewport().get_camera_3d()
		if camera == null:
			return

	update_lod(camera.global_position)


# =============================================================================
# MESH GENERATION
# =============================================================================

func _on_terrain_loaded(_mountain_id: String) -> void:
	# Clear existing meshes
	_clear_all_meshes()


func _on_chunk_loaded(chunk_coords: Vector2i) -> void:
	var chunk: TerrainChunk = terrain_service.chunks.get(chunk_coords)
	if chunk:
		_generate_chunk_mesh(chunk)
		if generate_collision:
			_generate_chunk_collision(chunk)

		chunk_mesh_generated.emit(chunk_coords)


func _clear_all_meshes() -> void:
	for mesh in chunk_meshes.values():
		mesh.queue_free()
	chunk_meshes.clear()

	for collider in chunk_colliders.values():
		collider.queue_free()
	chunk_colliders.clear()

	# Clear LOD data
	chunk_lod_meshes.clear()
	chunk_current_lod.clear()


## Generate mesh for a terrain chunk (generates all LOD levels)
func _generate_chunk_mesh(chunk: TerrainChunk) -> void:
	# Generate meshes for all LOD levels
	var lod_meshes: Array[ArrayMesh] = []
	for resolution in lod_resolutions:
		var mesh := _create_terrain_mesh(chunk, resolution)
		lod_meshes.append(mesh)

	# Store LOD meshes for this chunk
	chunk_lod_meshes[chunk.chunk_coords] = lod_meshes

	# Create mesh instance with highest detail (LOD 0)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = lod_meshes[0] if not lod_meshes.is_empty() else null
	mesh_instance.name = "Chunk_%d_%d" % [chunk.chunk_coords.x, chunk.chunk_coords.y]

	if terrain_material:
		mesh_instance.material_override = terrain_material

	# Position at chunk origin
	mesh_instance.position = chunk.world_origin

	mesh_parent.add_child(mesh_instance)
	chunk_meshes[chunk.chunk_coords] = mesh_instance

	# Initialize current LOD level
	chunk_current_lod[chunk.chunk_coords] = 0


## Create terrain mesh from chunk data
func _create_terrain_mesh(chunk: TerrainChunk, resolution_scale: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var step := maxi(1, int(1.0 / resolution_scale))
	var grid_size := chunk.resolution / step

	# Calculate vertex and index counts
	var vertex_count := (grid_size + 1) * (grid_size + 1)
	var index_count := grid_size * grid_size * 6

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	uvs.resize(vertex_count)
	colors.resize(vertex_count)
	indices.resize(index_count)

	# Generate vertices
	var vertex_idx := 0
	for z in range(0, chunk.resolution + 1, step):
		for x in range(0, chunk.resolution + 1, step):
			var grid_x := mini(x, chunk.resolution - 1)
			var grid_z := mini(z, chunk.resolution - 1)

			var cell := chunk.get_cell(Vector2i(grid_x, grid_z))
			var height := chunk.get_height(Vector2i(grid_x, grid_z))

			# Local position within chunk
			var local_pos := Vector3(
				x * chunk.cell_size,
				height - chunk.world_origin.y,  # Relative to chunk origin
				z * chunk.cell_size
			)

			vertices[vertex_idx] = local_pos
			normals[vertex_idx] = cell.normal if cell else Vector3.UP

			# UV coordinates
			uvs[vertex_idx] = Vector2(
				float(x) / chunk.resolution,
				float(z) / chunk.resolution
			)

			# Vertex color based on surface/slope
			colors[vertex_idx] = _get_vertex_color(cell)

			vertex_idx += 1

	# Generate indices (triangles)
	var index_idx := 0
	for z in range(grid_size):
		for x in range(grid_size):
			var top_left := z * (grid_size + 1) + x
			var top_right := top_left + 1
			var bottom_left := (z + 1) * (grid_size + 1) + x
			var bottom_right := bottom_left + 1

			# First triangle
			indices[index_idx] = top_left
			indices[index_idx + 1] = bottom_left
			indices[index_idx + 2] = top_right

			# Second triangle
			indices[index_idx + 3] = top_right
			indices[index_idx + 4] = bottom_left
			indices[index_idx + 5] = bottom_right

			index_idx += 6

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Get vertex color based on terrain cell properties
func _get_vertex_color(cell: TerrainCell) -> Color:
	if cell == null:
		return Color(0.5, 0.5, 0.5, 1.0)

	# Base color by surface type
	var color := Color.WHITE

	match cell.surface_type:
		GameEnums.SurfaceType.SNOW_FIRM:
			color = Color(0.95, 0.95, 1.0)
		GameEnums.SurfaceType.SNOW_SOFT:
			color = Color(0.9, 0.92, 0.98)
		GameEnums.SurfaceType.SNOW_POWDER:
			color = Color(1.0, 1.0, 1.0)
		GameEnums.SurfaceType.ICE:
			color = Color(0.8, 0.9, 1.0)
		GameEnums.SurfaceType.ROCK:
			color = Color(0.45, 0.4, 0.35)
		GameEnums.SurfaceType.ROCK_DRY:
			color = Color(0.5, 0.45, 0.4)
		GameEnums.SurfaceType.ROCK_WET:
			color = Color(0.35, 0.32, 0.28)
		GameEnums.SurfaceType.SCREE:
			color = Color(0.55, 0.5, 0.45)
		GameEnums.SurfaceType.MIXED:
			color = Color(0.7, 0.7, 0.75)

	# Darken steep slopes
	var slope_factor := 1.0 - (cell.slope_angle / 90.0) * 0.4
	color = color * slope_factor

	# Slight blue tint in shaded areas
	if cell.sun_exposure < 0.3:
		color = color.lerp(Color(0.8, 0.85, 0.95), 0.2)

	return color


# =============================================================================
# COLLISION GENERATION
# =============================================================================

## Generate collision shape for a chunk
func _generate_chunk_collision(chunk: TerrainChunk) -> void:
	var static_body := StaticBody3D.new()
	static_body.name = "Collider_%d_%d" % [chunk.chunk_coords.x, chunk.chunk_coords.y]

	var collision_shape := CollisionShape3D.new()
	var heightmap_shape := HeightMapShape3D.new()

	# Create heightmap data for collision
	var map_width := chunk.resolution + 1
	var map_depth := chunk.resolution + 1

	heightmap_shape.map_width = map_width
	heightmap_shape.map_depth = map_depth

	# HeightMapShape3D expects data as PackedFloat32Array
	var height_data := PackedFloat32Array()
	height_data.resize(map_width * map_depth)

	for z in range(map_depth):
		for x in range(map_width):
			var grid_x := mini(x, chunk.resolution - 1)
			var grid_z := mini(z, chunk.resolution - 1)
			var height := chunk.get_height(Vector2i(grid_x, grid_z))
			height_data[z * map_width + x] = height

	heightmap_shape.map_data = height_data

	collision_shape.shape = heightmap_shape

	# Position collision shape
	# HeightMapShape3D is centered, so we need to offset
	var center_offset := Vector3(
		chunk.chunk_size * 0.5,
		(chunk.min_elevation + chunk.max_elevation) * 0.5,
		chunk.chunk_size * 0.5
	)

	collision_shape.position = center_offset
	collision_shape.scale = Vector3(
		chunk.cell_size,
		1.0,
		chunk.cell_size
	)

	static_body.add_child(collision_shape)
	static_body.position = chunk.world_origin

	# Set collision layer/mask
	static_body.collision_layer = 1  # Terrain layer
	static_body.collision_mask = 0   # Terrain doesn't need to detect anything

	collider_parent.add_child(static_body)
	chunk_colliders[chunk.chunk_coords] = static_body


# =============================================================================
# LOD MANAGEMENT
# =============================================================================

## Update LOD based on camera position
func update_lod(camera_pos: Vector3) -> void:
	for coords in chunk_meshes:
		var mesh_instance: MeshInstance3D = chunk_meshes[coords]
		var chunk: TerrainChunk = terrain_service.chunks.get(coords)

		if chunk == null:
			continue

		var chunk_center := chunk.world_origin + Vector3(
			chunk.chunk_size * 0.5,
			(chunk.min_elevation + chunk.max_elevation) * 0.5,
			chunk.chunk_size * 0.5
		)

		var distance := camera_pos.distance_to(chunk_center)

		# Determine LOD level based on distance thresholds
		var target_lod := 0
		for i in range(lod_distances.size()):
			if distance > lod_distances[i]:
				target_lod = i + 1

		# Clamp to available LOD levels
		target_lod = mini(target_lod, lod_resolutions.size() - 1)

		# Get current LOD level for this chunk
		var current_lod: int = chunk_current_lod.get(coords, 0)

		# Switch mesh if LOD level changed
		if target_lod != current_lod:
			var lod_meshes: Array = chunk_lod_meshes.get(coords, [])
			if target_lod < lod_meshes.size():
				mesh_instance.mesh = lod_meshes[target_lod]
				chunk_current_lod[coords] = target_lod

		# Visibility culling for chunks beyond max LOD distance
		var max_visible_distance := lod_distances[-1] * 2.0 if not lod_distances.is_empty() else 400.0
		mesh_instance.visible = distance < max_visible_distance


## Get current LOD level for a chunk
func get_chunk_lod(chunk_coords: Vector2i) -> int:
	return chunk_current_lod.get(chunk_coords, 0)


## Force a specific LOD level for a chunk (useful for debugging)
func set_chunk_lod(chunk_coords: Vector2i, lod_level: int) -> void:
	if not chunk_meshes.has(chunk_coords):
		return

	var lod_meshes: Array = chunk_lod_meshes.get(chunk_coords, [])
	lod_level = clampi(lod_level, 0, lod_meshes.size() - 1)

	if lod_level < lod_meshes.size():
		var mesh_instance: MeshInstance3D = chunk_meshes[chunk_coords]
		mesh_instance.mesh = lod_meshes[lod_level]
		chunk_current_lod[chunk_coords] = lod_level


## Set the camera reference for LOD updates
func set_camera(cam: Camera3D) -> void:
	camera = cam


# =============================================================================
# DYNAMIC UPDATES
# =============================================================================

## Update terrain visuals for a specific area (e.g., after avalanche, tracks)
func update_area(center: Vector3, radius: float) -> void:
	# Find affected chunks
	var affected_chunks := []

	for coords in terrain_service.chunks:
		var chunk: TerrainChunk = terrain_service.chunks[coords]
		var chunk_center := chunk.world_origin + Vector3(chunk.chunk_size * 0.5, 0, chunk.chunk_size * 0.5)

		if chunk_center.distance_to(center) < radius + chunk.chunk_size:
			affected_chunks.append(coords)

	# Regenerate affected chunk meshes
	for coords in affected_chunks:
		# Clean up existing mesh instance
		if chunk_meshes.has(coords):
			chunk_meshes[coords].queue_free()
			chunk_meshes.erase(coords)

		# Clean up LOD data for this chunk
		if chunk_lod_meshes.has(coords):
			chunk_lod_meshes.erase(coords)
		if chunk_current_lod.has(coords):
			chunk_current_lod.erase(coords)

		# Regenerate the chunk with new LOD meshes
		var chunk: TerrainChunk = terrain_service.chunks[coords]
		_generate_chunk_mesh(chunk)


# =============================================================================
# DEBUG VISUALIZATION
# =============================================================================

## Draw debug visualization for terrain analysis
func draw_debug_overlay(chunk: TerrainChunk) -> void:
	# This would create visual markers for cliffs, exit zones, etc.
	# Useful during development

	for cliff_coords in chunk.cliff_cells:
		var cell := chunk.get_cell(cliff_coords)
		_create_debug_marker(cell.position, Color.RED, "cliff")

	for exit_coords in chunk.exit_zone_cells:
		var cell := chunk.get_cell(exit_coords)
		_create_debug_marker(cell.position, Color.GREEN, "exit")


func _create_debug_marker(pos: Vector3, color: Color, _type: String) -> void:
	var marker := CSGSphere3D.new()
	marker.radius = 1.0
	marker.position = pos + Vector3(0, 1, 0)

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	marker.material = material

	add_child(marker)
