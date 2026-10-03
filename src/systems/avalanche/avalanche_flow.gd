class_name AvalancheFlow
extends RefCounted
## One avalanche running down the mountain: snow parcels sliding over the
## heightfield under the Voellmy-Salm friction law used by avalanche
## engineers,
##
##   a = g (sin(theta) - mu cos(theta)) - g v^2 / (xi h)
##
## a dry-friction term (mu) that decides where the snow stops, and a
## turbulent drag term (xi, flow height h) that caps its speed. The parcels
## keep their momentum, so the snow follows gullies, spills over cliffs and
## runs out across the flats below a steep slope. Moving snow picks up the
## loose snow of the track (entrainment) and, where it stops, piles up as
## debris (deposit), compacted to about 60% of its volume.
##
## Parameters follow the Swiss guidelines' trend: small avalanches stop
## sooner (higher mu, lower xi), wet snow is slow and dense, ice blocks
## bounce and grind.
##
## The map ends before the valley does: near its edge the snow meets the
## unmapped valley floor (extra friction) and stops there in debris fans.

# =============================================================================
# CONSTANTS
# =============================================================================

enum Kind { SLAB, LOOSE, WET, ICE }

const KIND_NAMES := {Kind.SLAB: "slab", Kind.LOOSE: "loose", Kind.WET: "wet", Kind.ICE: "ice"}

const GRAVITY := 9.81
## A parcel slower than this on ground that holds it stops (m/s)
const STOP_SPEED := 0.8
## Hard limit on an avalanche's running time (seconds)
const MAX_TIME := 100.0
## Deposit grid spacing: the terrain vertex spacing (metres)
const DEPOSIT_STEP := 2.0
## Debris is denser than the snow that ran
const DEBRIS_COMPACTION := 0.6
## Deepest debris at one point (metres)
const MAX_DEBRIS_DEPTH := 6.0
## A parcel can at most double by entrainment (avalanches typically grow
## one and a half to three times between release and runout)
const MAX_GROWTH := 2.0
## Width of track a parcel sweeps for entrainment (metres)
const SWEEP_WIDTH := 1.0
## A parcel creeping slower than this for CREEP_TIME has stopped (m/s, s)
const CREEP_SPEED := 1.5
const CREEP_TIME := 2.5
## Debris spreads to about this thickness around where a parcel stops (m)
const DEPOSIT_THICKNESS := 1.0
## Thinner debris than this is not worth carving into the terrain (m)
const MIN_DEBRIS := 0.05
## The map ends before the valley does: within this distance of the edge the
## snow meets the valley floor beyond (extra friction) and fans out there
const EDGE_APRON := 40.0
const EDGE_FRICTION := 1.5
## Height of the moving snow above the ground, for drawing (metres)
const FLOW_LIFT := 0.35

## Voellmy parameters by size (index 1-4)
const SLAB_MU: Array[float] = [0.0, 0.40, 0.31, 0.25, 0.21]
const SLAB_XI: Array[float] = [0.0, 700.0, 1100.0, 1700.0, 2300.0]

# =============================================================================
# STATE
# =============================================================================

var id: int = 0
var kind: int = Kind.SLAB
var size: int = 2
var natural: bool = false
## The problem that released (AvalancheConditions.ProblemType, -1 for ice)
var problem_type: int = -1
var mu: float = 0.3
var xi: float = 1100.0
## Flow height for the drag term (metres)
var flow_height: float = 1.5
## Snow available to entrain along the track (metres)
var entrain_depth: float = 0.1
var slab_depth: float = 0.5

## Where it released: trigger point, slab cells and crown cells (world xz)
var origin: Vector3 = Vector3.ZERO
var slab_points: PackedVector2Array = PackedVector2Array()
var crown_points: PackedVector2Array = PackedVector2Array()
var crown_downhill: PackedVector2Array = PackedVector2Array()

## Parcels
var positions: PackedVector3Array = PackedVector3Array()
var velocities: PackedVector3Array = PackedVector3Array()
var volumes: PackedFloat32Array = PackedFloat32Array()
var start_volumes: PackedFloat32Array = PackedFloat32Array()
var moving: PackedByteArray = PackedByteArray()
var _slow_time: PackedFloat32Array = PackedFloat32Array()

## Bookkeeping (m^3 of snow as it ran, before compaction)
var released_volume: float = 0.0
var entrained_volume: float = 0.0
var deposited_volume: float = 0.0
## Snow that ran on past the edge of the mapped mountain
var lost_volume: float = 0.0
## Deposit (Vector2i on the 2 m vertex grid -> m^3 of snow)
var deposit: Dictionary = {}
var deposit_origin: Vector2 = Vector2.ZERO

var time: float = 0.0
var finished: bool = false
var max_speed: float = 0.0
## Lowest point reached (for the runout) and the furthest parcel
var lowest: Vector3 = Vector3(0.0, INF, 0.0)

var _rng := RandomNumberGenerator.new()


# =============================================================================
# SETUP
# =============================================================================

## Configure the friction for a kind and size
func configure(flow_kind: int, flow_size: int, depth: float, seed_value: int) -> void:
	kind = flow_kind
	size = clampi(flow_size, 1, 4)
	slab_depth = depth
	_rng.seed = seed_value
	mu = SLAB_MU[size]
	xi = SLAB_XI[size]
	flow_height = clampf(depth * 2.0 + float(size) * 0.4, 0.8, 4.0)
	entrain_depth = clampf(depth * 0.12, 0.03, 0.12)
	match kind:
		Kind.LOOSE:
			mu = 0.42
			xi = 600.0
			flow_height = 0.8
			entrain_depth = clampf(depth * 0.25, 0.04, 0.15)
		Kind.WET:
			mu += 0.06
			xi *= 0.45
			flow_height += 0.5
		Kind.ICE:
			mu = 0.3
			xi = 900.0
			flow_height = 1.2
			entrain_depth = 0.02


## Add a parcel of snow at a point (volume in m^3)
func add_parcel(position: Vector3, volume: float, initial_velocity: Vector3 = Vector3.ZERO) -> void:
	positions.append(position)
	velocities.append(initial_velocity)
	volumes.append(volume)
	start_volumes.append(volume)
	moving.append(1)
	_slow_time.append(0.0)
	released_volume += volume


# =============================================================================
# SIMULATION
# =============================================================================

## Advance the flow. terrain gives heights, normals and surfaces.
func step(dt: float, terrain: TerrainService) -> void:
	if finished:
		return
	time += dt
	var any_moving := false
	var top_speed := 0.0
	var count := positions.size()
	for i in range(count):
		if moving[i] == 0:
			continue
		var p := positions[i]
		var cell := terrain.get_cell_at(p)
		if cell == null or not terrain.has_terrain_at(p):
			_leave(i)
			continue
		var n := cell.normal
		var cos_theta := clampf(n.y, 0.05, 1.0)
		var friction := mu + _edge_friction(p, terrain)
		# Gravity along the slope plane
		var g_vec := Vector3(0.0, -GRAVITY, 0.0)
		var g_tan := g_vec - n * g_vec.dot(n)
		var v := velocities[i]
		v -= n * v.dot(n)
		var speed := v.length()
		var resist := friction * GRAVITY * cos_theta
		if speed < STOP_SPEED and g_tan.length() <= resist * 1.05:
			_stop(i, terrain)
			continue
		var a := g_tan
		if speed > 0.01:
			var dir := v / speed
			a -= dir * (resist + GRAVITY * speed * speed / (xi * flow_height))
			# Turbulence spreads the flow sideways a little
			var side := n.cross(dir).normalized()
			a += side * _rng.randf_range(-1.0, 1.0) * minf(speed * 0.12, 2.0)
		var new_v := v + a * dt
		# Friction cannot push the snow backwards: it stops instead
		if speed > 0.01 and new_v.dot(v) < 0.0:
			new_v = Vector3.ZERO
		v = new_v
		speed = v.length()
		var next := p + v * dt
		if not terrain.has_terrain_at(next):
			# Runs on past the edge of the mapped mountain, out of the game
			_leave(i)
			continue
		next.y = terrain.get_height_at(next) + FLOW_LIFT
		p = next
		positions[i] = p
		velocities[i] = v
		top_speed = maxf(top_speed, speed)
		if p.y < lowest.y:
			lowest = p
		# Creeping back and forth in a gully bottom is stopping
		if speed < CREEP_SPEED:
			_slow_time[i] += dt
			if _slow_time[i] > CREEP_TIME:
				_stop(i, terrain)
				continue
		else:
			_slow_time[i] = 0.0
		# Loose snow of the track joins the flow
		if kind != Kind.ICE and speed > 4.0 and TractionModel.is_snow(cell.surface_type) and cell.slope_angle > 20.0:
			var grow := entrain_depth * SWEEP_WIDTH * speed * dt
			grow = minf(grow, start_volumes[i] * MAX_GROWTH - volumes[i])
			if grow > 0.0:
				volumes[i] += grow
				entrained_volume += grow
		any_moving = true
	max_speed = maxf(max_speed, top_speed)
	if not any_moving or time >= MAX_TIME:
		for i in range(count):
			if moving[i] == 1:
				_stop(i, terrain)
		finished = true


## Run to the end in one go (recent avalanches before the run; tests)
func run_to_end(terrain: TerrainService, dt: float = 0.1) -> void:
	while not finished:
		step(dt, terrain)


## The unmapped valley floor beyond the edge, as friction near it
func _edge_friction(p: Vector3, terrain: TerrainService) -> float:
	var lo := terrain.terrain_bounds_min
	var hi := terrain.terrain_bounds_max
	var edge := minf(minf(p.x - lo.x, hi.x - p.x), minf(p.z - lo.z, hi.z - p.z))
	if edge >= EDGE_APRON:
		return 0.0
	return EDGE_FRICTION * (1.0 - clampf(edge / EDGE_APRON, 0.0, 1.0))


func _leave(i: int) -> void:
	moving[i] = 0
	velocities[i] = Vector3.ZERO
	lost_volume += volumes[i]


func _stop(i: int, _terrain: TerrainService) -> void:
	moving[i] = 0
	velocities[i] = Vector3.ZERO
	var p := positions[i]
	var gx := int(round((p.x - deposit_origin.x) / DEPOSIT_STEP))
	var gz := int(round((p.z - deposit_origin.y) / DEPOSIT_STEP))
	var volume := volumes[i]
	# Spread over a disc big enough for about DEPOSIT_THICKNESS of debris
	var area := volume * DEBRIS_COMPACTION / DEPOSIT_THICKNESS
	var reach := clampi(int(ceil(sqrt(area / PI) / DEPOSIT_STEP)), 1, 5)
	var outer := float(reach) + 1.0
	var total := 0.0
	var weights := {}
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var w := 1.0 - sqrt(float(dx * dx + dz * dz)) / outer
			if w > 0.0:
				weights[Vector2i(dx, dz)] = w
				total += w
	for offset in weights:
		var key: Vector2i = Vector2i(gx, gz) + offset
		deposit[key] = float(deposit.get(key, 0.0)) + volume * float(weights[offset]) / total
	deposited_volume += volume


# =============================================================================
# QUERIES
# =============================================================================

func is_moving() -> bool:
	return not finished


func moving_count() -> int:
	var n := 0
	for m in moving:
		n += m
	return n


## Mean velocity of the moving parcels within radius of a point, and how many
func flow_at(p: Vector3, radius: float) -> Dictionary:
	var sum := Vector3.ZERO
	var n := 0
	var r2 := radius * radius
	for i in range(positions.size()):
		if moving[i] == 0:
			continue
		var d := positions[i] - p
		d.y = 0.0
		if d.length_squared() <= r2:
			sum += velocities[i]
			n += 1
	return {"velocity": sum / float(maxi(n, 1)), "count": n}


## The leading part of the flow (lowest moving parcels): centre and velocity
func front() -> Dictionary:
	var best_y := INF
	var centre := Vector3.ZERO
	var velocity := Vector3.ZERO
	var n := 0
	for i in range(positions.size()):
		if moving[i] == 1 and positions[i].y < best_y:
			best_y = positions[i].y
	if best_y == INF:
		return {"position": lowest, "velocity": Vector3.ZERO, "count": 0}
	for i in range(positions.size()):
		if moving[i] == 1 and positions[i].y < best_y + 12.0:
			centre += positions[i]
			velocity += velocities[i]
			n += 1
	return {"position": centre / float(n), "velocity": velocity / float(n), "count": n}


## Debris depth (metres, compacted) at a deposit vertex key
func debris_depth(key: Vector2i) -> float:
	var volume: float = deposit.get(key, 0.0)
	return minf(volume * DEBRIS_COMPACTION / (DEPOSIT_STEP * DEPOSIT_STEP), MAX_DEBRIS_DEPTH)


## Debris depth at a world point (bilinear over the vertex grid)
func debris_depth_at(p: Vector2) -> float:
	var fx := (p.x - deposit_origin.x) / DEPOSIT_STEP
	var fz := (p.y - deposit_origin.y) / DEPOSIT_STEP
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var a := debris_depth(Vector2i(x0, z0))
	var b := debris_depth(Vector2i(x0 + 1, z0))
	var c := debris_depth(Vector2i(x0, z0 + 1))
	var d := debris_depth(Vector2i(x0 + 1, z0 + 1))
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


## Smooth the deposit once (a 3x3 box over the vertices it touches)
func smooth_deposit() -> void:
	var smoothed := {}
	var keys := deposit.keys()
	var touched := {}
	for key in keys:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				touched[key + Vector2i(dx, dz)] = true
	for key in touched:
		var total := 0.0
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				total += float(deposit.get(key + Vector2i(dx, dz), 0.0))
		if total > 0.0:
			smoothed[key] = total / 9.0
	deposit = smoothed


## World xz of a deposit key
func deposit_point(key: Vector2i) -> Vector2:
	return deposit_origin + Vector2(key) * DEPOSIT_STEP


## Horizontal reach and the runout angle (alpha: top of the release to the
## tip of the debris, the angle avalanche atlases are drawn with)
func runout_angle() -> float:
	if slab_points.is_empty() or lowest.y == INF:
		return 0.0
	var top := origin
	var tip := lowest
	var horizontal := Vector2(tip.x - top.x, tip.z - top.z).length()
	return rad_to_deg(atan2(top.y - tip.y, maxf(horizontal, 0.01)))
