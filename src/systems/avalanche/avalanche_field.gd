class_name AvalancheField
extends RefCounted
## Where today's snowpack is unstable: the day's avalanche problems laid
## over the terrain on a 4 m grid.
##
## A slope can release when it is steep enough (from about 30 deg, most often
## 35-45 deg; much steeper slopes sluff often and hold less), lies on an
## aspect and at an elevation the problem lives on, is snow (not rock, scree
## or bare glacier ice) and is not anchored by dense forest. Convex rolls,
## where the slab is in tension, are more sensitive. The snowpack also varies
## from place to place (a noise field): two slopes that look the same rarely
## are.
##
## Dry problems are fixed for the day. Wet problems are stored apart and
## scaled by the sun and the air temperature while the day runs
## (AvalancheSystem). pack holds the slab problems without the steepness
## term: a collapsing weak layer ("whumpf") is felt on gentle ground too.

# =============================================================================
# CONSTANTS
# =============================================================================

const STEP := 4.0
## No release below this, nor above the upper limit (degrees)
const MIN_RELEASE_SLOPE := 28.0
const MAX_RELEASE_SLOPE := 62.0
## Start zones counted for natural releases
const START_ZONE_SLOPE := 30.0
const START_ZONE_INSTABILITY := 0.12
## Glacier steeper than this sheds serac falls
const ICEFALL_SLOPE := 32.0
const NO_PROBLEM := 255

# =============================================================================
# DATA
# =============================================================================

var conditions: AvalancheConditions = null
var grid_min: Vector2 = Vector2.ZERO
var width: int = 0
var height: int = 0

var slope: PackedFloat32Array = PackedFloat32Array()
var elevation: PackedFloat32Array = PackedFloat32Array()
var downhill: PackedVector2Array = PackedVector2Array()
var aspect: PackedByteArray = PackedByteArray()
var snow: PackedByteArray = PackedByteArray()
var forest: PackedFloat32Array = PackedFloat32Array()

## Instability (0-1) from the dry problems, and the wet problems before warmth
var dry: PackedFloat32Array = PackedFloat32Array()
var wet: PackedFloat32Array = PackedFloat32Array()
var dry_problem: PackedByteArray = PackedByteArray()
var wet_problem: PackedByteArray = PackedByteArray()
## Slab problems on any snow, without the steepness term (collapses, cracks)
var pack: PackedFloat32Array = PackedFloat32Array()
var pack_problem: PackedByteArray = PackedByteArray()

## Steep, unstable cells (natural releases start here) and icefall cells
var start_cells: PackedInt32Array = PackedInt32Array()
var icefall_cells: PackedInt32Array = PackedInt32Array()


# =============================================================================
# BUILDING
# =============================================================================

static func build(terrain: TerrainService, today: AvalancheConditions) -> AvalancheField:
	var field := AvalancheField.new()
	field.conditions = today
	var bmin := terrain.terrain_bounds_min
	var bmax := terrain.terrain_bounds_max
	field.grid_min = Vector2(bmin.x, bmin.z)
	field.width = int(floor((bmax.x - bmin.x) / STEP)) + 1
	field.height = int(floor((bmax.z - bmin.z) / STEP)) + 1
	var count := field.width * field.height
	field.slope.resize(count)
	field.elevation.resize(count)
	field.forest.resize(count)
	field.dry.resize(count)
	field.wet.resize(count)
	field.pack.resize(count)
	field.downhill.resize(count)
	field.aspect.resize(count)
	field.snow.resize(count)
	field.dry_problem.resize(count)
	field.wet_problem.resize(count)
	field.pack_problem.resize(count)
	field._build_forest(terrain)

	var noise := FastNoiseLite.new()
	noise.seed = today.seed if today != null else 0
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / 45.0
	noise.fractal_octaves = 2

	for gz in range(field.height):
		for gx in range(field.width):
			var i := gz * field.width + gx
			var p := field.world_of(i)
			var cell := terrain.get_cell_at(Vector3(p.x, 0.0, p.y))
			field.dry_problem[i] = NO_PROBLEM
			field.wet_problem[i] = NO_PROBLEM
			field.pack_problem[i] = NO_PROBLEM
			if cell == null:
				continue
			field.slope[i] = cell.slope_angle
			field.elevation[i] = cell.elevation
			field.downhill[i] = Vector2(cell.slope_direction.x, cell.slope_direction.z)
			field.aspect[i] = AvalancheConditions.aspect_of(field.downhill[i]) if field.downhill[i].length_squared() > 0.0001 else 0
			var is_snow := TractionModel.is_snow(cell.surface_type) and cell.surface_type != GameEnums.SurfaceType.ICE
			field.snow[i] = 1 if is_snow else 0
			if cell.is_glacier and cell.slope_angle > ICEFALL_SLOPE:
				field.icefall_cells.append(i)
			if not is_snow or today == null:
				continue
			field._rate_cell(i, cell, noise)

	for i in range(count):
		if field.slope[i] >= START_ZONE_SLOPE and maxf(field.dry[i], field.wet[i]) >= START_ZONE_INSTABILITY:
			field.start_cells.append(i)
	return field


## Trees per cell neighbourhood: dense forest anchors the snowpack
func _build_forest(terrain: TerrainService) -> void:
	if terrain.scatter == null:
		return
	var counts := PackedFloat32Array()
	counts.resize(width * height)
	for obj in terrain.scatter.objects:
		if not obj.is_tree() or obj.size < 2.0:
			continue
		var gx := int(round((obj.position.x - grid_min.x) / STEP))
		var gz := int(round((obj.position.z - grid_min.y) / STEP))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var x := gx + dx
				var z := gz + dz
				if x < 0 or z < 0 or x >= width or z >= height:
					continue
				counts[z * width + x] += 1.0 if dx == 0 and dz == 0 else 0.5
	for i in range(counts.size()):
		forest[i] = clampf(counts[i] / 5.0, 0.0, 1.0)


func _rate_cell(i: int, cell: TerrainCell, noise: FastNoiseLite) -> void:
	var p := world_of(i)
	var band := conditions.band_of(cell.elevation)
	var sector: int = aspect[i]
	var angle := cell.slope_angle
	# Spatial variability: the same-looking slope is not the same snowpack
	var variability := 1.0 + 0.45 * noise.get_noise_2d(p.x, p.y)
	# Convex rolls hold the slab in tension; dense forest anchors it
	var shape := 1.0 + clampf(cell.curvature * 8.0, -0.15, 0.3)
	var anchored := 1.0 - 0.85 * forest[i]
	var best_dry := 0.0
	var best_wet := 0.0
	var best_pack := 0.0
	for k in range(conditions.problems.size()):
		var problem: AvalancheConditions.AvalancheProblem = conditions.problems[k]
		if not problem.covers(sector, band):
			continue
		var steep := steepness_factor(angle, problem.type)
		var value := problem.likelihood * steep * variability * shape * anchored
		if problem.is_wet():
			if value > best_wet:
				best_wet = value
				wet_problem[i] = k
		elif value > best_dry:
			best_dry = value
			dry_problem[i] = k
		if problem.is_slab() and not problem.is_wet():
			var slab := problem.likelihood * variability * anchored
			if slab > best_pack:
				best_pack = slab
				pack_problem[i] = k
	dry[i] = clampf(best_dry, 0.0, 1.0)
	wet[i] = clampf(best_wet, 0.0, 1.0)
	pack[i] = clampf(best_pack, 0.0, 1.0)


## How readily a slope of this angle releases (0-1) for a kind of problem
static func steepness_factor(angle: float, problem_type: int = AvalancheConditions.ProblemType.STORM_SLAB) -> float:
	if angle < MIN_RELEASE_SLOPE or angle > MAX_RELEASE_SLOPE:
		return 0.0
	match problem_type:
		AvalancheConditions.ProblemType.LOOSE_DRY:
			# Cold loose snow runs off the steepest slopes
			return smoothstep(36.0, 42.0, angle) * (1.0 - smoothstep(55.0, MAX_RELEASE_SLOPE, angle))
		AvalancheConditions.ProblemType.WET_LOOSE, AvalancheConditions.ProblemType.WET_SLAB:
			# Wet snow moves on lower angles
			return smoothstep(MIN_RELEASE_SLOPE, 34.0, angle) * (1.0 - smoothstep(50.0, MAX_RELEASE_SLOPE, angle))
	if angle < 36.0:
		return smoothstep(MIN_RELEASE_SLOPE, 36.0, angle)
	if angle <= 45.0:
		return 1.0
	if angle <= 55.0:
		return lerpf(1.0, 0.45, (angle - 45.0) / 10.0)
	return lerpf(0.45, 0.0, (angle - 55.0) / (MAX_RELEASE_SLOPE - 55.0))


# =============================================================================
# QUERIES
# =============================================================================

func world_of(i: int) -> Vector2:
	return grid_min + Vector2(float(i % width), float(i / width)) * STEP


func index_of(p: Vector2) -> int:
	var gx := clampi(int(round((p.x - grid_min.x) / STEP)), 0, width - 1)
	var gz := clampi(int(round((p.y - grid_min.y) / STEP)), 0, height - 1)
	return gz * width + gx


func contains(p: Vector2) -> bool:
	var fx := (p.x - grid_min.x) / STEP
	var fz := (p.y - grid_min.y) / STEP
	return fx >= -0.5 and fz >= -0.5 and fx <= float(width) - 0.5 and fz <= float(height) - 0.5


## Instability of a cell now; wet_activity (0-1.5) scales the wet problems
func instability(i: int, wet_activity: float) -> float:
	return clampf(maxf(dry[i], wet[i] * wet_activity), 0.0, 1.0)


## The problem driving a cell's instability now (null when stable)
func problem_now(i: int, wet_activity: float) -> AvalancheConditions.AvalancheProblem:
	if conditions == null:
		return null
	var k := int(dry_problem[i])
	if wet[i] * wet_activity > dry[i]:
		k = int(wet_problem[i])
	if k == NO_PROBLEM or k >= conditions.problems.size():
		return null
	return conditions.problems[k]


func pack_problem_at(i: int) -> AvalancheConditions.AvalancheProblem:
	var k := int(pack_problem[i])
	if conditions == null or k == NO_PROBLEM or k >= conditions.problems.size():
		return null
	return conditions.problems[k]


## The slab that breaks around a trigger: cells spreading out from it, up
## to the crown and across the slope, over steep snow of the same problem,
## until the target area is reached or the slope runs out. Uphill spreads
## more easily than downhill (the crown forms above the trigger).
func slab_area(trigger: int, target_area: float, wet_activity: float) -> PackedInt32Array:
	var area := PackedInt32Array()
	if trigger < 0 or snow[trigger] == 0:
		return area
	var trigger_value := maxf(instability(trigger, wet_activity), 0.05)
	var limit := sqrt(target_area) * 1.25
	var origin := world_of(trigger)
	var cost := {trigger: 0.0}
	var done := {}
	var frontier: Array[int] = [trigger]
	var cells_wanted := maxi(1, int(ceil(target_area / (STEP * STEP))))
	while not frontier.is_empty() and area.size() < cells_wanted:
		# Cheapest frontier cell next (small sets: a linear scan is fine)
		var best := 0
		for k in range(1, frontier.size()):
			if cost[frontier[k]] < cost[frontier[best]]:
				best = k
		var current: int = frontier[best]
		frontier.remove_at(best)
		if done.has(current):
			continue
		done[current] = true
		area.append(current)
		var cx := current % width
		var cz := current / width
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var nx := cx + dx
				var nz := cz + dz
				if nx < 0 or nz < 0 or nx >= width or nz >= height:
					continue
				var n := nz * width + nx
				if done.has(n) or snow[n] == 0:
					continue
				if slope[n] < MIN_RELEASE_SLOPE - 2.0 or slope[n] > MAX_RELEASE_SLOPE:
					continue
				if instability(n, wet_activity) < 0.3 * trigger_value:
					continue
				if world_of(n).distance_to(origin) > limit:
					continue
				var step_length := STEP * (1.4142 if dx != 0 and dz != 0 else 1.0)
				var uphill := elevation[n] > elevation[current]
				var c: float = cost[current] + step_length * (1.0 if uphill else 1.7)
				if c < cost.get(n, INF):
					cost[n] = c
					frontier.append(n)
	return area


## Cells of an area whose uphill neighbour is outside it: the crown
func crown_of(area: PackedInt32Array) -> PackedInt32Array:
	var inside := {}
	for i in area:
		inside[i] = true
	var crown := PackedInt32Array()
	for i in area:
		var up := -downhill[i]
		if up.length_squared() < 0.0001:
			continue
		var above := index_of(world_of(i) + up.normalized() * STEP)
		if not inside.has(above):
			crown.append(i)
	return crown


## Pick a natural start zone, weighted by instability squared
func pick_start(rng: RandomNumberGenerator, wet_activity: float) -> int:
	var total := 0.0
	for i in start_cells:
		var v := instability(i, wet_activity)
		total += v * v
	if total <= 0.0:
		return -1
	var pick := rng.randf() * total
	for i in start_cells:
		var v := instability(i, wet_activity)
		pick -= v * v
		if pick <= 0.0:
			return i
	return start_cells[start_cells.size() - 1]


## Fraction of the steep snow (>= 30 deg) that is unstable today
func unstable_share() -> float:
	var steep := 0
	for i in range(slope.size()):
		if snow[i] == 1 and slope[i] >= START_ZONE_SLOPE:
			steep += 1
	return float(start_cells.size()) / float(maxi(steep, 1))
