class_name GlacierField
extends RefCounted
## A glacier on the mountain and its crevasses, as built by
## ProceduralMountainGenerator.
##
## The glacier is a tongue of ice lying in the flank beside the normal route:
## a smooth surface flowing down the fall line, icefalls where the rock steps
## are, lateral moraines along its edges. Below the equilibrium line
## (ela_elevation) it is bare ice; above, snow-covered.
##
## Crevasses open where the ice is stretched: transverse rows across the
## glacier where it steepens (icefalls), chevrons at the margins where the
## edges drag, and the bergschrund at its head. Open ones are cut into the
## terrain; bridged ones are hidden under snow with only a faint sag, and a
## bridge can give way under the climber (CrevasseSystem), at which point the
## terrain is carved open (TerrainService.carve_crevasse_section).

# =============================================================================
# DATA
# =============================================================================

enum CrevasseKind { TRANSVERSE, MARGINAL, BERGSCHRUND }

## Half-length of a bridge section that gives way at once (metres)
const SECTION_HALF_LENGTH := 3.5

class Crevasse:
	var id: int = 0
	var kind: int = 0
	## Centre line in world xz (2-3 points)
	var points: PackedVector2Array = PackedVector2Array()
	## Height of the glacier surface at each point before any carving (the lip)
	var lip_heights: PackedFloat32Array = PackedFloat32Array()
	## Width at the lip (metres)
	var width: float = 2.0
	## Depth of the open slot (metres below the lip)
	var depth: float = 10.0
	## Hidden under a snow bridge
	var bridged: bool = false
	## Bridge strength, 0 (a crust over nothing) to 1 (metres of firm snow)
	var bridge_strength: float = 1.0
	## Bridge sections that have given way (centre points, world xz)
	var collapsed: PackedVector2Array = PackedVector2Array()
	## Found by probing
	var probed: bool = false

	## Horizontal distance from a point to the centre line, and the parameter
	## along it ([distance, t, segment index])
	func locate(p: Vector2) -> Vector3:
		var best := INF
		var best_t := 0.0
		var best_seg := 0
		for i in range(points.size() - 1):
			var a := points[i]
			var b := points[i + 1]
			var ab := b - a
			var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			if d < best:
				best = d
				best_t = t
				best_seg = i
		return Vector3(best, best_t, best_seg)

	func distance_to(p: Vector2) -> float:
		return locate(p).x

	## Is a point over the slot (within the lip, between the ends)?
	func contains(p: Vector2, margin: float = 0.0) -> bool:
		var where := locate(p)
		if where.x > width * 0.5 + margin:
			return false
		# Ends taper: the last metre at each end is closed
		var seg := int(where.z)
		var t := where.y
		if seg == 0 and t <= 0.0:
			return false
		if seg == points.size() - 2 and t >= 1.0:
			return false
		return true

	## Lip height at the point of the centre line nearest p
	func lip_height_at(p: Vector2) -> float:
		var where := locate(p)
		var seg := int(where.z)
		if lip_heights.size() < points.size():
			return 0.0
		return lerpf(lip_heights[seg], lip_heights[seg + 1], where.y)

	## Direction along the slot (unit, xz)
	func direction_at(p: Vector2) -> Vector2:
		var seg := int(locate(p).z)
		return (points[seg + 1] - points[seg]).normalized()

	func length() -> float:
		var total := 0.0
		for i in range(points.size() - 1):
			total += points[i].distance_to(points[i + 1])
		return total

	## Is the bridge (if any) still standing over this point?
	func is_bridged_at(p: Vector2) -> bool:
		if not bridged:
			return false
		for c in collapsed:
			if c.distance_to(p) < GlacierField.SECTION_HALF_LENGTH:
				return false
		return true


## Centre line from the head to the snout (world xz) and half widths
var centreline: PackedVector2Array = PackedVector2Array()
var half_widths: PackedFloat32Array = PackedFloat32Array()
## Flow direction (down-glacier, unit xz)
var flow_direction: Vector2 = Vector2.RIGHT
## Equilibrium line: bare ice below, snow above (metres)
var ela_elevation: float = 0.0
var head_elevation: float = 0.0
var snout_elevation: float = 0.0
var crevasses: Array[Crevasse] = []

## Coverage (0-1) and moraine height (metres) on the terrain sample grid
var grid_size: int = 0
var grid_min: Vector2 = Vector2.ZERO
var cell_size: float = 2.0
var weights: PackedFloat32Array = PackedFloat32Array()
var moraine: PackedFloat32Array = PackedFloat32Array()

const BUCKET := 16.0
var _buckets: Dictionary = {}


# =============================================================================
# QUERIES
# =============================================================================

## Glacier coverage at a world point (0 off the ice, 1 on it)
func weight_at(p: Vector2) -> float:
	return _sample(weights, p)


## Lateral moraine height at a world point (metres of rubble ridge)
func moraine_at(p: Vector2) -> float:
	return _sample(moraine, p)


func is_on_glacier(p: Vector2) -> bool:
	return weight_at(p) >= 0.5


## Crevasses whose centre line passes within radius of a point
func crevasses_near(p: Vector2, radius: float) -> Array[Crevasse]:
	var found: Array[Crevasse] = []
	var seen := {}
	var reach := int(ceil(radius / BUCKET))
	var key := _key(p)
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			for index in _buckets.get(key + Vector2i(dx, dz), []):
				if seen.has(index):
					continue
				seen[index] = true
				var crevasse: Crevasse = crevasses[index]
				if crevasse.distance_to(p) <= radius + crevasse.width * 0.5:
					found.append(crevasse)
	return found


## The crevasse whose slot a point is over, or null
func crevasse_at(p: Vector2, margin: float = 0.0) -> Crevasse:
	for crevasse in crevasses_near(p, margin + 4.0):
		if crevasse.contains(p, margin):
			return crevasse
	return null


## Glacier length along the centre line (metres)
func get_length() -> float:
	var total := 0.0
	for i in range(1, centreline.size()):
		total += centreline[i].distance_to(centreline[i - 1])
	return total


func count_open() -> int:
	var n := 0
	for crevasse in crevasses:
		if not crevasse.bridged:
			n += 1
	return n


func count_bridged() -> int:
	return crevasses.size() - count_open()


# =============================================================================
# BUILDING
# =============================================================================

## Index the crevasses for crevasses_near (call after the list is final)
func build_index() -> void:
	_buckets.clear()
	for index in range(crevasses.size()):
		var crevasse: Crevasse = crevasses[index]
		var keys := {}
		for i in range(crevasse.points.size() - 1):
			var a := crevasse.points[i]
			var b := crevasse.points[i + 1]
			var steps := maxi(1, int(ceil(a.distance_to(b) / (BUCKET * 0.5))))
			for k in range(steps + 1):
				keys[_key(a.lerp(b, float(k) / float(steps)))] = true
		for key in keys:
			if not _buckets.has(key):
				_buckets[key] = []
			(_buckets[key] as Array).append(index)


func _key(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / BUCKET)), int(floor(p.y / BUCKET)))


## Bilinear sample of a grid stored like the terrain heights (row-major, z * size + x)
func _sample(grid: PackedFloat32Array, p: Vector2) -> float:
	if grid_size <= 1 or grid.size() != grid_size * grid_size:
		return 0.0
	var fx := (p.x - grid_min.x) / cell_size
	var fz := (p.y - grid_min.y) / cell_size
	if fx < 0.0 or fz < 0.0 or fx > float(grid_size - 1) or fz > float(grid_size - 1):
		return 0.0
	var x0 := mini(int(fx), grid_size - 2)
	var z0 := mini(int(fz), grid_size - 2)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var i := z0 * grid_size + x0
	var top := lerpf(grid[i], grid[i + 1], tx)
	var bottom := lerpf(grid[i + grid_size], grid[i + grid_size + 1], tx)
	return lerpf(top, bottom, tz)
