class_name TerrainGenerator
extends Node3D
## Generates visual terrain meshes and collision shapes from terrain data
## Handles LOD and chunk-based rendering
##
## Mesh and collision for a chunk are built from the same (resolution + 1)^2
## height samples: interior samples from the chunk itself, the last row/column
## from the neighbouring chunk (via TerrainService.get_grid_height), so chunk
## seams are watertight and normals match across them.

# =============================================================================
# SIGNALS
# =============================================================================

signal chunk_mesh_generated(chunk_coords: Vector2i)
signal all_meshes_generated()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Material for terrain rendering (a procedural default is built when null)
@export var terrain_material: Material

## Generate collision shapes
@export var generate_collision: bool = true

## LOD distances
@export var lod_distances: Array[float] = [140.0, 280.0, 560.0]

## Depth of the apron hanging from each chunk edge (hides LOD seam cracks)
@export var skirt_depth: float = 6.0

## LOD resolution multipliers (1.0 = full res, 0.5 = half, etc.)
@export var lod_resolutions: Array[float] = [1.0, 0.5, 0.25]

## World-space repeat size of the procedural detail texture (metres)
@export var detail_texture_scale: float = 3.0

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

## Per-vertex colour variation noise
var _color_noise: FastNoiseLite

## Padded height samples for the chunk being built: (resolution + 3)^2,
## covering grid indices -1 .. resolution + 1
var _padded: PackedFloat32Array = PackedFloat32Array()
var _padded_stride: int = 0

## TerrainService.load_serial the current meshes were built for
var _built_serial: int = -1


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

	_color_noise = FastNoiseLite.new()
	_color_noise.seed = 7919
	_color_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_color_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_color_noise.fractal_octaves = 2
	_color_noise.frequency = 1.0 / 9.0

	if terrain_material == null:
		terrain_material = _create_default_material()

	# Get terrain service
	ServiceLocator.get_service_async("TerrainService", _on_terrain_service_ready)


func _on_terrain_service_ready(service: Object) -> void:
	terrain_service = service as TerrainService
	if terrain_service == null:
		return
	terrain_service.terrain_loaded.connect(_on_terrain_loaded)
	terrain_service.chunk_loaded.connect(_on_chunk_loaded)

	print("[TerrainGenerator] Connected to TerrainService")

	# Terrain may already be loaded (generator attached late)
	if not terrain_service.is_loading and not terrain_service.chunks.is_empty():
		rebuild_all()


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
# DEFAULT MATERIAL
# =============================================================================

## Procedural default: vertex colours for the surface palette plus a subtle
## seamless noise grain projected triplanar in world space
func _create_default_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.metallic = 0.0
	material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	var noise := FastNoiseLite.new()
	noise.seed = 1301
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.frequency = 0.02

	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.85, 0.85, 0.85))
	ramp.set_color(1, Color(1.0, 1.0, 1.0))

	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.noise = noise
	texture.color_ramp = ramp

	material.albedo_texture = texture
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	var repeat := 1.0 / maxf(detail_texture_scale, 0.1)
	material.uv1_scale = Vector3(repeat, repeat, repeat)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	return material


# =============================================================================
# MESH GENERATION
# =============================================================================

func _on_terrain_loaded(_mountain_id: String) -> void:
	# TerrainService.load_terrain() already called rebuild_all() for this load
	if _built_serial == terrain_service.load_serial:
		return
	rebuild_all()


func _on_chunk_loaded(chunk_coords: Vector2i) -> void:
	# Bulk loads are handled once in _on_terrain_loaded
	if terrain_service == null or terrain_service.is_loading:
		return
	if chunk_meshes.has(chunk_coords):
		return
	_build_chunk(chunk_coords)


## Clear and rebuild meshes + collision for every loaded chunk
func rebuild_all() -> void:
	if terrain_service == null:
		return
	var started := Time.get_ticks_msec()
	_clear_all_meshes()
	_built_serial = terrain_service.load_serial

	for coords in terrain_service.chunks:
		_build_chunk(coords)

	print("[TerrainGenerator] Built %d chunk meshes in %d ms" % [
		chunk_meshes.size(), Time.get_ticks_msec() - started
	])
	all_meshes_generated.emit()


func _build_chunk(chunk_coords: Vector2i) -> void:
	var chunk: TerrainChunk = terrain_service.chunks.get(chunk_coords)
	if chunk == null:
		return
	_fill_padded_samples(chunk)
	_generate_chunk_mesh(chunk)
	if generate_collision:
		_generate_chunk_collision(chunk)
	chunk_mesh_generated.emit(chunk_coords)


func _clear_all_meshes() -> void:
	for instance in chunk_meshes.values():
		var mesh_instance: MeshInstance3D = instance
		# Unbind before freeing so the renderer never sees an instance whose
		# mesh RID was released first (the headless dummy renderer complains)
		mesh_instance.mesh = null
		mesh_instance.queue_free()
	chunk_meshes.clear()

	for collider in chunk_colliders.values():
		collider.queue_free()
	chunk_colliders.clear()

	# Clear LOD data
	chunk_lod_meshes.clear()
	chunk_current_lod.clear()


## Gather (resolution + 3)^2 samples around the chunk, seams included
func _fill_padded_samples(chunk: TerrainChunk) -> void:
	var res := chunk.resolution
	var stride := res + 3
	_padded_stride = stride
	_padded.resize(stride * stride)

	var heightmap := chunk.heightmap
	var coords := chunk.chunk_coords
	for z in range(-1, res + 2):
		var row := (z + 1) * stride
		for x in range(-1, res + 2):
			var h: float
			if x >= 0 and x < res and z >= 0 and z < res:
				h = heightmap[z * res + x]
			else:
				h = terrain_service.get_grid_height(coords, x, z)
			_padded[row + x + 1] = h


func _padded_height(x: int, z: int) -> float:
	return _padded[(z + 1) * _padded_stride + x + 1]


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


## Create terrain mesh from the padded sample grid
func _create_terrain_mesh(chunk: TerrainChunk, resolution_scale: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var res := chunk.resolution
	var step := maxi(1, int(round(1.0 / resolution_scale)))
	var grid_size := res / step
	var cell := chunk.cell_size
	var sample_spacing := cell * step
	var coords := chunk.chunk_coords

	# Calculate vertex and index counts (surface + four skirt strips)
	var surface_vertex_count := (grid_size + 1) * (grid_size + 1)
	var skirt_vertex_count := 4 * (grid_size + 1)
	var vertex_count := surface_vertex_count + skirt_vertex_count
	var index_count := grid_size * grid_size * 6 + 4 * grid_size * 12

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

	var origin_x := chunk.world_origin.x
	var origin_y := chunk.world_origin.y
	var origin_z := chunk.world_origin.z
	var inv_2s := 1.0 / (2.0 * sample_spacing)
	var padded := _padded
	var stride := _padded_stride
	var cells := chunk.cells
	var inv_res := 1.0 / float(res)

	# Generate vertices
	var vertex_idx := 0
	for gz in range(grid_size + 1):
		var z := gz * step
		var z_prev := maxi(z - step, -1)
		var z_next := mini(z + step, res + 1)
		var row := (z + 1) * stride + 1
		var row_prev := (z_prev + 1) * stride + 1
		var row_next := (z_next + 1) * stride + 1
		var world_z := origin_z + z * cell
		for gx in range(grid_size + 1):
			var x := gx * step
			var height := padded[row + x]

			# Local position within chunk (heights are absolute, world_origin.y is 0)
			vertices[vertex_idx] = Vector3(x * cell, height - origin_y, z * cell)

			# Normal from central differences on the same sample grid
			var east := padded[row + mini(x + step, res + 1)]
			var west := padded[row + maxi(x - step, -1)]
			var south := padded[row_next + x]
			var north := padded[row_prev + x]
			var dx := (east - west) * inv_2s
			var dz := (south - north) * inv_2s
			normals[vertex_idx] = Vector3(-dx, 1.0, -dz).normalized()

			# UV coordinates
			uvs[vertex_idx] = Vector2(float(x) * inv_res, float(z) * inv_res)

			# Vertex color based on surface/slope (neighbour cell on the seam row/column)
			var cell_data: TerrainCell
			if x < res and z < res:
				cell_data = cells[x][z]
			else:
				cell_data = terrain_service.get_grid_cell(coords, x, z)
			colors[vertex_idx] = _get_vertex_color(cell_data, origin_x + x * cell, world_z)

			vertex_idx += 1

	# Generate indices (triangles); split along the (x+1, z) -> (x, z+1) diagonal,
	# matching HeightMapShape3D and TerrainChunk.get_height_at_world.
	# Godot front faces wind clockwise, so seen from above (+Y) each triangle
	# runs TL -> TR -> BL.
	var index_idx := 0
	for z in range(grid_size):
		for x in range(grid_size):
			var top_left := z * (grid_size + 1) + x
			var top_right := top_left + 1
			var bottom_left := (z + 1) * (grid_size + 1) + x
			var bottom_right := bottom_left + 1

			# First triangle (faces up)
			indices[index_idx] = top_left
			indices[index_idx + 1] = top_right
			indices[index_idx + 2] = bottom_left

			# Second triangle (faces up)
			indices[index_idx + 3] = top_right
			indices[index_idx + 4] = bottom_right
			indices[index_idx + 5] = bottom_left

			index_idx += 6

	# Skirts: copy each edge row/column downward and stitch it with both
	# windings so cracks between differently tessellated neighbours never show
	var skirt_base := surface_vertex_count
	var edges: Array[PackedInt32Array] = []
	var north := PackedInt32Array()
	var south := PackedInt32Array()
	var west := PackedInt32Array()
	var east := PackedInt32Array()
	for i in range(grid_size + 1):
		north.append(i)
		south.append(grid_size * (grid_size + 1) + i)
		west.append(i * (grid_size + 1))
		east.append(i * (grid_size + 1) + grid_size)
	edges.append(north)
	edges.append(south)
	edges.append(west)
	edges.append(east)

	for edge in edges:
		for i in range(edge.size()):
			var src := edge[i]
			vertices[skirt_base + i] = vertices[src] - Vector3(0.0, skirt_depth, 0.0)
			normals[skirt_base + i] = normals[src]
			uvs[skirt_base + i] = uvs[src]
			colors[skirt_base + i] = colors[src]
		for i in range(edge.size() - 1):
			var a := edge[i]
			var b := edge[i + 1]
			var c := skirt_base + i
			var d := skirt_base + i + 1
			indices[index_idx] = a
			indices[index_idx + 1] = b
			indices[index_idx + 2] = c
			indices[index_idx + 3] = b
			indices[index_idx + 4] = d
			indices[index_idx + 5] = c
			indices[index_idx + 6] = a
			indices[index_idx + 7] = c
			indices[index_idx + 8] = b
			indices[index_idx + 9] = b
			indices[index_idx + 10] = c
			indices[index_idx + 11] = d
			index_idx += 12
		skirt_base += edge.size()

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Get vertex color based on terrain cell properties
func _get_vertex_color(cell: TerrainCell, world_x: float = 0.0, world_z: float = 0.0) -> Color:
	if cell == null:
		return Color(0.5, 0.5, 0.5, 1.0)

	# Base color by surface type
	var color := Color.WHITE

	match cell.surface_type:
		GameEnums.SurfaceType.SNOW_FIRM:
			color = Color(0.93, 0.94, 0.98)
		GameEnums.SurfaceType.SNOW_SOFT:
			color = Color(0.9, 0.92, 0.98)
		GameEnums.SurfaceType.SNOW_PACKED:
			color = Color(0.9, 0.91, 0.95)
		GameEnums.SurfaceType.SNOW_POWDER:
			color = Color(1.0, 1.0, 1.0)
		GameEnums.SurfaceType.ICE:
			color = Color(0.78, 0.88, 1.0)
		GameEnums.SurfaceType.ROCK:
			color = Color(0.45, 0.4, 0.35)
		GameEnums.SurfaceType.ROCK_DRY:
			color = Color(0.5, 0.45, 0.4)
		GameEnums.SurfaceType.ROCK_WET:
			color = Color(0.35, 0.32, 0.28)
		GameEnums.SurfaceType.SCREE:
			color = Color(0.55, 0.52, 0.48)
		GameEnums.SurfaceType.GRASS:
			color = Color(0.45, 0.5, 0.3)
		GameEnums.SurfaceType.MUD:
			color = Color(0.35, 0.3, 0.25)
		GameEnums.SurfaceType.MIXED:
			color = Color(0.7, 0.7, 0.75)

	# Darken steep slopes
	var slope_factor := 1.0 - (cell.slope_angle / 90.0) * 0.4
	color = color * slope_factor

	# Per-vertex grain so large slopes are not flat colour
	var variation := 1.0 + _color_noise.get_noise_2d(world_x, world_z) * 0.09
	color = Color(color.r * variation, color.g * variation, color.b * variation, 1.0)

	# Slight blue tint in shaded areas
	if cell.sun_exposure < 0.3:
		color = color.lerp(Color(0.8, 0.85, 0.95), 0.2)

	color.a = 1.0
	return color


# =============================================================================
# COLLISION GENERATION
# =============================================================================

## Generate collision shape for a chunk from the same samples as the mesh
func _generate_chunk_collision(chunk: TerrainChunk) -> void:
	var static_body := StaticBody3D.new()
	static_body.name = "Collider_%d_%d" % [chunk.chunk_coords.x, chunk.chunk_coords.y]

	var collision_shape := CollisionShape3D.new()
	var heightmap_shape := HeightMapShape3D.new()

	var map_width := chunk.resolution + 1
	var map_depth := chunk.resolution + 1

	heightmap_shape.map_width = map_width
	heightmap_shape.map_depth = map_depth

	var height_data := PackedFloat32Array()
	height_data.resize(map_width * map_depth)

	for z in range(map_depth):
		for x in range(map_width):
			height_data[z * map_width + x] = _padded_height(x, z) - chunk.world_origin.y

	heightmap_shape.map_data = height_data
	collision_shape.shape = heightmap_shape

	# HeightMapShape3D is centred on its XZ extent with 1 unit between samples:
	# scale to the cell size and shift by half a chunk so sample (0, 0) lands on
	# the chunk origin. Heights are already relative to world_origin.y.
	collision_shape.position = Vector3(chunk.chunk_size * 0.5, 0.0, chunk.chunk_size * 0.5)
	collision_shape.scale = Vector3(chunk.cell_size, 1.0, chunk.cell_size)

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

		# Visibility culling for chunks far beyond the last LOD distance
		var max_visible_distance := lod_distances[-1] * 3.0 if not lod_distances.is_empty() else 1000.0
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
	if terrain_service == null:
		return

	# Find affected chunks
	var affected_chunks: Array[Vector2i] = []

	for coords in terrain_service.chunks:
		var chunk: TerrainChunk = terrain_service.chunks[coords]
		var chunk_center := chunk.world_origin + Vector3(chunk.chunk_size * 0.5, 0, chunk.chunk_size * 0.5)

		if chunk_center.distance_to(center) < radius + chunk.chunk_size:
			affected_chunks.append(coords)

	# Regenerate affected chunk meshes
	for coords in affected_chunks:
		# Clean up existing mesh instance
		if chunk_meshes.has(coords):
			var old_instance: MeshInstance3D = chunk_meshes[coords]
			old_instance.mesh = null
			old_instance.queue_free()
			chunk_meshes.erase(coords)

		# Clean up LOD data for this chunk
		chunk_lod_meshes.erase(coords)
		chunk_current_lod.erase(coords)

		# Regenerate the chunk with new LOD meshes
		var chunk: TerrainChunk = terrain_service.chunks[coords]
		_fill_padded_samples(chunk)
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
