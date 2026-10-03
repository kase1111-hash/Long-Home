class_name RouteSurvey
extends RefCounted
## Surveys the loaded mountain for the lines a guidebook would describe and
## measures each one (RouteMetrics): grade, book time, abseils, a pitch-by-
## pitch topo.
##
##   Normal route  the easiest way off (on procedural terrain, the generator's
##                 guaranteed corridor through the cliff-band ramps)
##   Face direct   the fall line: short, steep, the cliff bands abseiled
##   Snow line     stays on snow: the ski and glissade line
##   Rib           a quieter line off to one side, over steeper ground
##
## Lines are found by A* over a 4 m grid of the terrain with a cost per style;
## near-duplicates are dropped. Results are cached per terrain load.
##
## All of this lives on paper: the guidebook and the planning map. Nothing is
## drawn or marked on the mountain itself.

# =============================================================================
# CONSTANTS
# =============================================================================

enum Style { NORMAL, DIRECT, SNOW, RIB }

## Grid spacing for the line search (metres)
const GRID_STEP := 4.0
## Two lines closer than this on average are the same line (metres)
const DUPLICATE_DISTANCE := 18.0
## Douglas-Peucker tolerance for planning-map waypoints (metres)
const WAYPOINT_TOLERANCE := 3.0
## The rib keeps at least this far off the normal route where it can (metres)
const RIB_AVOID_DISTANCE := 60.0

const STYLE_IDS := {
	Style.NORMAL: "normal",
	Style.DIRECT: "direct",
	Style.SNOW: "snow",
	Style.RIB: "rib",
}

## Map ink per style (muted, printed-map colours)
const STYLE_COLORS := {
	Style.NORMAL: Color(0.12, 0.45, 0.32, 0.95),
	Style.DIRECT: Color(0.62, 0.14, 0.12, 0.95),
	Style.SNOW: Color(0.12, 0.3, 0.62, 0.95),
	Style.RIB: Color(0.42, 0.2, 0.52, 0.95),
}

const FEATURE_WORDS: Array[String] = [
	"Raven", "Grey", "Hidden", "Lantern", "Widow's", "Pilgrim's", "Shepherd's",
	"Iron", "Glass", "Long", "Quiet", "Broken", "Hermit's", "Cold", "Silver", "Ash"
]

const COMPASS_8: Array[String] = [
	"North", "North-East", "East", "South-East", "South", "South-West", "West", "North-West"
]


# =============================================================================
# DATA
# =============================================================================

## One line in the guidebook
class GuideRoute:
	var id: String = ""
	var style: int = Style.NORMAL
	var name: String = ""
	## In the printed guide (false = notes from the hut book, learnt on the mountain)
	var published: bool = true
	## Summit to base camp, ground height
	var line: PackedVector3Array = PackedVector3Array()
	## Intermediate points for the planning map (endpoints excluded)
	var waypoints: PackedVector3Array = PackedVector3Array()
	## Measured going down
	var metrics: RouteMetrics.Result = null
	## Measured going up (filled on demand by get_ascent_metrics)
	var ascent_metrics: RouteMetrics.Result = null
	var description: String = ""
	var color: Color = Color.BLACK

	func get_ascent_line() -> PackedVector3Array:
		var reversed := line.duplicate()
		reversed.reverse()
		return reversed

	func get_ascent_metrics(terrain: TerrainService) -> RouteMetrics.Result:
		if ascent_metrics == null and terrain != null:
			ascent_metrics = RouteMetrics.measure(get_ascent_line(), terrain)
		return ascent_metrics

	## Can this line be climbed on foot (no abseil pitch in the way)?
	func is_ascent_possible(terrain: TerrainService) -> bool:
		var up := get_ascent_metrics(terrain)
		return up != null and not up.ascent_blocked


## Precomputed terrain grid for the search
class Grid:
	var width: int = 0
	var height: int = 0
	var origin: Vector2 = Vector2.ZERO
	var step: float = GRID_STEP
	var heights: PackedFloat32Array = PackedFloat32Array()
	var slopes: PackedFloat32Array = PackedFloat32Array()
	var cliff: PackedFloat32Array = PackedFloat32Array()
	var snow: PackedByteArray = PackedByteArray()
	var rope: PackedByteArray = PackedByteArray()
	var valid: PackedByteArray = PackedByteArray()

	func index_of(world: Vector2) -> int:
		var x := clampi(roundi((world.x - origin.x) / step), 0, width - 1)
		var z := clampi(roundi((world.y - origin.y) / step), 0, height - 1)
		return z * width + x

	func world_of(index: int) -> Vector2:
		return origin + Vector2(float(index % width), float(index / width)) * step


static var _cache: Dictionary = {}


# =============================================================================
# PUBLIC API
# =============================================================================

## The guidebook for the loaded terrain (cached until the next terrain load)
static func survey(terrain: TerrainService) -> Array[GuideRoute]:
	var routes: Array[GuideRoute] = []
	if terrain == null or terrain.chunks.is_empty():
		return routes
	var key := "%s:%d" % [terrain.current_mountain, terrain.load_serial]
	if _cache.has(key):
		routes.assign(_cache[key])
		return routes

	var started := Time.get_ticks_msec()
	var summit := terrain.start_position
	var base := terrain.goal_position
	if summit == Vector3.ZERO or base == Vector3.ZERO:
		return routes

	var grid := _build_grid(terrain)
	var start_index := grid.index_of(Vector2(summit.x, summit.z))
	var goal_index := grid.index_of(Vector2(base.x, base.z))

	var seed_value := hash(terrain.current_mountain)
	var face := _face_name(summit, base)

	# Normal route: the generator's corridor when there is one, else the safest search
	var normal_line := PackedVector3Array()
	if terrain.corridor.size() >= 2:
		normal_line = terrain.corridor.duplicate()
	else:
		normal_line = _search(grid, start_index, goal_index, Style.NORMAL, PackedFloat32Array(), terrain)
	_pin_ends(normal_line, summit, base, terrain)

	var candidates: Array[GuideRoute] = []
	candidates.append(_make_route(Style.NORMAL, normal_line, terrain, seed_value, face, null))

	var axis := _axis_field(grid, summit, base)
	var direct_line := _search(grid, start_index, goal_index, Style.DIRECT, axis, terrain)
	_pin_ends(direct_line, summit, base, terrain)
	candidates.append(_make_route(Style.DIRECT, direct_line, terrain, seed_value, face, null))

	var avoid_normal := _distance_field(grid, normal_line)
	var snow_line := _search(grid, start_index, goal_index, Style.SNOW, avoid_normal, terrain)
	_pin_ends(snow_line, summit, base, terrain)
	candidates.append(_make_route(Style.SNOW, snow_line, terrain, seed_value, face, null))

	var avoid := avoid_normal
	if snow_line.size() >= 2:
		var avoid_snow := _distance_field(grid, snow_line)
		for i in range(avoid.size()):
			avoid[i] = minf(avoid[i], avoid_snow[i])
	var rib_line := _search(grid, start_index, goal_index, Style.RIB, avoid, terrain)
	_pin_ends(rib_line, summit, base, terrain)
	candidates.append(_make_route(Style.RIB, rib_line, terrain, seed_value, face, candidates[0]))

	for route in candidates:
		if route == null or route.line.size() < 2:
			continue
		var duplicate := false
		for kept in routes:
			if _mean_separation(route.line, kept.line) < DUPLICATE_DISTANCE:
				duplicate = true
				break
		if not duplicate:
			routes.append(route)

	_cache[key] = routes.duplicate()
	print("[RouteSurvey] %d lines on %s in %d ms: %s" % [
		routes.size(), terrain.current_mountain, Time.get_ticks_msec() - started,
		", ".join(routes.map(func(r: GuideRoute) -> String: return "%s %s %s" % [r.name, r.metrics.grade, RouteMetrics.format_minutes(r.metrics.minutes)]))
	])
	return routes


## Forget cached surveys (tests, terrain reloads with the same serial)
static func clear_cache() -> void:
	_cache.clear()


## The guidebook line this travelled path follows best, or null (fraction of
## the path within tolerance must reach min_share)
static func match_route(path: PackedVector3Array, routes: Array[GuideRoute], tolerance: float = 20.0, min_share: float = 0.7) -> GuideRoute:
	var best: GuideRoute = null
	var best_share := min_share
	var path_length := _length_xz(path)
	for route in routes:
		# A few metres near both ends is not the line: most of it must be walked
		if route.metrics != null and path_length < 0.5 * route.metrics.length:
			continue
		var share := share_near(path, route.line, tolerance)
		if share >= best_share:
			best_share = share
			best = route
	return best


## Fraction of the path (by length, sampled every few metres) within
## tolerance of the line (XZ)
static func share_near(path: PackedVector3Array, line: PackedVector3Array, tolerance: float) -> float:
	if path.is_empty() or line.size() < 2:
		return 0.0
	var dense := _densify_xz(line, 4.0)
	var samples := _densify_xz(path, 5.0) if path.size() >= 2 else PackedVector2Array([Vector2(path[0].x, path[0].z)])
	var near := 0
	var counted := 0
	var stride := maxi(1, samples.size() / 300)
	for i in range(0, samples.size(), stride):
		counted += 1
		if _distance_to_points(samples[i], dense) <= tolerance:
			near += 1
	return float(near) / float(maxi(counted, 1))


# =============================================================================
# GRID
# =============================================================================

static func _build_grid(terrain: TerrainService) -> Grid:
	var grid := Grid.new()
	var bmin := terrain.terrain_bounds_min
	var bmax := terrain.terrain_bounds_max
	grid.origin = Vector2(bmin.x, bmin.z) + Vector2.ONE * (GRID_STEP * 0.5)
	grid.width = maxi(2, int(floor((bmax.x - bmin.x) / GRID_STEP)))
	grid.height = maxi(2, int(floor((bmax.z - bmin.z) / GRID_STEP)))
	var count := grid.width * grid.height
	grid.heights.resize(count)
	grid.slopes.resize(count)
	grid.cliff.resize(count)
	grid.snow.resize(count)
	grid.rope.resize(count)
	grid.valid.resize(count)
	for z in range(grid.height):
		for x in range(grid.width):
			var i := z * grid.width + x
			var world := grid.origin + Vector2(x, z) * GRID_STEP
			var cell := terrain.get_cell_at(Vector3(world.x, 0.0, world.y))
			if cell == null:
				grid.valid[i] = 0
				continue
			grid.valid[i] = 1
			grid.heights[i] = terrain.get_height_at(Vector3(world.x, 0.0, world.y))
			grid.slopes[i] = cell.slope_angle
			grid.cliff[i] = cell.distance_to_cliff
			grid.snow[i] = 1 if TractionModel.is_snow(cell.surface_type) else 0
			grid.rope[i] = 1 if cell.requires_rope else 0
	return grid


## Per-metre cost of standing on node i for a style (before edge terms)
static func _node_cost(grid: Grid, i: int, style: int) -> float:
	var slope := grid.slopes[i]
	var cliff_distance := grid.cliff[i]
	var rope := grid.rope[i] == 1
	var cost := 1.0
	match style:
		Style.NORMAL:
			if slope > 18.0:
				cost += (slope - 18.0) * 0.08
			if slope > 28.0:
				cost += (slope - 28.0) * 0.6
			if slope > 35.0:
				cost += 15.0
			if rope:
				cost += 80.0
			if cliff_distance < 15.0:
				cost += (15.0 - cliff_distance) * 0.25
			if grid.snow[i] == 0:
				cost += 0.2
		Style.DIRECT:
			if slope > 35.0:
				cost += 0.8
			if rope:
				cost += 4.0
			if cliff_distance < 6.0:
				cost += 0.3
		Style.SNOW:
			# Consistent 28-42 deg snow, well clear of the cliffs: the ski line
			if grid.snow[i] == 0:
				cost += 5.0
			if slope < 20.0:
				cost += 1.5
			elif slope < 28.0:
				cost += 0.6
			if slope > 42.0:
				cost += 12.0
			if rope:
				cost += 100.0
			if cliff_distance < 25.0:
				cost += (25.0 - cliff_distance) * 0.5
		Style.RIB:
			if slope > 25.0:
				cost += (slope - 25.0) * 0.12
			if slope > 35.0:
				cost += 6.0
			if rope:
				cost += 60.0
			if cliff_distance < 10.0:
				cost += (10.0 - cliff_distance) * 0.2
	return cost


## Cost for climbing back uphill on the way down, per metre of rise
static func _uphill_weight(style: int) -> float:
	return 3.0 if style == Style.DIRECT else 6.0


## Extra per-metre cost from a node's field value (avoid / axis distance)
static func _field_cost(style: int, value: float) -> float:
	match style:
		Style.DIRECT:
			# The fall line: drift from the straight summit-base axis costs
			return value * 0.025
		Style.SNOW:
			return maxf(0.0, 40.0 - value) * 0.04
		Style.RIB:
			return maxf(0.0, RIB_AVOID_DISTANCE - value) * 0.08
	return 0.0


## A* from start to goal; returns the line in world space (y = ground).
## field (optional, one value per node) feeds _field_cost: distance from
## lines to keep away from, or from the fall-line axis.
static func _search(grid: Grid, start: int, goal: int, style: int, field: PackedFloat32Array, terrain: TerrainService) -> PackedVector3Array:
	var count := grid.width * grid.height
	var node_cost := PackedFloat32Array()
	node_cost.resize(count)
	var use_field := field.size() == count
	for i in range(count):
		if grid.valid[i] == 0:
			node_cost[i] = -1.0
			continue
		var c := _node_cost(grid, i, style)
		if use_field:
			c += _field_cost(style, field[i])
		node_cost[i] = c

	var g_score := PackedFloat32Array()
	g_score.resize(count)
	g_score.fill(INF)
	var came_from := PackedInt32Array()
	came_from.resize(count)
	came_from.fill(-1)
	var closed := PackedByteArray()
	closed.resize(count)

	var width := grid.width
	var step := grid.step
	var diag := step * sqrt(2.0)
	var offsets: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(1, 1, 1), Vector3i(-1, 1, 1), Vector3i(1, -1, 1), Vector3i(-1, -1, 1),
	]
	var uphill := _uphill_weight(style)
	# Edge grade bands: a 4 m step can hide a cliff step between two nodes
	var steep_grade := tan(deg_to_rad(35.0))
	var rope_grade := tan(deg_to_rad(50.0))
	var steep_extra := 0.8 if style == Style.DIRECT else 15.0
	var rope_extra := 4.0 if style == Style.DIRECT else (60.0 if style == Style.RIB else 80.0)
	if style == Style.SNOW:
		rope_extra = 100.0
		steep_extra = 12.0

	var goal_world := grid.world_of(goal)
	var heap_nodes := PackedInt32Array()
	var heap_keys := PackedFloat32Array()
	g_score[start] = 0.0
	_heap_push(heap_nodes, heap_keys, start, grid.world_of(start).distance_to(goal_world))

	while not heap_nodes.is_empty():
		var current := _heap_pop(heap_nodes, heap_keys)
		if closed[current] == 1:
			continue
		if current == goal:
			break
		closed[current] = 1
		var cx := current % width
		var cz := current / width
		var ch := grid.heights[current]
		var cg := g_score[current]
		for offset in offsets:
			var nx := cx + offset.x
			var nz := cz + offset.y
			if nx < 0 or nz < 0 or nx >= width or nz >= grid.height:
				continue
			var next := nz * width + nx
			if closed[next] == 1:
				continue
			var base_cost := node_cost[next]
			if base_cost < 0.0:
				continue
			var length := diag if offset.z == 1 else step
			var dy := grid.heights[next] - ch
			var grade := absf(dy) / length
			var cost := length * base_cost
			if grade > rope_grade:
				cost += length * rope_extra
			elif grade > steep_grade:
				cost += length * steep_extra
			if dy > 0.0:
				cost += dy * uphill
			var tentative := cg + cost
			if tentative < g_score[next]:
				g_score[next] = tentative
				came_from[next] = current
				_heap_push(heap_nodes, heap_keys, next, tentative + grid.world_of(next).distance_to(goal_world))

	if came_from[goal] == -1 and goal != start:
		return PackedVector3Array()

	var indices := PackedInt32Array()
	var node := goal
	while node != -1:
		indices.append(node)
		node = came_from[node]
	indices.reverse()

	var flat := PackedVector2Array()
	for index in indices:
		flat.append(grid.world_of(index))
	flat = _chaikin(flat, 2)
	var line := PackedVector3Array()
	for p in flat:
		line.append(Vector3(p.x, terrain.get_height_at(Vector3(p.x, 0.0, p.y)), p.y))
	return line


static func _heap_push(nodes: PackedInt32Array, keys: PackedFloat32Array, node: int, key: float) -> void:
	nodes.append(node)
	keys.append(key)
	var i := nodes.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if keys[parent] <= keys[i]:
			break
		var tn := nodes[parent]
		nodes[parent] = nodes[i]
		nodes[i] = tn
		var tk := keys[parent]
		keys[parent] = keys[i]
		keys[i] = tk
		i = parent


static func _heap_pop(nodes: PackedInt32Array, keys: PackedFloat32Array) -> int:
	var top := nodes[0]
	var last := nodes.size() - 1
	nodes[0] = nodes[last]
	keys[0] = keys[last]
	nodes.resize(last)
	keys.resize(last)
	var size := last
	var i := 0
	while true:
		var left := 2 * i + 1
		if left >= size:
			break
		var smallest := left
		var right := left + 1
		if right < size and keys[right] < keys[left]:
			smallest = right
		if keys[i] <= keys[smallest]:
			break
		var tn := nodes[smallest]
		nodes[smallest] = nodes[i]
		nodes[i] = tn
		var tk := keys[smallest]
		keys[smallest] = keys[i]
		keys[i] = tk
		i = smallest
	return top


## Distance (metres) of every grid node from the straight summit-base axis
static func _axis_field(grid: Grid, summit: Vector3, base: Vector3) -> PackedFloat32Array:
	var count := grid.width * grid.height
	var field := PackedFloat32Array()
	field.resize(count)
	var a := Vector2(summit.x, summit.z)
	var b := Vector2(base.x, base.z)
	for i in range(count):
		field[i] = _point_segment_distance(grid.world_of(i), a, b)
	return field


## Chamfer distance (metres) from every grid node to a line
static func _distance_field(grid: Grid, line: PackedVector3Array) -> PackedFloat32Array:
	var count := grid.width * grid.height
	var field := PackedFloat32Array()
	field.resize(count)
	field.fill(1.0e9)
	var dense := _densify_xz(line, grid.step * 0.5)
	for p in dense:
		field[grid.index_of(p)] = 0.0
	var a := grid.step
	var b := grid.step * sqrt(2.0)
	var w := grid.width
	var h := grid.height
	for z in range(h):
		for x in range(w):
			var i := z * w + x
			var v := field[i]
			if x > 0:
				v = minf(v, field[i - 1] + a)
			if z > 0:
				v = minf(v, field[i - w] + a)
				if x > 0:
					v = minf(v, field[i - w - 1] + b)
				if x < w - 1:
					v = minf(v, field[i - w + 1] + b)
			field[i] = v
	for z in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := z * w + x
			var v := field[i]
			if x < w - 1:
				v = minf(v, field[i + 1] + a)
			if z < h - 1:
				v = minf(v, field[i + w] + a)
				if x < w - 1:
					v = minf(v, field[i + w + 1] + b)
				if x > 0:
					v = minf(v, field[i + w - 1] + b)
			field[i] = v
	return field


# =============================================================================
# ROUTE ASSEMBLY
# =============================================================================

static func _make_route(style: int, line: PackedVector3Array, terrain: TerrainService, seed_value: int, face: String, normal: GuideRoute) -> GuideRoute:
	if line.size() < 2:
		return null
	var route := GuideRoute.new()
	route.style = style
	route.id = STYLE_IDS[style]
	route.line = line
	route.color = STYLE_COLORS[style]
	route.published = style == Style.NORMAL or style == Style.DIRECT
	route.metrics = RouteMetrics.measure(line, terrain)
	route.waypoints = simplify(line, WAYPOINT_TOLERANCE)
	route.name = _route_name(style, route, seed_value, face, normal)
	route.description = _describe(route, normal)
	return route


## Douglas-Peucker in XZ; returns the kept interior points (endpoints dropped,
## they are the summit and base camp on the planning map)
static func simplify(line: PackedVector3Array, tolerance: float) -> PackedVector3Array:
	var keep := PackedByteArray()
	keep.resize(line.size())
	if line.size() < 3:
		return PackedVector3Array()
	keep[0] = 1
	keep[line.size() - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, line.size() - 1)]
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var a := Vector2(line[span.x].x, line[span.x].z)
		var b := Vector2(line[span.y].x, line[span.y].z)
		var worst := -1.0
		var worst_index := -1
		for i in range(span.x + 1, span.y):
			var p := Vector2(line[i].x, line[i].z)
			var d := _point_segment_distance(p, a, b)
			if d > worst:
				worst = d
				worst_index = i
		if worst > tolerance and worst_index > 0:
			keep[worst_index] = 1
			stack.append(Vector2i(span.x, worst_index))
			stack.append(Vector2i(worst_index, span.y))
	var points := PackedVector3Array()
	for i in range(1, line.size() - 1):
		if keep[i] == 1:
			points.append(line[i])
	return points


static func _pin_ends(line: PackedVector3Array, summit: Vector3, base: Vector3, terrain: TerrainService) -> void:
	if line.size() < 2:
		return
	var s := summit
	s.y = terrain.get_height_at(s)
	var g := base
	g.y = terrain.get_height_at(g)
	line[0] = s
	line[line.size() - 1] = g


static func _route_name(style: int, route: GuideRoute, seed_value: int, face: String, normal: GuideRoute) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + style * 7919
	var word := FEATURE_WORDS[rng.randi_range(0, FEATURE_WORDS.size() - 1)]
	match style:
		Style.NORMAL:
			return "Normal Route"
		Style.DIRECT:
			return "%s Face Direct" % face
		Style.SNOW:
			if route.metrics != null and route.metrics.sustained_slope >= 36.0:
				return "%s Couloir" % word
			return "%s Snowfield" % word
		Style.RIB:
			var side := _side_name(route.line, normal.line if normal != null else PackedVector3Array())
			return "%s %s" % [side, "Spur" if rng.randf() < 0.4 else "Rib"]
	return "Unnamed line"


static func _describe(route: GuideRoute, normal: GuideRoute) -> String:
	var m := route.metrics
	var lead := ""
	match route.style:
		Style.NORMAL:
			lead = "The way most parties come down. It finds the easiest ground on the mountain"
			if m.rappels == 0:
				lead += " and slips through the cliff bands on snow ramps. Long, but never hard."
			else:
				lead += ", though the rope still comes out."
		Style.DIRECT:
			if m.rappels > 0:
				lead = "Straight down the fall line. Short and committing: the cliff bands are abseiled, not avoided, and once the rope is pulled there is no way back up."
			else:
				lead = "Straight down the fall line: steeper than the normal route and far shorter."
		Style.SNOW:
			lead = "Keeps to snow the whole way: the ski and glissade line. Fast when the snow is good; know where it runs out before you commit."
		Style.RIB:
			lead = "A quieter line off to one side of the face, over steeper ground and well away from the normal route."
	var facts: Array[String] = []
	if m.rappels > 0:
		facts.append("%d abseil%s (longest %d m): %d m rope minimum" % [m.rappels, "" if m.rappels == 1 else "s", roundi(m.longest_rappel), roundi(m.min_rope_length)])
	if m.crampons_advised:
		facts.append("crampons")
	if m.exposure > 0.15:
		facts.append("exposed")
	if m.snow_fraction > 0.85 and m.rappels == 0 and m.max_slope < 45.0:
		facts.append("skiable")
	if not facts.is_empty():
		var joined := ", ".join(facts)
		lead += " " + joined.substr(0, 1).to_upper() + joined.substr(1) + "."
	return lead


## Compass name of the face (the direction it looks, summit to base)
static func _face_name(summit: Vector3, base: Vector3) -> String:
	var d := Vector2(base.x - summit.x, base.z - summit.z)
	return _compass(d)


## Which side of the normal route a line keeps to, as a compass word
static func _side_name(line: PackedVector3Array, normal: PackedVector3Array) -> String:
	if line.size() < 2 or normal.size() < 2:
		return "East"
	var along := Vector2(line[line.size() - 1].x - line[0].x, line[line.size() - 1].z - line[0].z).normalized()
	var offset := Vector2.ZERO
	var samples := 0
	var dense := _densify_xz(normal, 8.0)
	for i in range(0, line.size(), maxi(1, line.size() / 40)):
		var p := Vector2(line[i].x, line[i].z)
		var nearest := _nearest_point(p, dense)
		offset += p - nearest
		samples += 1
	offset /= float(maxi(samples, 1))
	# Remove the along-face part: what is left points to the side
	offset -= along * offset.dot(along)
	if offset.length() < 0.01:
		offset = Vector2(-along.y, along.x)
	return _compass(offset)


## 8-point compass word for a horizontal direction (-Z is north, +X east)
static func _compass(direction: Vector2) -> String:
	var bearing := fposmod(rad_to_deg(atan2(direction.x, -direction.y)), 360.0)
	var index := int(round(bearing / 45.0)) % 8
	return COMPASS_8[index]


# =============================================================================
# GEOMETRY HELPERS
# =============================================================================

static func _chaikin(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var current := points
	for _k in range(iterations):
		if current.size() < 3:
			return current
		var next := PackedVector2Array()
		next.append(current[0])
		for i in range(current.size() - 1):
			var a := current[i]
			var b := current[i + 1]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		next.append(current[current.size() - 1])
		current = next
	return current


static func _densify_xz(line: PackedVector3Array, spacing: float) -> PackedVector2Array:
	var dense := PackedVector2Array()
	for i in range(line.size() - 1):
		var a := Vector2(line[i].x, line[i].z)
		var b := Vector2(line[i + 1].x, line[i + 1].z)
		var steps := maxi(1, int(ceil(a.distance_to(b) / spacing)))
		for k in range(steps):
			dense.append(a.lerp(b, float(k) / float(steps)))
	if not line.is_empty():
		dense.append(Vector2(line[line.size() - 1].x, line[line.size() - 1].z))
	return dense


static func _length_xz(line: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, line.size()):
		length += Vector2(line[i].x - line[i - 1].x, line[i].z - line[i - 1].z).length()
	return length


static func _distance_to_points(p: Vector2, points: PackedVector2Array) -> float:
	var best := INF
	for q in points:
		best = minf(best, p.distance_squared_to(q))
	return sqrt(best)


static func _nearest_point(p: Vector2, points: PackedVector2Array) -> Vector2:
	var best := INF
	var best_point := p
	for q in points:
		var d := p.distance_squared_to(q)
		if d < best:
			best = d
			best_point = q
	return best_point


static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Mean distance from line a's points to line b (XZ), sampled
static func _mean_separation(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var dense := _densify_xz(b, 6.0)
	var total := 0.0
	var count := 0
	for i in range(0, a.size(), maxi(1, a.size() / 60)):
		total += _distance_to_points(Vector2(a[i].x, a[i].z), dense)
		count += 1
	return total / float(maxi(count, 1))
