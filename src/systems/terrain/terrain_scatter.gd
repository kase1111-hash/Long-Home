class_name TerrainScatter
extends Node3D
## Trees and boulders on the mountain: low-poly conifers, wind-flattened
## krummholz and dead snags up to the treeline, boulders and talus on rock and
## scree and below the cliff bands, small rocks everywhere the ground is
## broken.
##
## Placement reads the analysed terrain cells (elevation, slope, surface,
## cliffs) and is deterministic per mountain:
##   - trees grow below a treeline set by the mountain's climate, in clumps
##     (forest noise), on ground under ~38 deg that is not ice or a cliff;
##     the tree band thins into shrubs and snags as it nears the treeline
##   - boulders favour scree and rock, gather as talus under cliffs, and
##     sit on snow only sparsely
##   - nothing grows on the guaranteed corridor, the summit plateau or base camp
##
## Rendering is one MultiMeshInstance3D per mesh variant (ScatterMeshes; any
## of them can be swapped for an authored mesh in res://assets/scatter/).
## Trees sway with the wind. Tree trunks, snags and boulders over ~0.9 m have
## cylinder colliders on OBSTACLE_LAYER: the climber walks round them, and
## hitting one at speed hurts (PlayerController).
##
## Built by TerrainService after each terrain load, before terrain_loaded is
## emitted, so maps and anchors can use it straight away.

# =============================================================================
# CONSTANTS
# =============================================================================

enum Kind { CONIFER, SNAG, SHRUB, BOULDER, ROCK }

const KIND_NAMES := {
	Kind.CONIFER: "conifer",
	Kind.SNAG: "snag",
	Kind.SHRUB: "shrub",
	Kind.BOULDER: "boulder",
	Kind.ROCK: "rock",
}

## Mesh variants per kind
const VARIANTS := {
	Kind.CONIFER: 3,
	Kind.SNAG: 2,
	Kind.SHRUB: 2,
	Kind.BOULDER: 4,
	Kind.ROCK: 3,
}

## Physics layer for obstacles (layer 3; the player's mask includes it,
## camera and terrain rays do not)
const OBSTACLE_LAYER := 4

## Keep-clear distances (metres)
const CORRIDOR_CLEARANCE := {
	Kind.CONIFER: 6.0,
	Kind.SNAG: 6.0,
	Kind.SHRUB: 4.0,
	Kind.BOULDER: 5.0,
	Kind.ROCK: 2.5,
}
const SUMMIT_CLEARANCE := 16.0
const BASE_CAMP_CLEARANCE := 26.0

## Steepest ground a tree or a boulder rests on (deg)
const MAX_TREE_SLOPE := 38.0
const MAX_BOULDER_SLOPE := 42.0

## Candidate grid spacing per kind (metres)
const GRID_SPACING := {
	Kind.CONIFER: 3.2,
	Kind.BOULDER: 4.5,
	Kind.ROCK: 3.0,
}

## Caps (performance)
const MAX_TREES := 2600
const MAX_BOULDERS := 800
const MAX_ROCKS := 2400

## Boulders at least this big (metres) get a collider
const MIN_COLLIDER_BOULDER := 0.9

## Spatial hash bucket (metres)
const BUCKET := 8.0

const WIND_AMPLITUDE := {
	GameEnums.WindStrength.CALM: 0.05,
	GameEnums.WindStrength.LIGHT: 0.2,
	GameEnums.WindStrength.MODERATE: 0.4,
	GameEnums.WindStrength.STRONG: 0.65,
	GameEnums.WindStrength.GALE: 0.9,
	GameEnums.WindStrength.SEVERE: 1.0,
}

const FOLIAGE_SHADER := """
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float wind_strength = 0.3;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float roughness_value = 0.92;

void vertex() {
	// Unit-frame meshes: VERTEX.y is the height up the tree (0 base, 1 top)
	vec3 origin = MODEL_MATRIX[3].xyz;
	float h = clamp(VERTEX.y, 0.0, 1.2);
	float gust = sin(TIME * 1.1 + origin.x * 0.13 + origin.z * 0.11) * 0.7
		+ sin(TIME * 2.7 + origin.x * 0.41 - origin.z * 0.37) * 0.3;
	float bend = h * h * wind_strength * (0.025 + 0.02 * gust);
	VERTEX.xz += wind_direction * bend;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness_value;
}
"""


# =============================================================================
# DATA
# =============================================================================

## One placed object
class ScatterObject:
	var kind: int = TerrainScatter.Kind.CONIFER
	var variant: int = 0
	## Ground contact point (base of the trunk, centre of the boulder's footprint)
	var position: Vector3 = Vector3.ZERO
	## Height (trees, shrubs, snags) or width (rocks), metres
	var size: float = 1.0
	var basis: Basis = Basis.IDENTITY
	## Collider radius and height (0 = no collider)
	var collider_radius: float = 0.0
	var collider_height: float = 0.0
	## Footprint radius for spacing (metres)
	var footprint: float = 1.0

	func is_tree() -> bool:
		return kind == TerrainScatter.Kind.CONIFER or kind == TerrainScatter.Kind.SNAG or kind == TerrainScatter.Kind.SHRUB

	func get_kind_name() -> String:
		return TerrainScatter.KIND_NAMES.get(kind, "object")


## Analysed terrain on one regular grid, copied out of the chunks
class CellGrid:
	var origin: Vector2 = Vector2.ZERO
	var cell_size: float = 2.0
	var width: int = 0
	var depth: int = 0
	var slope: PackedFloat32Array = PackedFloat32Array()
	var surface: PackedInt32Array = PackedInt32Array()
	var cliff: PackedFloat32Array = PackedFloat32Array()
	var elevation: PackedFloat32Array = PackedFloat32Array()
	## Nearest cliff lies uphill (talus ground)
	var cliff_above: PackedByteArray = PackedByteArray()
	var valid: PackedByteArray = PackedByteArray()

	func index_at(world: Vector2) -> int:
		# Cells sit on the grid vertices (TerrainChunk.world_to_grid rounds)
		var x := roundi((world.x - origin.x) / cell_size)
		var z := roundi((world.y - origin.y) / cell_size)
		if x < 0 or z < 0 or x >= width or z >= depth:
			return -1
		var i := z * width + x
		return i if valid[i] == 1 else -1


# =============================================================================
# STATE
# =============================================================================

## Build scatter at all (tests and benchmarks may switch it off)
@export var enabled: bool = true

## Where authored replacement meshes live (see ScatterMeshes.load_override)
@export var override_directory: String = "res://assets/scatter"

## Everything placed on the current terrain
var objects: Array[ScatterObject] = []

## TerrainService.load_serial this scatter was built for (-1 = none)
var built_serial: int = -1

## Snow dusting on the meshes (0-1) and the treeline as a fraction of the
## terrain's elevation range, for the current mountain
var snow_amount: float = 0.5
var treeline_fraction: float = 0.4

var terrain_service: TerrainService = null

var _buckets: Dictionary = {}  # Vector2i -> Array[int]
var _corridor_buckets: Dictionary = {}  # Vector2i -> PackedVector2Array
var _render_parent: Node3D = null
var _collision_body: StaticBody3D = null
var _foliage_material: ShaderMaterial = null
var _rock_material: StandardMaterial3D = null
var _forest_noise: FastNoiseLite = null
var _field_noise: FastNoiseLite = null


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	name = "TerrainScatter"
	_foliage_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = FOLIAGE_SHADER
	_foliage_material.shader = shader
	_rock_material = StandardMaterial3D.new()
	_rock_material.vertex_color_use_as_albedo = true
	_rock_material.roughness = 0.95
	if not EventBus.wind_changed.is_connected(_on_wind_changed):
		EventBus.wind_changed.connect(_on_wind_changed)


func _on_wind_changed(strength: GameEnums.WindStrength, direction: Vector3) -> void:
	if _foliage_material == null:
		return
	_foliage_material.set_shader_parameter("wind_strength", float(WIND_AMPLITUDE.get(strength, 0.3)))
	var flat := Vector2(direction.x, direction.z)
	if flat.length_squared() > 0.0001:
		_foliage_material.set_shader_parameter("wind_direction", flat.normalized())


# =============================================================================
# BUILD
# =============================================================================

## Rebuild for the terrain now loaded in the service
func rebuild(service: TerrainService) -> void:
	terrain_service = service
	clear()
	if not enabled or service == null or service.chunks.is_empty():
		built_serial = service.load_serial if service != null else -1
		return
	var started := Time.get_ticks_msec()

	var seed_value := hash(service.current_mountain + "/scatter")
	_setup_noise(seed_value)
	_read_climate(service.current_mountain)
	var grid := _build_cell_grid(service)
	_build_corridor_buckets(service)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_place_trees(grid, rng)
	_place_boulders(grid, rng, Kind.BOULDER, MAX_BOULDERS)
	_place_boulders(grid, rng, Kind.ROCK, MAX_ROCKS)

	_build_render(seed_value)
	_build_colliders()
	built_serial = service.load_serial

	var counts := count_by_kind()
	print("[TerrainScatter] %s: %d conifers, %d shrubs, %d snags, %d boulders, %d rocks in %d ms (treeline at %.0f%%)" % [
		service.current_mountain, counts[Kind.CONIFER], counts[Kind.SHRUB], counts[Kind.SNAG],
		counts[Kind.BOULDER], counts[Kind.ROCK], Time.get_ticks_msec() - started, treeline_fraction * 100.0
	])


## Remove every object, mesh and collider
func clear() -> void:
	objects.clear()
	_buckets.clear()
	_corridor_buckets.clear()
	# Detach before freeing: the rebuilt nodes take the same names this frame
	for node in [_render_parent, _collision_body]:
		if node != null and is_instance_valid(node):
			remove_child(node)
			node.queue_free()
	_render_parent = null
	_collision_body = null
	built_serial = -1


func _setup_noise(seed_value: int) -> void:
	_forest_noise = FastNoiseLite.new()
	_forest_noise.seed = seed_value
	_forest_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_forest_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_forest_noise.fractal_octaves = 3
	_forest_noise.frequency = 1.0 / 70.0
	_field_noise = FastNoiseLite.new()
	_field_noise.seed = seed_value + 31
	_field_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_field_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_field_noise.fractal_octaves = 2
	_field_noise.frequency = 1.0 / 45.0


## The climate sets the treeline and the snow on the branches: a mild peak is
## wooded well up its flanks, a cold giant has a few stunted trees at the foot
func _read_climate(mountain_id: String) -> void:
	var temperature := -12.0
	var db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if db != null:
		var mountain := db.get_mountain(mountain_id)
		if mountain != null:
			temperature = mountain.typical_temperature
	var warmth := clampf((temperature + 30.0) / 25.0, 0.0, 1.0)
	treeline_fraction = lerpf(0.2, 0.5, warmth)
	snow_amount = clampf(0.35 + 0.65 * (1.0 - warmth), 0.3, 1.0)


func _build_cell_grid(service: TerrainService) -> CellGrid:
	var grid := CellGrid.new()
	var bmin := service.terrain_bounds_min
	var bmax := service.terrain_bounds_max
	var first: TerrainChunk = service.chunks.values()[0]
	grid.cell_size = first.cell_size
	grid.origin = Vector2(bmin.x, bmin.z)
	grid.width = maxi(1, int(round((bmax.x - bmin.x) / grid.cell_size)))
	grid.depth = maxi(1, int(round((bmax.z - bmin.z) / grid.cell_size)))
	var count := grid.width * grid.depth
	grid.slope.resize(count)
	grid.surface.resize(count)
	grid.cliff.resize(count)
	grid.elevation.resize(count)
	grid.cliff_above.resize(count)
	grid.valid.resize(count)
	grid.valid.fill(0)
	for chunk in service.chunks.values():
		var ox := int(round((chunk.world_origin.x - grid.origin.x) / grid.cell_size))
		var oz := int(round((chunk.world_origin.z - grid.origin.y) / grid.cell_size))
		var cells: Array[Array] = chunk.cells
		for x in range(chunk.resolution):
			var gx := ox + x
			if gx < 0 or gx >= grid.width:
				continue
			var column: Array = cells[x]
			for z in range(chunk.resolution):
				var gz := oz + z
				if gz < 0 or gz >= grid.depth:
					continue
				var cell: TerrainCell = column[z]
				var i := gz * grid.width + gx
				grid.valid[i] = 1
				grid.slope[i] = cell.slope_angle
				grid.surface[i] = cell.surface_type
				grid.cliff[i] = cell.distance_to_cliff
				grid.elevation[i] = cell.elevation
				# slope_direction points downhill: a cliff in the uphill direction
				var uphill := Vector2(-cell.slope_direction.x, -cell.slope_direction.z)
				var to_cliff := Vector2(cell.cliff_direction.x, cell.cliff_direction.z)
				grid.cliff_above[i] = 1 if uphill.dot(to_cliff) > 0.3 else 0
	return grid


func _build_corridor_buckets(service: TerrainService) -> void:
	for point in service.corridor:
		var key := _bucket_key(Vector2(point.x, point.z))
		if not _corridor_buckets.has(key):
			_corridor_buckets[key] = PackedVector2Array()
		var bucket: PackedVector2Array = _corridor_buckets[key]
		bucket.append(Vector2(point.x, point.z))
		_corridor_buckets[key] = bucket


# =============================================================================
# PLACEMENT
# =============================================================================

func _place_trees(grid: CellGrid, rng: RandomNumberGenerator) -> void:
	var spacing: float = GRID_SPACING[Kind.CONIFER]
	var bmin := terrain_service.terrain_bounds_min
	var bmax := terrain_service.terrain_bounds_max
	var low := bmin.y
	var span := maxf(bmax.y - bmin.y, 1.0)
	var placed := 0
	var nx := int((bmax.x - bmin.x) / spacing)
	var nz := int((bmax.z - bmin.z) / spacing)
	for iz in range(nz):
		for ix in range(nx):
			if placed >= MAX_TREES:
				return
			var p := Vector2(bmin.x + (float(ix) + rng.randf()) * spacing, bmin.z + (float(iz) + rng.randf()) * spacing)
			var roll := rng.randf()
			var i := grid.index_at(p)
			if i < 0:
				continue
			# Height band: full below the forest line, thinning to the treeline
			var fraction := (grid.elevation[i] - low) / span
			var band := 1.0 - smoothstep(treeline_fraction - 0.16, treeline_fraction, fraction)
			if band <= 0.0:
				continue
			var slope := grid.slope[i]
			if slope > MAX_TREE_SLOPE or grid.cliff[i] < 4.0:
				continue
			var ground := _tree_ground_factor(grid.surface[i])
			if ground <= 0.0:
				continue
			var clump := smoothstep(-0.3, 0.35, _forest_noise.get_noise_2d(p.x, p.y))
			var steepness := 1.0 if slope < 30.0 else 0.5
			var chance := 0.55 * band * clump * ground * steepness
			if roll >= chance:
				continue

			# Near the treeline the forest gives way to krummholz and snags
			var kind := Kind.CONIFER
			var pick := rng.randf()
			if band < 0.45:
				kind = Kind.SHRUB if pick < 0.6 else (Kind.SNAG if pick < 0.75 else Kind.CONIFER)
			elif pick < 0.04:
				kind = Kind.SNAG
			var size := 1.0
			match kind:
				Kind.CONIFER:
					size = lerpf(3.5, 13.0, pow(rng.randf(), 0.8)) * lerpf(0.55, 1.0, band)
				Kind.SNAG:
					size = rng.randf_range(4.0, 9.0)
				Kind.SHRUB:
					size = rng.randf_range(0.6, 1.5)
			var footprint := 1.6 if kind == Kind.SHRUB else clampf(size * 0.22, 1.2, 2.6)
			if not _is_clear(p, kind, footprint) or not _cell_allows(p, kind):
				continue
			var obj := ScatterObject.new()
			obj.kind = kind
			obj.variant = rng.randi_range(0, int(VARIANTS[kind]) - 1)
			obj.size = size
			obj.footprint = footprint
			obj.basis = Basis(Vector3.UP, rng.randf_range(0.0, TAU))
			if kind == Kind.SNAG:
				# Dead trees lean
				obj.basis = obj.basis * Basis(Vector3.RIGHT, rng.randf_range(-0.12, 0.12))
			obj.position = _ground(p, 0.4, 0.15)
			if kind != Kind.SHRUB:
				obj.collider_radius = clampf(0.03 * size + 0.12, 0.18, 0.55)
				obj.collider_height = minf(size, 6.0)
			_add(obj)
			placed += 1


## How well trees grow on a surface (0 = not at all)
func _tree_ground_factor(surface: int) -> float:
	match surface:
		GameEnums.SurfaceType.ICE:
			return 0.0
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET:
			return 0.15  # Rooted in cracks
		GameEnums.SurfaceType.MIXED:
			return 0.25
		GameEnums.SurfaceType.SCREE:
			return 0.3
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.7
	return 1.0


func _place_boulders(grid: CellGrid, rng: RandomNumberGenerator, kind: int, cap: int) -> void:
	var spacing: float = GRID_SPACING[kind]
	var bmin := terrain_service.terrain_bounds_min
	var bmax := terrain_service.terrain_bounds_max
	var placed := 0
	var nx := int((bmax.x - bmin.x) / spacing)
	var nz := int((bmax.z - bmin.z) / spacing)
	var small := kind == Kind.ROCK
	for iz in range(nz):
		for ix in range(nx):
			if placed >= cap:
				return
			var p := Vector2(bmin.x + (float(ix) + rng.randf()) * spacing, bmin.z + (float(iz) + rng.randf()) * spacing)
			var roll := rng.randf()
			var i := grid.index_at(p)
			if i < 0:
				continue
			var slope := grid.slope[i]
			if slope > MAX_BOULDER_SLOPE or grid.cliff[i] < 2.0:
				continue
			var ground := _rock_ground_factor(grid.surface[i])
			if ground <= 0.0:
				continue
			# Talus: rockfall piles up at the foot of a cliff
			var talus := 0.0
			if grid.cliff_above[i] == 1 and grid.cliff[i] < 30.0:
				talus = 1.0 - grid.cliff[i] / 30.0
			var field := smoothstep(-0.2, 0.5, _field_noise.get_noise_2d(p.x, p.y))
			var chance := (0.16 if small else 0.11) * ground * (0.35 + field) + (0.25 if small else 0.35) * talus
			if slope > 35.0:
				chance *= 0.6
			if roll >= chance:
				continue
			var size := 0.0
			if small:
				size = rng.randf_range(0.2, 0.6)
			else:
				size = 0.6 + 2.6 * pow(rng.randf(), 2.2) + 0.8 * talus * rng.randf()
			var footprint := maxf(size * 0.6, 0.4)
			if not _is_clear(p, kind, footprint) or not _cell_allows(p, kind):
				continue
			var obj := ScatterObject.new()
			obj.kind = kind
			obj.variant = rng.randi_range(0, int(VARIANTS[kind]) - 1)
			obj.size = size
			obj.footprint = footprint
			# Settled into the slope: random heading, a little tilt
			obj.basis = Basis(Vector3.UP, rng.randf_range(0.0, TAU)) * Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.18))
			obj.position = _ground(p, size * 0.4, size * 0.08)
			if not small and size >= MIN_COLLIDER_BOULDER:
				obj.collider_radius = size * 0.42
				obj.collider_height = size * 0.6
			_add(obj)
			placed += 1


## How readily boulders lie on a surface (0 = never)
func _rock_ground_factor(surface: int) -> float:
	match surface:
		GameEnums.SurfaceType.SCREE:
			return 1.0
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET:
			return 0.7
		GameEnums.SurfaceType.MIXED:
			return 0.6
		GameEnums.SurfaceType.GRASS, GameEnums.SurfaceType.MUD:
			return 0.35
		GameEnums.SurfaceType.ICE:
			return 0.0
	return 0.08  # Erratics on snow


## The terrain's own cell under the point (what the game will query later)
## agrees: not too steep, not ice for a tree, not a cliff
func _cell_allows(p: Vector2, kind: int) -> bool:
	var cell := terrain_service.get_cell_at(Vector3(p.x, 0.0, p.y))
	if cell == null or cell.requires_rope or cell.is_glacier:
		return false
	if kind == Kind.BOULDER or kind == Kind.ROCK:
		return cell.slope_angle <= MAX_BOULDER_SLOPE and _rock_ground_factor(cell.surface_type) > 0.0
	return cell.slope_angle <= MAX_TREE_SLOPE and _tree_ground_factor(cell.surface_type) > 0.0


## Clear of the corridor, the summit, base camp, the world's edge and other objects?
func _is_clear(p: Vector2, kind: int, footprint: float) -> bool:
	var bmin := terrain_service.terrain_bounds_min
	var bmax := terrain_service.terrain_bounds_max
	var margin := footprint + 3.0
	if p.x < bmin.x + margin or p.x > bmax.x - margin or p.y < bmin.z + margin or p.y > bmax.z - margin:
		return false
	var summit := terrain_service.start_position
	var base := terrain_service.goal_position
	if summit != Vector3.ZERO and p.distance_to(Vector2(summit.x, summit.z)) < SUMMIT_CLEARANCE:
		return false
	if base != Vector3.ZERO and p.distance_to(Vector2(base.x, base.z)) < BASE_CAMP_CLEARANCE:
		return false
	if _distance_to_corridor(p) < float(CORRIDOR_CLEARANCE[kind]) + footprint * 0.5:
		return false
	# Spacing: footprints must not overlap
	var key := _bucket_key(p)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var bucket: Array = _buckets.get(key + Vector2i(dx, dz), [])
			for index in bucket:
				var other: ScatterObject = objects[index]
				var gap := footprint + other.footprint
				if kind == Kind.ROCK or other.kind == Kind.ROCK:
					gap *= 0.6
				if p.distance_to(Vector2(other.position.x, other.position.z)) < gap:
					return false
	return true


func _distance_to_corridor(p: Vector2) -> float:
	if _corridor_buckets.is_empty():
		return INF
	var key := _bucket_key(p)
	var best := INF
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var bucket: PackedVector2Array = _corridor_buckets.get(key + Vector2i(dx, dz), PackedVector2Array())
			for q in bucket:
				best = minf(best, p.distance_squared_to(q))
	return sqrt(best)


## Base position on the ground: the lowest point of the footprint, sunk a little
## so nothing floats on a slope
func _ground(p: Vector2, radius: float, sink: float) -> Vector3:
	var lowest := terrain_service.get_height_at(Vector3(p.x, 0.0, p.y))
	for k in range(4):
		var angle := TAU * float(k) / 4.0 + 0.4
		var q := Vector3(p.x + cos(angle) * radius, 0.0, p.y + sin(angle) * radius)
		if terrain_service.has_terrain_at(q):
			lowest = minf(lowest, terrain_service.get_height_at(q))
	return Vector3(p.x, lowest - sink, p.y)


func _add(obj: ScatterObject) -> void:
	objects.append(obj)
	var key := _bucket_key(Vector2(obj.position.x, obj.position.z))
	if not _buckets.has(key):
		_buckets[key] = []
	(_buckets[key] as Array).append(objects.size() - 1)


func _bucket_key(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / BUCKET)), int(floor(p.y / BUCKET)))


# =============================================================================
# RENDERING AND COLLISION
# =============================================================================

func _build_render(seed_value: int) -> void:
	_render_parent = Node3D.new()
	_render_parent.name = "ScatterMeshes"
	add_child(_render_parent)

	# Group the objects by kind and variant
	var groups := {}
	for obj in objects:
		var key := Vector2i(obj.kind, obj.variant)
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(obj)

	for key in groups:
		var kind: int = key.x
		var variant: int = key.y
		var members: Array = groups[key]
		var mesh_info := _mesh_for(kind, variant, seed_value)
		var mesh: Mesh = mesh_info["mesh"]
		var fit: Transform3D = mesh_info["fit"]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = members.size()
		for n in range(members.size()):
			var obj: ScatterObject = members[n]
			var placement := Transform3D(obj.basis.scaled(Vector3.ONE * obj.size), obj.position)
			multimesh.set_instance_transform(n, placement * fit)
		var instance := MultiMeshInstance3D.new()
		instance.name = "%s_%d" % [KIND_NAMES[kind], variant]
		instance.multimesh = multimesh
		if not bool(mesh_info["authored"]):
			instance.material_override = _rock_material if (kind == Kind.BOULDER or kind == Kind.ROCK) else _foliage_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if kind == Kind.ROCK else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_render_parent.add_child(instance)


## Mesh for a kind/variant: an authored override if installed, else built here
func _mesh_for(kind: int, variant: int, seed_value: int) -> Dictionary:
	var override := ScatterMeshes.load_override(override_directory, KIND_NAMES[kind], variant)
	if not override.is_empty():
		override["authored"] = true
		return override
	var mesh_seed := seed_value + kind * 1009 + variant * 97
	var mesh: Mesh = null
	match kind:
		Kind.CONIFER:
			mesh = ScatterMeshes.build_conifer(mesh_seed, variant, snow_amount)
		Kind.SNAG:
			mesh = ScatterMeshes.build_snag(mesh_seed)
		Kind.SHRUB:
			mesh = ScatterMeshes.build_shrub(mesh_seed, variant, snow_amount)
		Kind.BOULDER:
			mesh = ScatterMeshes.build_boulder(mesh_seed, variant, snow_amount)
		Kind.ROCK:
			mesh = ScatterMeshes.build_rock(mesh_seed, variant, snow_amount)
	return {"mesh": mesh, "fit": Transform3D.IDENTITY, "authored": false}


func _build_colliders() -> void:
	_collision_body = StaticBody3D.new()
	_collision_body.name = "ScatterColliders"
	_collision_body.collision_layer = OBSTACLE_LAYER
	_collision_body.collision_mask = 0
	_collision_body.add_to_group("scatter_obstacle")
	add_child(_collision_body)
	for index in range(objects.size()):
		var obj := objects[index]
		if obj.collider_radius <= 0.0:
			continue
		var cylinder := CylinderShape3D.new()
		cylinder.radius = obj.collider_radius
		cylinder.height = obj.collider_height
		var shape := CollisionShape3D.new()
		shape.shape = cylinder
		shape.position = obj.position + Vector3(0.0, obj.collider_height * 0.5, 0.0)
		shape.set_meta("scatter_kind", obj.get_kind_name())
		shape.set_meta("scatter_index", index)
		_collision_body.add_child(shape)


# =============================================================================
# QUERIES
# =============================================================================

## Objects within radius (XZ) of a point, nearest first
func get_objects_near(center: Vector3, radius: float) -> Array[ScatterObject]:
	var found: Array[ScatterObject] = []
	var flat := Vector2(center.x, center.z)
	var reach := int(ceil(radius / BUCKET))
	var key := _bucket_key(flat)
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var bucket: Array = _buckets.get(key + Vector2i(dx, dz), [])
			for index in bucket:
				var obj: ScatterObject = objects[index]
				if flat.distance_to(Vector2(obj.position.x, obj.position.z)) <= radius:
					found.append(obj)
	found.sort_custom(func(a: ScatterObject, b: ScatterObject) -> bool:
		return flat.distance_squared_to(Vector2(a.position.x, a.position.z)) < flat.distance_squared_to(Vector2(b.position.x, b.position.z)))
	return found


## Number of objects of each kind
func count_by_kind() -> Dictionary:
	var counts := {}
	for kind in Kind.values():
		counts[kind] = 0
	for obj in objects:
		counts[obj.kind] = int(counts[obj.kind]) + 1
	return counts


## Number of colliders built
func get_collider_count() -> int:
	return _collision_body.get_child_count() if _collision_body != null else 0


## Tree positions (map symbols)
func get_tree_points() -> PackedVector2Array:
	var points := PackedVector2Array()
	for obj in objects:
		if obj.kind == Kind.CONIFER or obj.kind == Kind.SNAG:
			points.append(Vector2(obj.position.x, obj.position.z))
	return points


## Boulder positions at least min_size across (map symbols)
func get_boulder_points(min_size: float = 1.2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for obj in objects:
		if obj.kind == Kind.BOULDER and obj.size >= min_size:
			points.append(Vector2(obj.position.x, obj.position.z))
	return points
