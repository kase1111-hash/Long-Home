class_name ProceduralMountainGenerator
extends RefCounted
## Builds a procedural mountain heightfield for mountains that ship without DEM data.
##
## Layout: the summit sits toward one side of a square world, base camp toward the
## opposite side (direction picked from the seed). Elevation falls from the summit to
## base camp along a designed profile with benches (< 25 deg), broad slideable snow
## slopes (30-35 deg), steeper downclimb faces (35-50 deg) and cliff bands (> 70 deg)
## whose count and coverage scale with the mountain's cliff exposure.
##
## Playability guarantee: a gently S-curving corridor links summit and base camp. Inside
## the corridor core the surface is the analytic profile only (no noise, no cliff step,
## flat across), and the profile is built so the corridor grade never exceeds
## MAX_CORRIDOR_GRADE. Cliff bands are crossed through ramps carved into the band.
## Both the summit and base camp are flattened plateaus.
##
## Glacier (mountains with glacier_extent > 0): a tongue of ice in the flank
## beside the corridor, outside its blend. Its surface is smooth (no noise),
## its profile the face's with the cliff bands turned into icefalls, lateral
## and terminal moraines line it, and its crevasses (GlacierField) are cut
## into the surface: open slots carved deep, snow bridges as a faint sag.

# =============================================================================
# CONSTANTS
# =============================================================================

## Half-width of the corridor core (metres): pure analytic surface
const CORE_HALF_WIDTH := 3.0
## Width of the blend from corridor core to wild terrain (metres)
const BLEND_WIDTH := 14.0
## Extra blend width around cliff-band ramps (banks are taller there)
const BAND_BLEND_EXTRA := 12.0
## Corridor distance at which noise reaches full amplitude
const NOISE_ENVELOPE_END := 45.0
## Flat plateau radius at summit / base camp, and the blend beyond it
const PLATEAU_RADIUS := 9.0
const PLATEAU_BLEND := 9.0
## tan(32 deg): hard cap on the corridor grade
const MAX_CORRIDOR_GRADE := 0.5095  # tan(27 deg): the safe line is a cautious walk
## tan(36 deg): cap on the face grade where the corridor runs diagonally
const MAX_FACE_GRADE := 0.7265
## Bench grade for the shelves that host cliff-band ramps: tan(9 deg)
const RAMP_SHELF_GRADE := 0.1584
## Grade behind the summit (tan 28 deg) and beyond base camp (tan 12 deg)
const BACK_GRADE := 0.5317
const RUNOUT_GRADE := 0.2126
## Horizontal width of a cliff band step (metres)
const BAND_STEP_WIDTH := 4.0
## Half-width of the profile grade smoothing (metres)
const GRADE_BLUR_RADIUS := 3

## Glacier: edge transition width, gap kept from the corridor centre line
## (beyond its blend), half-length of an icefall over a cliff band,
## moraine ridge height, and the sag over a snow bridge (metres)
const GLACIER_EDGE := 10.0
const GLACIER_CORRIDOR_GAP := 26.0
const ICEFALL_HALF := 22.0
const MORAINE_HEIGHT := 3.5
const BRIDGE_SAG := 0.45


# =============================================================================
# RESULT
# =============================================================================

## Output of a generation pass: a square grid of height samples plus layout data
class Result:
	## Samples per side (world_chunks * chunk_resolution + 1)
	var grid_size: int = 0
	## Height samples, row-major (z * grid_size + x)
	var heights: PackedFloat32Array = PackedFloat32Array()
	## World xz of sample (0, 0)
	var world_min: Vector2 = Vector2.ZERO
	## Spacing between samples (metres)
	var cell_size: float = 2.0
	## Summit plateau centre (xz)
	var start_xz: Vector2 = Vector2.ZERO
	## Base camp plateau centre (xz)
	var goal_xz: Vector2 = Vector2.ZERO
	## Corridor polyline summit -> base camp (xz), ~1 m spacing
	var corridor: PackedVector2Array = PackedVector2Array()
	## Corridor arc length (metres)
	var corridor_length: float = 0.0
	## Summit elevation (metres)
	var summit_elevation: float = 0.0
	## Base camp elevation (metres)
	var base_elevation: float = 0.0
	## Achieved vertical drop summit -> base camp
	var drop: float = 0.0
	## Vertical drop requested from the mountain data
	var requested_drop: float = 0.0
	## Seed used for all noise
	var seed: int = 0
	## Number of cliff bands laid across the face
	var cliff_band_count: int = 0
	## The glacier and its crevasses (null when the mountain has none)
	var glacier: GlacierField = null

	func sample(x: int, z: int) -> float:
		return heights[z * grid_size + x]


## One cliff band across the face
class CliffBand:
	## Axis coordinate of the band (metres from the summit along the axis)
	var s: float = 0.0
	## Vertical height of the step (metres)
	var height: float = 0.0
	## Half-length of the corridor ramp through the band (metres, along the axis)
	var ramp_half: float = 0.0
	## Lateral coverage bias (0-1): higher = band spans more of the face
	var coverage: float = 0.5
	## Offset into the band noise so each band has its own shape
	var noise_offset: float = 0.0


# =============================================================================
# STATE
# =============================================================================

var _rng: RandomNumberGenerator
var _fbm: FastNoiseLite
var _ridge: FastNoiseLite
var _fine: FastNoiseLite
var _band_noise: FastNoiseLite

## Axis from summit to base camp, its perpendicular, and endpoints (xz)
var _dir: Vector2 = Vector2.RIGHT
var _perp: Vector2 = Vector2.DOWN
var _summit_xz: Vector2 = Vector2.ZERO
var _base_xz: Vector2 = Vector2.ZERO
var _axis_length: float = 1.0

## Corridor lateral offset: a1 * sin(pi s / L) + a2 * sin(2 pi s / L)
var _a1: float = 0.0
var _a2: float = 0.0

## Tabulated profiles at 1 m steps along the axis (metres of descent from the summit)
var _profile_face: PackedFloat32Array = PackedFloat32Array()
var _profile_corridor: PackedFloat32Array = PackedFloat32Array()
## 1.0 inside a ramp window (for widening the corridor blend), 0 elsewhere
var _ramp_zone: PackedFloat32Array = PackedFloat32Array()
var _profile_scale: float = 1.0
var _bands: Array[CliffBand] = []

## Glacier layout in axis coordinates (see _setup_glacier)
var _glacier: GlacierField = null
var _g_side: float = 1.0
var _g_top: float = 0.0
var _g_snout: float = 0.0
var _g_offset: float = 0.0
var _g_width_top: float = 0.0
var _g_width_snout: float = 0.0
var _g_ela: float = 0.0
var _profile_glacier: PackedFloat32Array = PackedFloat32Array()

var _summit_elevation: float = 3400.0
var _lateral_grade: float = 0.194
var _fbm_amplitude: float = 8.0
var _ridge_amplitude: float = 4.0
var _fine_amplitude: float = 0.3


# =============================================================================
# PUBLIC API
# =============================================================================

## Generate a heightfield. mountain may be null (defaults are used).
## Chunk coordinates run from -world_chunks / 2 to world_chunks / 2 - 1.
func generate(
	mountain_id: String,
	mountain: MountainDatabase.MountainData,
	world_chunks: int,
	chunk_size: float,
	chunk_resolution: int
) -> Result:
	var result := Result.new()
	result.seed = hash(mountain_id)
	_rng = RandomNumberGenerator.new()
	_rng.seed = result.seed

	var world_size := world_chunks * chunk_size
	var cell := chunk_size / chunk_resolution
	var grid := world_chunks * chunk_resolution + 1
	var world_min := Vector2(-float(world_chunks / 2) * chunk_size, -float(world_chunks / 2) * chunk_size)
	var centre := world_min + Vector2(world_size, world_size) * 0.5

	result.grid_size = grid
	result.world_min = world_min
	result.cell_size = cell

	# Mountain parameters (fallbacks when the database has no entry)
	var total_descent := 1000.0
	var cliff_exposure := 0.4
	_summit_elevation = 3400.0
	if mountain != null:
		_summit_elevation = mountain.summit_elevation
		total_descent = mountain.total_descent
		cliff_exposure = clampf(mountain.cliff_exposure, 0.0, 1.0)
	result.summit_elevation = _summit_elevation
	result.requested_drop = clampf(total_descent * 0.4, 200.0, 400.0)

	_setup_noise(result.seed)
	_setup_layout(centre, world_size)
	_setup_bands(cliff_exposure)
	_build_profiles(result.requested_drop)

	var glacier_extent := 0.0
	if mountain != null:
		glacier_extent = clampf(mountain.glacier_extent, 0.0, 1.0)
	_setup_glacier(glacier_extent, result.seed)

	result.start_xz = _summit_xz
	result.goal_xz = _base_xz
	result.corridor = _build_corridor_polyline()
	result.corridor_length = _polyline_length(result.corridor)
	result.cliff_band_count = _bands.size()
	result.base_elevation = _summit_elevation - _profile_scale * _profile_corridor[_profile_corridor.size() - 1]
	result.drop = _summit_elevation - result.base_elevation

	_fill_heights(result)
	if _glacier != null:
		_finish_glacier(result)
	result.glacier = _glacier

	return result


# =============================================================================
# SETUP
# =============================================================================

func _setup_noise(seed_value: int) -> void:
	_fbm = FastNoiseLite.new()
	_fbm.seed = seed_value
	_fbm.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_fbm.fractal_type = FastNoiseLite.FRACTAL_FBM
	_fbm.fractal_octaves = 3
	_fbm.fractal_gain = 0.45
	_fbm.fractal_lacunarity = 2.0
	_fbm.frequency = 1.0 / 160.0

	_ridge = FastNoiseLite.new()
	_ridge.seed = seed_value + 101
	_ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge.fractal_octaves = 2
	_ridge.fractal_gain = 0.5
	_ridge.frequency = 1.0 / 48.0

	_fine = FastNoiseLite.new()
	_fine.seed = seed_value + 202
	_fine.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_fine.fractal_type = FastNoiseLite.FRACTAL_NONE
	_fine.frequency = 1.0 / 16.0

	_band_noise = FastNoiseLite.new()
	_band_noise.seed = seed_value + 303
	_band_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_band_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	_band_noise.frequency = 1.0 / 70.0


func _setup_layout(centre: Vector2, world_size: float) -> void:
	var theta := _rng.randf_range(0.0, TAU)
	_dir = Vector2(cos(theta), sin(theta))
	_perp = Vector2(-_dir.y, _dir.x)

	_summit_xz = centre - _dir * (0.36 * world_size)
	_base_xz = centre + _dir * (0.42 * world_size)
	_axis_length = 0.78 * world_size

	# S-curve amplitudes (signs randomised); kept well inside the world
	_a1 = _rng.randf_range(0.06, 0.10) * world_size * (1.0 if _rng.randf() < 0.5 else -1.0)
	_a2 = _rng.randf_range(0.03, 0.06) * world_size * (1.0 if _rng.randf() < 0.5 else -1.0)

	_lateral_grade = _rng.randf_range(0.16, 0.22)
	_fbm_amplitude = _rng.randf_range(6.5, 9.0)
	_ridge_amplitude = _rng.randf_range(2.5, 4.0)


func _setup_bands(cliff_exposure: float) -> void:
	_bands.clear()
	var count := clampi(roundi(cliff_exposure * 3.3), 0, 3)
	if cliff_exposure > 0.05 and count == 0:
		count = 1

	for k in range(count):
		var band := CliffBand.new()
		# Spread bands over the middle of the descent, jittered
		var frac := 0.25 + 0.55 * (float(k) + 0.5) / float(count)
		frac += _rng.randf_range(-0.02, 0.02)
		band.s = frac * _axis_length
		band.height = 12.0 + 16.0 * cliff_exposure + _rng.randf_range(-2.0, 2.0)
		band.coverage = clampf(0.55 + 0.45 * cliff_exposure, 0.0, 1.0)
		band.noise_offset = 1000.0 * float(k + 1)

		# Ramp long enough that shelf grade + ramp grade stays under the corridor cap
		var cos_angle := 1.0 / sqrt(1.0 + _offset_d1(band.s) * _offset_d1(band.s))
		var available := MAX_CORRIDOR_GRADE / cos_angle - RAMP_SHELF_GRADE
		band.ramp_half = 0.55 * band.height / available
		_bands.append(band)


## Tabulate face and corridor profiles (metres of descent) at 1 m steps along the axis.
func _build_profiles(requested_drop: float) -> void:
	var n := int(ceil(_axis_length)) + 1
	var grade_face := PackedFloat32Array()
	var grade_ramp := PackedFloat32Array()
	_ramp_zone = PackedFloat32Array()
	grade_face.resize(n)
	grade_ramp.resize(n)
	_ramp_zone.resize(n)
	_ramp_zone.fill(0.0)

	# 1. Base: slope sections at the corridor cap, adjusted for the corridor's diagonal
	for i in range(n):
		var s := float(i)
		var d1 := _offset_d1(s)
		var cos_angle := 1.0 / sqrt(1.0 + d1 * d1)
		grade_face[i] = minf(MAX_CORRIDOR_GRADE / cos_angle, MAX_FACE_GRADE)
		grade_ramp[i] = 0.0

	# 2. Plateau ends
	var plateau_len := PLATEAU_RADIUS + PLATEAU_BLEND
	for i in range(n):
		var s := float(i)
		if s < plateau_len or s > _axis_length - plateau_len:
			grade_face[i] = 0.03

	# 3. Cliff bands: shelf + ramp windows
	var blocked: Array[Vector2] = []
	for band in _bands:
		var lo := band.s - band.ramp_half - 6.0
		var hi := band.s + band.ramp_half + 6.0
		blocked.append(Vector2(lo, hi))
		var ramp_grade := band.height / (2.0 * band.ramp_half)
		for i in range(maxi(0, int(floor(lo))), mini(n, int(ceil(hi)) + 1)):
			var s := float(i)
			grade_face[i] = RAMP_SHELF_GRADE
			if s >= band.s - band.ramp_half and s <= band.s + band.ramp_half:
				grade_ramp[i] = ramp_grade
				_ramp_zone[i] = 1.0

	# 4. Benches in the free gaps between plateaus and band shelves
	var free_lo := plateau_len
	var gap_edges: Array[float] = []
	blocked.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	for block in blocked:
		gap_edges.append(free_lo)
		gap_edges.append(block.x)
		free_lo = block.y
	gap_edges.append(free_lo)
	gap_edges.append(_axis_length - plateau_len)

	var gap_index := 0
	while gap_index + 1 < gap_edges.size():
		var lo := gap_edges[gap_index]
		var hi := gap_edges[gap_index + 1]
		gap_index += 2
		var length := hi - lo
		if length < 45.0:
			continue
		var bench_len := _rng.randf_range(14.0, minf(30.0, length * 0.4))
		var bench_start := _rng.randf_range(lo + 8.0, hi - bench_len - 8.0)
		var bench_grade := tan(deg_to_rad(_rng.randf_range(12.0, 20.0)))
		for i in range(int(floor(bench_start)), mini(n, int(ceil(bench_start + bench_len)) + 1)):
			grade_face[i] = bench_grade
		# Vary the slope sections a little so faces are not all one angle
		var factor := _rng.randf_range(0.9, 1.0)
		for i in range(int(floor(lo)), mini(n, int(ceil(hi)) + 1)):
			if float(i) < bench_start or float(i) > bench_start + bench_len:
				grade_face[i] *= factor

	# 5. Smooth grades (box blur never exceeds the local maximum) and integrate
	var face_smooth := _box_blur(grade_face, GRADE_BLUR_RADIUS)
	var ramp_smooth := _box_blur(grade_ramp, GRADE_BLUR_RADIUS)

	_profile_face.resize(n)
	_profile_corridor.resize(n)
	var acc_face := 0.0
	var acc_corr := 0.0
	for i in range(n):
		_profile_face[i] = acc_face
		_profile_corridor[i] = acc_corr
		acc_face += face_smooth[i]
		acc_corr += face_smooth[i] + ramp_smooth[i]

	# 6. Scale down if the mountain asks for less drop than the profile delivers
	var delivered := _profile_corridor[n - 1]
	_profile_scale = 1.0
	if delivered > requested_drop and delivered > 0.0:
		_profile_scale = requested_drop / delivered


func _box_blur(values: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var n := values.size()
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var sum := 0.0
		var count := 0
		for k in range(-radius, radius + 1):
			var j := clampi(i + k, 0, n - 1)
			sum += values[j]
			count += 1
		out[i] = sum / float(count)
	return out


# =============================================================================
# CORRIDOR GEOMETRY
# =============================================================================

func _offset(s: float) -> float:
	var t := s / _axis_length
	return _a1 * sin(PI * t) + _a2 * sin(TAU * t)


func _offset_d1(s: float) -> float:
	var t := s / _axis_length
	return (_a1 * PI * cos(PI * t) + _a2 * TAU * cos(TAU * t)) / _axis_length


func _offset_d2(s: float) -> float:
	var t := s / _axis_length
	return -(_a1 * PI * PI * sin(PI * t) + _a2 * TAU * TAU * sin(TAU * t)) / (_axis_length * _axis_length)


func _corridor_point(s: float) -> Vector2:
	return _summit_xz + _dir * s + _perp * _offset(s)


func _build_corridor_polyline() -> PackedVector2Array:
	var points := PackedVector2Array()
	var steps := int(ceil(_axis_length))
	for i in range(steps + 1):
		var s := minf(float(i), _axis_length)
		points.append(_corridor_point(s))
	return points


func _polyline_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i].distance_to(points[i - 1])
	return length


## Profile lookup with linear interpolation, extended beyond both ends
func _profile_at(table: PackedFloat32Array, s: float) -> float:
	var last := table.size() - 1
	if s <= 0.0:
		return table[0] - s * BACK_GRADE
	if s >= float(last):
		return table[last] + (s - float(last)) * RUNOUT_GRADE
	var i := int(s)
	var f := s - float(i)
	return table[i] + (table[i + 1] - table[i]) * f


# =============================================================================
# GLACIER
# =============================================================================

## Lay out the glacier for this mountain (none below a trace of extent)
func _setup_glacier(extent: float, seed_value: int) -> void:
	_glacier = null
	if extent <= 0.01:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 4241
	var length := _axis_length
	_g_top = length * lerpf(0.5, 0.16, extent)
	_g_snout = length * lerpf(0.82, 0.95, extent)
	_g_width_top = lerpf(32.0, 72.0, extent)
	_g_width_snout = lerpf(16.0, 30.0, extent)
	_g_offset = _g_width_top + GLACIER_CORRIDOR_GAP
	# Away from the corridor's main bow, so the ice stays well inside the world
	_g_side = -signf(_a1) if absf(_a1) > 0.001 else 1.0
	_g_ela = lerpf(_g_top, _g_snout, 0.45)
	_build_glacier_profile()

	_glacier = GlacierField.new()
	_glacier.flow_direction = _dir
	_plan_crevasses(rng)


## The face profile with each cliff band spread into an icefall, smoothed:
## ice flows over the rock steps instead of breaking off them
func _build_glacier_profile() -> void:
	var n := _profile_face.size()
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in range(n):
		var s := float(i)
		var value := _profile_face[i]
		for band in _bands:
			value += band.height * band.coverage * smoothstep(-ICEFALL_HALF, ICEFALL_HALF, s - band.s)
		raw[i] = value
	_profile_glacier = _box_blur(raw, 8)


func _glacier_centre_v(s: float) -> float:
	return _offset(s) + _g_side * _g_offset


## Half width of the ice at s: a rounded cirque at the head, a tongue at the snout
func _glacier_half_width(s: float) -> float:
	if s < _g_top - 6.0 or s > _g_snout:
		return 0.0
	var t := clampf((s - _g_top) / maxf(_g_snout - _g_top, 1.0), 0.0, 1.0)
	var w := lerpf(_g_width_top, _g_width_snout, smoothstep(0.0, 1.0, t))
	w *= sqrt(clampf((s - _g_top + 6.0) / 22.0, 0.0, 1.0))
	w *= sqrt(clampf((_g_snout - s) / 28.0, 0.0, 1.0))
	return w


## Coverage of the ice at (s, v)
func _glacier_weight(s: float, v: float) -> float:
	var w := _glacier_half_width(s)
	if w <= 0.5:
		return 0.0
	var lateral := absf(v - _glacier_centre_v(s))
	return 1.0 - smoothstep(w - GLACIER_EDGE, w + 2.0, lateral)


## Rubble ridges: lateral moraines along the edges, a terminal moraine round the snout
func _moraine_height(s: float, v: float) -> float:
	var height := 0.0
	var centre := _glacier_centre_v(clampf(s, _g_top, _g_snout))
	var tongue_start := _g_snout - _g_width_snout
	if s >= _g_top + 10.0 and s <= tongue_start:
		var w := _glacier_half_width(s)
		var lateral := absf(v - centre)
		var x := (lateral - (w + 5.0)) / 4.0
		height = MORAINE_HEIGHT * exp(-x * x)
	elif s > tongue_start and s < _g_snout + 20.0:
		var radial := Vector2(s - tongue_start, v - centre).length()
		var x := (radial - (_g_width_snout + 5.0)) / 4.0
		height = MORAINE_HEIGHT * exp(-x * x)
	return height


## Crevasse layout: the bergschrund at the head, transverse rows where the ice
## steepens (dense in the icefalls), chevrons at the margins. Above the
## equilibrium line most are bridged by snow; below it most are open.
func _plan_crevasses(rng: RandomNumberGenerator) -> void:
	var specs: Array[Dictionary] = []
	var head := _g_top + 4.0

	# Bergschrund: the ice pulls away from the face at the head
	var head_width := _glacier_half_width(head + 6.0)
	if head_width > 10.0:
		var half := head_width * rng.randf_range(0.6, 0.85)
		var bend := half * 0.12
		specs.append(_crevasse_spec(GlacierField.CrevasseKind.BERGSCHRUND,
			[Vector2(head + 6.0 + bend, -half), Vector2(head + 6.0, 0.0), Vector2(head + 6.0 + bend, half)],
			rng.randf_range(2.0, 3.4), rng.randf_range(10.0, 15.0), rng.randf() < 0.6, rng.randf_range(0.3, 0.8)))

	# Transverse rows
	var s := head + 16.0
	while s < _g_snout - 14.0:
		var w := _glacier_half_width(s)
		var icefall := 0.0
		for band in _bands:
			icefall = maxf(icefall, 1.0 - clampf(absf(s - band.s) / (ICEFALL_HALF + 6.0), 0.0, 1.0))
		if w > 9.0 and rng.randf() < 0.22 + 0.7 * icefall:
			var pieces := rng.randi_range(1, 2 if icefall < 0.5 else 3)
			for _k in range(pieces):
				var span := minf(w * rng.randf_range(0.5, 1.1) / float(pieces), 2.0 * w - 8.0)
				if span < 6.0:
					continue
				var centre := rng.randf_range(-w + span * 0.5 + 3.0, w - span * 0.5 - 3.0)
				var bend := span * 0.08
				var above := s < _g_ela
				specs.append(_crevasse_spec(GlacierField.CrevasseKind.TRANSVERSE,
					[Vector2(s + bend, centre - span * 0.5), Vector2(s, centre), Vector2(s + bend, centre + span * 0.5)],
					lerpf(1.2, 3.4, rng.randf()) * (1.0 + 0.3 * icefall), rng.randf_range(7.0, 13.0),
					rng.randf() < (0.8 if above else 0.15), pow(rng.randf(), 0.8)))
			s += rng.randf_range(7.0, 12.0) * (1.0 - 0.4 * icefall)
		else:
			s += rng.randf_range(6.0, 10.0)

	# Chevrons: from the edges, angled inward and up-glacier
	for side_sign in [-1.0, 1.0]:
		var sm := head + 20.0
		while sm < _g_snout - 16.0:
			var w := _glacier_half_width(sm)
			if w > 12.0 and rng.randf() < 0.55:
				var length := rng.randf_range(8.0, 15.0)
				var v0: float = side_sign * (w - 3.0)
				var v1: float = side_sign * (w - 3.0 - length * 0.7)
				specs.append(_crevasse_spec(GlacierField.CrevasseKind.MARGINAL,
					[Vector2(sm, v0), Vector2(sm - length * 0.7, v1)],
					rng.randf_range(0.9, 1.8), rng.randf_range(5.0, 9.0),
					rng.randf() < (0.7 if sm < _g_ela else 0.2), pow(rng.randf(), 0.8)))
			sm += rng.randf_range(12.0, 22.0)

	# Into world space, dropping any that crowd one already placed
	var placed: Array[GlacierField.Crevasse] = []
	for spec in specs:
		var crevasse := GlacierField.Crevasse.new()
		crevasse.kind = spec["kind"]
		crevasse.width = spec["width"]
		crevasse.depth = spec["depth"]
		crevasse.bridged = spec["bridged"]
		crevasse.bridge_strength = clampf(spec["strength"], 0.05, 1.0)
		for sv in spec["points"]:
			crevasse.points.append(_axis_to_world(sv.x, _glacier_centre_v(sv.x) + sv.y))
		var crowded := false
		for other in placed:
			for p in crevasse.points:
				if other.distance_to(p) < (other.width + crevasse.width) * 0.5 + 3.0:
					crowded = true
		if crowded:
			continue
		crevasse.id = placed.size()
		placed.append(crevasse)
	_glacier.crevasses = placed
	_glacier.build_index()


func _crevasse_spec(kind: int, points: Array, width: float, depth: float, bridged: bool, strength: float) -> Dictionary:
	return {"kind": kind, "points": points, "width": width, "depth": depth, "bridged": bridged, "strength": strength}


func _axis_to_world(s: float, v: float) -> Vector2:
	return _summit_xz + _dir * s + _perp * v


## How far a crevasse lowers the surface at a world point: the full depth
## inside an open slot (tapering at the ends), a faint sag over a bridge
func _crevasse_cut(p: Vector2) -> float:
	var cut := 0.0
	for crevasse in _glacier.crevasses_near(p, 4.0):
		var where := crevasse.locate(p)
		var seg := int(where.z)
		var along := 0.0
		for i in range(seg):
			along += crevasse.points[i].distance_to(crevasse.points[i + 1])
		along += crevasse.points[seg].distance_to(crevasse.points[seg + 1]) * where.y
		var from_end := minf(along, crevasse.length() - along)
		var taper := smoothstep(0.0, 2.5, from_end)
		# At least the nearest row of terrain samples (2 m apart) goes the full
		# depth, so a narrow slot is never lost between them
		var half := maxf(crevasse.width * 0.5, 1.1)
		if crevasse.bridged:
			cut = maxf(cut, BRIDGE_SAG * (1.0 - smoothstep(half, half + 2.5, where.x)) * taper)
		else:
			cut = maxf(cut, crevasse.depth * (1.0 - smoothstep(half - 0.3, half + 1.0, where.x)) * taper)
	return cut


## After the heights: lips, elevations and the centre line for the field
func _finish_glacier(result: Result) -> void:
	_glacier.grid_size = result.grid_size
	_glacier.grid_min = result.world_min
	_glacier.cell_size = result.cell_size
	for crevasse in _glacier.crevasses:
		crevasse.lip_heights.clear()
		for i in range(crevasse.points.size()):
			var p := crevasse.points[i]
			var along_dir := (crevasse.points[mini(i + 1, crevasse.points.size() - 1)] - crevasse.points[maxi(i - 1, 0)]).normalized()
			var across := Vector2(-along_dir.y, along_dir.x)
			var reach := crevasse.width * 0.5 + 2.5
			var lip := minf(_height_at(result, p + across * reach), _height_at(result, p - across * reach))
			if crevasse.bridged:
				lip = maxf(lip, _height_at(result, p) + BRIDGE_SAG)
			crevasse.lip_heights.append(lip)
	var s := _g_top
	while s <= _g_snout:
		_glacier.centreline.append(_axis_to_world(s, _glacier_centre_v(s)))
		_glacier.half_widths.append(_glacier_half_width(s))
		s += 4.0
	_glacier.head_elevation = _height_at(result, _axis_to_world(_g_top + 8.0, _glacier_centre_v(_g_top + 8.0)))
	_glacier.snout_elevation = _height_at(result, _axis_to_world(_g_snout - 6.0, _glacier_centre_v(_g_snout - 6.0)))
	_glacier.ela_elevation = _height_at(result, _axis_to_world(_g_ela, _glacier_centre_v(_g_ela)))


## Bilinear height from the result grid at a world point
func _height_at(result: Result, p: Vector2) -> float:
	var fx := clampf((p.x - result.world_min.x) / result.cell_size, 0.0, float(result.grid_size - 1))
	var fz := clampf((p.y - result.world_min.y) / result.cell_size, 0.0, float(result.grid_size - 1))
	var x0 := mini(int(fx), result.grid_size - 2)
	var z0 := mini(int(fz), result.grid_size - 2)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var top := lerpf(result.sample(x0, z0), result.sample(x0 + 1, z0), tx)
	var bottom := lerpf(result.sample(x0, z0 + 1), result.sample(x0 + 1, z0 + 1), tx)
	return lerpf(top, bottom, tz)


# =============================================================================
# HEIGHTFIELD
# =============================================================================

func _fill_heights(result: Result) -> void:
	var grid := result.grid_size
	var cell := result.cell_size
	var heights := PackedFloat32Array()
	heights.resize(grid * grid)

	var summit := _summit_elevation
	var base_height := result.base_elevation
	var scale := _profile_scale
	var dir_x := _dir.x
	var dir_y := _dir.y
	var sx := _summit_xz.x
	var sz := _summit_xz.y
	var bx := _base_xz.x
	var bz := _base_xz.y
	var axis_len := _axis_length
	var band_count := _bands.size()
	var plateau_outer := PLATEAU_RADIUS + PLATEAU_BLEND
	var near_limit := NOISE_ENVELOPE_END + BLEND_WIDTH + BAND_BLEND_EXTRA + 10.0

	var has_glacier := _glacier != null
	var glacier_s_min := _g_top - 8.0
	var glacier_s_max := _g_snout + 22.0
	if has_glacier:
		_glacier.weights.resize(grid * grid)
		_glacier.weights.fill(0.0)
		_glacier.moraine.resize(grid * grid)
		_glacier.moraine.fill(0.0)

	for gz in range(grid):
		var wz := result.world_min.y + float(gz) * cell
		var row := gz * grid
		for gx in range(grid):
			var wx := result.world_min.x + float(gx) * cell
			var px := wx - sx
			var pz := wz - sz
			var s := px * dir_x + pz * dir_y
			var v := -px * dir_y + pz * dir_x

			# --- distance to the corridor (Newton refinement, only where it matters)
			var rough := absf(v - _offset(clampf(s, 0.0, axis_len)))
			var d := rough
			var st := clampf(s, 0.0, axis_len)
			if rough < near_limit:
				for _iter in range(2):
					var off := _offset(st)
					var d1 := _offset_d1(st)
					var d2 := _offset_d2(st)
					var f1 := 2.0 * (st - s) + 2.0 * (off - v) * d1
					var f2 := 2.0 + 2.0 * d1 * d1 + 2.0 * (off - v) * d2
					st = clampf(st - f1 / maxf(f2, 0.5), 0.0, axis_len)
				var dv := _offset(st) - v
				var ds := st - s
				d = sqrt(ds * ds + dv * dv)

			# --- face (wild terrain in axis coordinates)
			var lateral := _lateral_grade * (sqrt(v * v + 400.0) - 20.0)
			var face := summit - scale * _profile_at(_profile_face, s) - lateral
			for k in range(band_count):
				var band: CliffBand = _bands[k]
				var rel := s - band.s
				if rel < -30.0:
					continue
				var coverage := clampf(band.coverage + 0.9 * _band_noise.get_noise_2d(band.noise_offset, v), 0.0, 1.0)
				var step_h := band.height * scale * coverage
				if rel > 30.0:
					face -= step_h
				else:
					var warped := rel + 12.0 * _band_noise.get_noise_2d(wx + band.noise_offset, wz)
					face -= step_h * smoothstep(-BAND_STEP_WIDTH * 0.5, BAND_STEP_WIDTH * 0.5, warped)

			# --- glacier: smooth ice over the face, moraines along its edges
			var g := 0.0
			if has_glacier and s > glacier_s_min and s < glacier_s_max:
				var moraine_h := _moraine_height(s, v)
				if moraine_h > 0.01:
					face += moraine_h
					_glacier.moraine[row + gx] = moraine_h
				g = _glacier_weight(s, v)
				if g > 0.0:
					var ice := summit - scale * _profile_at(_profile_glacier, s) - lateral - 1.0
					face = lerpf(face, ice, g)
					_glacier.weights[row + gx] = g

			# --- corridor surface: analytic profile, flat across
			var corridor_h := summit - scale * _profile_at(_profile_corridor, st)

			# --- blend corridor into face
			var ramp_zone := 0.0
			if st > 0.0 and st < axis_len:
				ramp_zone = _ramp_zone[int(st)]
			var blend_w := BLEND_WIDTH + BAND_BLEND_EXTRA * ramp_zone
			var w_core := 1.0 - smoothstep(CORE_HALF_WIDTH, CORE_HALF_WIDTH + blend_w, d)
			var h := face + (corridor_h - face) * w_core

			# --- noise, damped near the corridor
			var env := smoothstep(CORE_HALF_WIDTH, NOISE_ENVELOPE_END, d)
			if env > 0.0:
				var n := _fbm.get_noise_2d(wx, wz) * _fbm_amplitude
				n -= (_ridge.get_noise_2d(s * 0.35, v) * 0.5 + 0.5) * _ridge_amplitude
				n += _fine.get_noise_2d(wx, wz) * _fine_amplitude
				# Ice is smooth: only a faint texture survives on the glacier
				h += n * env * (1.0 - g)
			if g > 0.0:
				h += _fine.get_noise_2d(wx * 2.0, wz * 2.0) * 0.25 * g
				h -= _crevasse_cut(Vector2(wx, wz))

			# --- plateaus
			var dsx := wx - sx
			var dsz := wz - sz
			var dist_summit := sqrt(dsx * dsx + dsz * dsz)
			if dist_summit < plateau_outer:
				h = lerpf(summit, h, smoothstep(PLATEAU_RADIUS, plateau_outer, dist_summit))
			var dbx := wx - bx
			var dbz := wz - bz
			var dist_base := sqrt(dbx * dbx + dbz * dbz)
			if dist_base < plateau_outer:
				h = lerpf(base_height, h, smoothstep(PLATEAU_RADIUS, plateau_outer, dist_base))

			heights[row + gx] = h

	result.heights = heights
