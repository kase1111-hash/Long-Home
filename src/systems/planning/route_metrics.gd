class_name RouteMetrics
extends RefCounted
## Measures a line on the loaded terrain the way a guidebook author would:
## where it is steep and for how long, where the rope comes out, how exposed
## it is, what it is graded, and how long a competent party takes.
##
## Book times come from the game's own movement model (Tobler pace on foot,
## TractionModel downclimbing speed, the rope system's set-up and abseil
## timings) at a sustainable pace, converted to game minutes. A player who
## moves well matches the book; one who glides or skis where the book walks
## beats it.
##
## The same measurement grades a planned line (guidebook, planning screen)
## and the line actually travelled (scoring). For a travelled line, optional
## per-sample travel modes say how each stretch was covered: ground crossed
## out of control (falls, tumbling slides) earns no difficulty, and only
## abseils actually made count as abseils.

# =============================================================================
# CONSTANTS
# =============================================================================

## Resampling step along the line (horizontal metres)
const SAMPLE_STEP := 2.0
## Shorter sections fold into their neighbours (a pitch is a stretch, not a cell)
const MIN_PITCH_LENGTH := 12.0
## A rope section needs at least this much height to be an abseil
## (RopeService.mandatory_rope_cliff_height)
const MIN_RAPPEL_HEIGHT := 3.0
## A rope section this high cannot be climbed on foot
const MIN_BLOCKING_HEIGHT := 6.0
## A drop this close below makes the ground exposed (metres)
const EXPOSURE_CLIFF_DISTANCE := 12.0
## Window for the steepest sustained slope (samples: 10 x 2 m)
const SUSTAINED_WINDOW := 10

## Sustainable pace as a fraction of flat-out (stops, route finding, breathing)
const PACE := 0.85
## Walking speed on the flat (m/s real time, PlayerController.base_walk_speed)
const BASE_WALK_SPEED := 2.4
## Average of the downclimbing placement pulse (0.3 + 0.7 * mean sin^2)
const CLIMB_PULSE_MEAN := 0.65
## Abseil timing (real seconds): find and build an anchor, thread, rope down,
## pull it through
const RAPPEL_ANCHOR_SEARCH := 10.0
const RAPPEL_SETUP := 26.0
const RAPPEL_SPEED := 1.0
const RAPPEL_PULL := 14.0
## Default rope when none is given (60 m doubled: 30 m abseils)
const DEFAULT_ROPE_LENGTH := 60.0

## Travel modes for a travelled line (RunContext.path_modes)
const MODE_FOOT := 0
const MODE_CLIMB := 1
const MODE_ROPE := 2
const MODE_GLIDE := 3
const MODE_ADRIFT := 4

## Pitch kinds: WALK below 30 deg, STEEP 30-35 (a slip slides), DOWNCLIMB
## 35-50 (facing in), RAPPEL on rope ground; GLIDE and ADRIFT only on a
## travelled line (skied or glissaded; out of control)
enum Kind { WALK, STEEP, DOWNCLIMB, RAPPEL, GLIDE, ADRIFT }

const KIND_NAMES := {
	Kind.WALK: "walk",
	Kind.STEEP: "steep",
	Kind.DOWNCLIMB: "downclimb",
	Kind.RAPPEL: "rappel",
	Kind.GLIDE: "glide",
	Kind.ADRIFT: "adrift",
}


# =============================================================================
# DATA
# =============================================================================

## One stretch of uniform character, as a guidebook topo lists it
class Pitch:
	var kind: int = Kind.WALK
	var first_sample: int = 0
	var last_sample: int = 0
	## Horizontal metres from the start of the line
	var start_distance: float = 0.0
	var length: float = 0.0
	var start_elevation: float = 0.0
	var end_elevation: float = 0.0
	var min_slope: float = 90.0
	var max_slope: float = 0.0
	var mean_slope: float = 0.0
	var surface: int = 0
	var exposed: bool = false
	var icy: bool = false
	var rappels: int = 0
	var longest_rappel: float = 0.0
	## Book time for the pitch (game minutes)
	var minutes: float = 0.0
	var start_point: Vector3 = Vector3.ZERO
	var end_point: Vector3 = Vector3.ZERO

	func get_height() -> float:
		return absf(start_elevation - end_elevation)

	func to_dict() -> Dictionary:
		return {
			"kind": KIND_NAMES.get(kind, "walk"),
			"length": length,
			"start_elevation": start_elevation,
			"end_elevation": end_elevation,
			"max_slope": max_slope,
			"rappels": rappels,
			"minutes": minutes,
		}


class Result:
	## Resampled line (y = ground)
	var points: PackedVector3Array = PackedVector3Array()
	## Horizontal distance from the start at each point
	var distances: PackedFloat32Array = PackedFloat32Array()
	## Pitch kind of the step that starts at each point
	var step_kinds: PackedByteArray = PackedByteArray()
	var length: float = 0.0
	var surface_length: float = 0.0
	var start_elevation: float = 0.0
	var end_elevation: float = 0.0
	var height_loss: float = 0.0
	var height_gain: float = 0.0
	## Height lost (or, going up, gained) under control: out-of-control
	## stretches and jumps excluded
	var controlled_vertical: float = 0.0
	var ascending: bool = false
	## Steepest cell crossed (deg)
	var max_slope: float = 0.0
	## Steepest ~20 m stretch walked, climbed or skied (deg, abseils excluded)
	var sustained_slope: float = 0.0
	## Horizontal metres of each kind
	var metres_by_kind: Dictionary = {}
	var steep_metres: float = 0.0
	var ice_metres: float = 0.0
	var exposed_metres: float = 0.0
	var exposure: float = 0.0
	var snow_fraction: float = 0.0
	var rappels: int = 0
	var rappel_height: float = 0.0
	var longest_rappel: float = 0.0
	var pitches: Array[Pitch] = []
	## Book time (game minutes)
	var minutes: float = 0.0
	## A rope pitch stands in the way of going up this line on foot
	var ascent_blocked: bool = false
	var grade_value: float = 0.0
	var grade: String = "F"
	var commitment: String = "I"
	var crampons_advised: bool = false
	var rope_required: bool = false
	## Shortest rope that makes the abseils (metres, 0 = none needed)
	var min_rope_length: float = 0.0

	func get_full_grade() -> String:
		return "%s %s" % [grade, commitment]

	func get_vertical() -> float:
		return absf(start_elevation - end_elevation)

	func to_dict() -> Dictionary:
		return {
			"length": length,
			"vertical": get_vertical(),
			"grade": grade,
			"grade_value": grade_value,
			"commitment": commitment,
			"minutes": minutes,
			"rappels": rappels,
			"sustained_slope": sustained_slope,
			"exposure": exposure,
		}


## Travel mode for a player movement state (and slide control while sliding)
static func travel_mode_for(state: int, slide_control: int) -> int:
	match state:
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			return MODE_CLIMB
		GameEnums.PlayerMovementState.ROPING:
			return MODE_ROPE
		GameEnums.PlayerMovementState.SKIING:
			return MODE_GLIDE
		GameEnums.PlayerMovementState.SLIDING:
			if slide_control == GameEnums.SlideControlLevel.CONTROLLED or slide_control == GameEnums.SlideControlLevel.MARGINAL:
				return MODE_GLIDE
			return MODE_ADRIFT
		GameEnums.PlayerMovementState.FALLING, GameEnums.PlayerMovementState.ARRESTED, GameEnums.PlayerMovementState.INCAPACITATED:
			return MODE_ADRIFT
	return MODE_FOOT


# =============================================================================
# MEASUREMENT
# =============================================================================

## Measure a line. options:
##   rope_length    float  rope carried (abseil = half of it); default 60
##   has_crampons   bool   pace and footing with crampons where they help; default true
##   weight_modifier float pack weight pace factor; default 0.95
##   modes          PackedByteArray  travel mode per input point (travelled lines)
##   rappels_made   int    abseils actually made (travelled lines); -1 = from the terrain
static func measure(line: PackedVector3Array, terrain: TerrainService, options: Dictionary = {}) -> Result:
	var result := Result.new()
	if line.size() < 2 or terrain == null:
		return result

	var rope_length: float = options.get("rope_length", DEFAULT_ROPE_LENGTH)
	if rope_length <= 0.0:
		rope_length = DEFAULT_ROPE_LENGTH
	var max_rappel := rope_length * 0.5
	var has_crampons: bool = options.get("has_crampons", true)
	var weight_modifier: float = options.get("weight_modifier", 0.95)
	var input_modes: PackedByteArray = options.get("modes", PackedByteArray())
	var rappels_made: int = options.get("rappels_made", -1)

	var modes := PackedByteArray()
	_resample(line, input_modes, terrain, result, modes)
	var n := result.points.size()
	if n < 2:
		return result

	result.start_elevation = result.points[0].y
	result.end_elevation = result.points[n - 1].y
	result.ascending = result.end_elevation > result.start_elevation

	# --- per-step classification and timing -------------------------------
	var steps := n - 1
	var geo_kinds := PackedByteArray()
	var kinds := PackedByteArray()
	var slopes := PackedFloat32Array()
	var surfaces := PackedInt32Array()
	var exposed := PackedByteArray()
	var step_seconds := PackedFloat32Array()
	geo_kinds.resize(steps)
	kinds.resize(steps)
	slopes.resize(steps)
	surfaces.resize(steps)
	exposed.resize(steps)
	step_seconds.resize(steps)

	var boots := GameEnums.Footwear.BOOTS
	var crampons := GameEnums.Footwear.CRAMPONS
	var snow_metres := 0.0

	for i in range(steps):
		var a := result.points[i]
		var b := result.points[i + 1]
		var mid := (a + b) * 0.5
		var cell := terrain.get_cell_at(mid)
		var slope := 0.0
		var surface := GameEnums.SurfaceType.SNOW_FIRM
		var rope := false
		var cliff_distance := 1000.0
		var slope_dir := Vector3.ZERO
		if cell != null:
			slope = cell.slope_angle
			surface = cell.surface_type
			rope = cell.requires_rope
			cliff_distance = cell.distance_to_cliff
			slope_dir = cell.slope_direction
		slopes[i] = slope
		surfaces[i] = surface

		var geo := Kind.WALK
		if rope:
			geo = Kind.RAPPEL
		elif slope >= GameEnums.SLOPE_THRESHOLDS.downclimb_min:
			geo = Kind.DOWNCLIMB
		elif slope >= GameEnums.SLOPE_THRESHOLDS.slide_min:
			# Where a slip turns into a slide
			geo = Kind.STEEP
		geo_kinds[i] = geo

		var kind := geo
		if not modes.is_empty():
			match int(modes[i]):
				MODE_ADRIFT:
					kind = Kind.ADRIFT
				MODE_ROPE:
					kind = Kind.RAPPEL
				MODE_GLIDE:
					kind = Kind.GLIDE
				_:
					# On foot over rope ground (a short step taken without
					# the rope) counts as downclimbing it
					if geo == Kind.RAPPEL:
						kind = Kind.DOWNCLIMB
		kinds[i] = kind

		var horizontal := Vector2(b.x - a.x, b.z - a.z).length()
		var dy := b.y - a.y
		result.surface_length += sqrt(horizontal * horizontal + dy * dy)
		if dy < 0.0:
			result.height_loss -= dy
		else:
			result.height_gain += dy

		if TractionModel.is_snow(surface):
			snow_metres += horizontal

		var is_exposed := (
			cliff_distance < EXPOSURE_CLIFF_DISTANCE
			and slope >= GameEnums.SLOPE_THRESHOLDS.walkable_max
			and kind != Kind.RAPPEL
		)
		exposed[i] = 1 if is_exposed else 0

		# Book time: foot travel over the geometry (rope pitches are timed per abseil)
		step_seconds[i] = 0.0
		if geo != Kind.RAPPEL and horizontal > 0.0001:
			var heading := Vector3(b.x - a.x, 0.0, b.z - a.z) / horizontal
			var along := heading.dot(slope_dir) if slope_dir != Vector3.ZERO else 0.0
			var across := sqrt(maxf(0.0, 1.0 - along * along))
			var steepness := tan(deg_to_rad(minf(slope, 85.0)))
			var surface_distance := sqrt(horizontal * horizontal + dy * dy)
			var speed := 0.0
			if geo == Kind.DOWNCLIMB:
				var climb := TractionModel.downclimb_speed(slope, surface, boots)
				if has_crampons:
					climb = maxf(climb, TractionModel.downclimb_speed(slope, surface, crampons))
				speed = climb * CLIMB_PULSE_MEAN
				if dy > 0.0 and along < -0.3:
					speed *= 0.6  # Climbing up
				elif absf(along) < 0.5:
					speed *= 0.8  # Across the face
			else:
				var surface_speed := TractionModel.walk_surface_speed(surface, boots)
				if has_crampons:
					surface_speed = maxf(surface_speed, TractionModel.walk_surface_speed(surface, crampons))
				var grade := dy / horizontal
				var cross := steepness * across
				speed = BASE_WALK_SPEED * surface_speed * TractionModel.tobler_factor(grade, cross, surface) * weight_modifier
			speed *= PACE
			step_seconds[i] = surface_distance / maxf(speed, 0.05)

	result.snow_fraction = snow_metres / maxf(result.distances[n - 1], 0.001)
	result.length = result.distances[n - 1]

	# --- pitches -----------------------------------------------------------
	result.pitches = _build_pitches(result, kinds, slopes, surfaces, exposed, max_rappel)

	# Timing per pitch (rope pitches by abseil, from the geometry)
	var total_seconds := 0.0
	for pitch in result.pitches:
		var seconds := 0.0
		for i in range(pitch.first_sample, pitch.last_sample):
			seconds += step_seconds[i]
		# Abseil time comes from the geometric rope ground inside the pitch
		var geo_rope := _geo_rope_runs(result, geo_kinds, pitch.first_sample, pitch.last_sample)
		for height in geo_rope:
			if height < MIN_RAPPEL_HEIGHT:
				# A short step: climbed, at downclimbing pace
				seconds += height / (0.3 * PACE)
				continue
			var count := int(ceil(height / max_rappel))
			for _k in range(count):
				var drop := height / float(count)
				seconds += RAPPEL_ANCHOR_SEARCH + RAPPEL_SETUP + drop / RAPPEL_SPEED + RAPPEL_PULL
			if result.ascending and height >= MIN_BLOCKING_HEIGHT:
				result.ascent_blocked = true
		pitch.minutes = seconds * GameEnums.TIME_SCALE / 60.0
		total_seconds += seconds
	result.minutes = total_seconds * GameEnums.TIME_SCALE / 60.0

	# --- totals ------------------------------------------------------------
	for kind_key in Kind.values():
		result.metres_by_kind[kind_key] = 0.0
	var counted_rappels := 0
	for pitch in result.pitches:
		result.metres_by_kind[pitch.kind] = float(result.metres_by_kind.get(pitch.kind, 0.0)) + pitch.length
		if pitch.kind == Kind.RAPPEL:
			counted_rappels += pitch.rappels
			result.rappel_height += pitch.get_height()
			result.longest_rappel = maxf(result.longest_rappel, pitch.longest_rappel)

	var voluntary_metres := 0.0
	var adrift_drop := 0.0
	for i in range(steps):
		var horizontal := result.distances[i + 1] - result.distances[i]
		result.max_slope = maxf(result.max_slope, slopes[i])
		if kinds[i] == Kind.ADRIFT:
			# Signed height covered out of control, in the line's direction
			var step_dy := result.points[i + 1].y - result.points[i].y
			adrift_drop += step_dy if result.ascending else -step_dy
			continue
		voluntary_metres += horizontal
		if kinds[i] == Kind.DOWNCLIMB or (kinds[i] == Kind.GLIDE and slopes[i] >= GameEnums.SLOPE_THRESHOLDS.downclimb_min):
			result.steep_metres += horizontal
		if surfaces[i] == GameEnums.SurfaceType.ICE and slopes[i] >= GameEnums.SLOPE_THRESHOLDS.slide_min and kinds[i] != Kind.RAPPEL:
			result.ice_metres += horizontal
		if exposed[i] == 1:
			result.exposed_metres += horizontal
	result.exposure = result.exposed_metres / maxf(voluntary_metres, 1.0)
	result.controlled_vertical = maxf(0.0, result.get_vertical() - adrift_drop)
	result.sustained_slope = _sustained_slope(slopes, kinds)

	result.rappels = counted_rappels if rappels_made < 0 else rappels_made
	result.rope_required = counted_rappels > 0
	if result.longest_rappel > 0.0:
		result.min_rope_length = maxf(30.0, ceilf(result.longest_rappel * 2.0 / 10.0) * 10.0)

	result.crampons_advised = result.ice_metres > 5.0 or _hard_snow_metres(result, slopes, surfaces, kinds) > 20.0

	result.grade_value = AlpineGrade.grade_value(
		result.sustained_slope, result.steep_metres, result.rappels, result.exposure, result.ice_metres
	)
	result.grade = AlpineGrade.grade_name(result.grade_value)
	result.commitment = AlpineGrade.commitment(result.minutes)
	result.step_kinds = kinds
	return result


## Resample the line every SAMPLE_STEP horizontal metres onto the ground,
## carrying the travel mode of the source segment
static func _resample(
	line: PackedVector3Array,
	input_modes: PackedByteArray,
	terrain: TerrainService,
	result: Result,
	modes: PackedByteArray
) -> void:
	var has_modes := input_modes.size() == line.size()
	var travelled := 0.0
	var next_sample := 0.0
	for i in range(line.size() - 1):
		var a := line[i]
		var b := line[i + 1]
		var seg := Vector2(b.x - a.x, b.z - a.z).length()
		if seg < 0.0001:
			continue
		while next_sample <= travelled + seg:
			var t := (next_sample - travelled) / seg
			var p := a.lerp(b, t)
			p.y = terrain.get_height_at(p)
			result.points.append(p)
			result.distances.append(next_sample)
			if has_modes:
				modes.append(input_modes[i])
			next_sample += SAMPLE_STEP
		travelled += seg
	# Always end exactly on the last point
	var last := line[line.size() - 1]
	if result.distances.is_empty() or travelled - result.distances[result.distances.size() - 1] > 0.25:
		last.y = terrain.get_height_at(last)
		result.points.append(last)
		result.distances.append(travelled)
		if has_modes:
			modes.append(input_modes[line.size() - 1])


## Group steps into pitches: runs of one kind, short runs folded into the
## run before them, rope runs too short to abseil turned into downclimbing
static func _build_pitches(
	result: Result,
	kinds: PackedByteArray,
	slopes: PackedFloat32Array,
	surfaces: PackedInt32Array,
	exposed: PackedByteArray,
	max_rappel: float
) -> Array[Pitch]:
	var steps := kinds.size()

	# Runs as [kind, first, last) triples
	var runs: Array[Vector3i] = []
	var start := 0
	for i in range(1, steps + 1):
		if i == steps or kinds[i] != kinds[start]:
			runs.append(Vector3i(kinds[start], start, i))
			start = i

	# Rope runs with little height are a step, not an abseil
	for r in range(runs.size()):
		var run := runs[r]
		if run.x == Kind.RAPPEL:
			var height := absf(result.points[run.y].y - result.points[run.z].y)
			if height < MIN_RAPPEL_HEIGHT:
				runs[r] = Vector3i(Kind.DOWNCLIMB, run.y, run.z)

	# Fold short runs into a neighbour (abseils and out-of-control stretches stay)
	var folded: Array[Vector3i] = []
	for run in runs:
		var length := result.distances[run.z] - result.distances[run.y]
		var keep := run.x == Kind.RAPPEL or run.x == Kind.ADRIFT or length >= MIN_PITCH_LENGTH
		if not keep and not folded.is_empty():
			var prev := folded[folded.size() - 1]
			if prev.x != Kind.RAPPEL and prev.x != Kind.ADRIFT:
				folded[folded.size() - 1] = Vector3i(prev.x, prev.y, run.z)
				continue
		if not folded.is_empty() and folded[folded.size() - 1].x == run.x:
			var prev2 := folded[folded.size() - 1]
			folded[folded.size() - 1] = Vector3i(prev2.x, prev2.y, run.z)
			continue
		folded.append(run)

	# A short first run had nothing before it: give it to the next one
	if folded.size() >= 2:
		var first := folded[0]
		var first_length := result.distances[first.z] - result.distances[first.y]
		if first_length < MIN_PITCH_LENGTH and first.x != Kind.RAPPEL and first.x != Kind.ADRIFT and folded[1].x != Kind.RAPPEL:
			folded[1] = Vector3i(folded[1].x, first.y, folded[1].z)
			folded.remove_at(0)

	var pitches: Array[Pitch] = []
	for run in folded:
		var pitch := Pitch.new()
		pitch.kind = run.x
		pitch.first_sample = run.y
		pitch.last_sample = run.z
		pitch.start_distance = result.distances[run.y]
		pitch.length = result.distances[run.z] - result.distances[run.y]
		pitch.start_point = result.points[run.y]
		pitch.end_point = result.points[run.z]
		pitch.start_elevation = pitch.start_point.y
		pitch.end_elevation = pitch.end_point.y
		var slope_sum := 0.0
		var surface_metres := {}
		for i in range(run.y, run.z):
			var horizontal := result.distances[i + 1] - result.distances[i]
			pitch.min_slope = minf(pitch.min_slope, slopes[i])
			pitch.max_slope = maxf(pitch.max_slope, slopes[i])
			slope_sum += slopes[i]
			surface_metres[surfaces[i]] = float(surface_metres.get(surfaces[i], 0.0)) + horizontal
			if exposed[i] == 1:
				pitch.exposed = true
			if surfaces[i] == GameEnums.SurfaceType.ICE and slopes[i] >= GameEnums.SLOPE_THRESHOLDS.slide_min:
				pitch.icy = true
		pitch.mean_slope = slope_sum / maxf(1.0, float(run.z - run.y))
		var best_surface := GameEnums.SurfaceType.SNOW_FIRM
		var best_metres := -1.0
		for surface_key in surface_metres:
			if float(surface_metres[surface_key]) > best_metres:
				best_metres = surface_metres[surface_key]
				best_surface = surface_key
		pitch.surface = best_surface
		if pitch.kind == Kind.RAPPEL:
			var height := pitch.get_height()
			pitch.rappels = maxi(1, int(ceil(height / max_rappel)))
			pitch.longest_rappel = height / float(pitch.rappels)
		pitches.append(pitch)
	return pitches


## Heights of the geometric rope runs between two samples
static func _geo_rope_runs(result: Result, geo_kinds: PackedByteArray, first: int, last: int) -> Array[float]:
	var heights: Array[float] = []
	var i := first
	while i < last:
		if geo_kinds[i] != Kind.RAPPEL:
			i += 1
			continue
		var j := i
		while j < last and geo_kinds[j] == Kind.RAPPEL:
			j += 1
		heights.append(absf(result.points[i].y - result.points[j].y))
		i = j
	return heights


## Steepest mean slope over SUSTAINED_WINDOW consecutive voluntary, non-rope steps
static func _sustained_slope(slopes: PackedFloat32Array, kinds: PackedByteArray) -> float:
	var eligible := PackedFloat32Array()
	var best := 0.0
	for i in range(slopes.size()):
		if kinds[i] == Kind.RAPPEL or kinds[i] == Kind.ADRIFT:
			# A break in the stretch: score what came before
			best = maxf(best, _window_max(eligible))
			eligible.clear()
			continue
		eligible.append(slopes[i])
	return maxf(best, _window_max(eligible))


static func _window_max(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var window := mini(SUSTAINED_WINDOW, values.size())
	var sum := 0.0
	for i in range(window):
		sum += values[i]
	var best := sum / float(window)
	for i in range(window, values.size()):
		sum += values[i] - values[i - window]
		best = maxf(best, sum / float(window))
	return best


## Metres of firm or packed snow at 25 deg or more (crampon ground)
static func _hard_snow_metres(result: Result, slopes: PackedFloat32Array, surfaces: PackedInt32Array, kinds: PackedByteArray) -> float:
	var metres := 0.0
	for i in range(slopes.size()):
		if kinds[i] == Kind.RAPPEL or slopes[i] < GameEnums.SLOPE_THRESHOLDS.walkable_max:
			continue
		var surface := surfaces[i]
		if surface == GameEnums.SurfaceType.SNOW_FIRM or surface == GameEnums.SurfaceType.SNOW_PACKED:
			metres += result.distances[i + 1] - result.distances[i]
	return metres


# =============================================================================
# DESCRIPTION
# =============================================================================

## A guidebook topo line for a pitch: altitudes, length, character, warnings.
## Altitudes are what an altimeter shows; nothing is marked on the mountain.
static func describe_pitch(pitch: Pitch, ascending: bool = false) -> String:
	var range_text := "%d → %d m" % [roundi(pitch.start_elevation), roundi(pitch.end_elevation)]
	var slope_text := "%d–%d°" % [roundi(pitch.min_slope), roundi(pitch.max_slope)]
	if roundi(pitch.min_slope) == roundi(pitch.max_slope):
		slope_text = "%d°" % roundi(pitch.max_slope)
	var surface_name := surface_word(pitch.surface)
	var body := ""
	match pitch.kind:
		Kind.WALK:
			body = "%d m of %s, %s" % [roundi(pitch.length), surface_name, slope_text]
		Kind.STEEP:
			body = "%d m steep %s, %s: a slip here slides" % [roundi(pitch.length), surface_name, slope_text]
		Kind.DOWNCLIMB:
			var verb := "Climb" if ascending else "Downclimb"
			body = "%s %d m facing in, %s %s" % [verb, roundi(pitch.length), surface_name, slope_text]
		Kind.RAPPEL:
			if ascending:
				body = "Cliff band, %d m high: no way up without a fixed line" % roundi(pitch.get_height())
			elif pitch.rappels == 1:
				body = "Cliff band: one abseil of %d m" % roundi(pitch.get_height())
			else:
				body = "Cliff band: %d abseils, %d m in all" % [pitch.rappels, roundi(pitch.get_height())]
		Kind.GLIDE:
			body = "%d m glided or skied, %s" % [roundi(pitch.length), slope_text]
		Kind.ADRIFT:
			body = "%d m out of control" % roundi(pitch.length)
	var notes: Array[String] = []
	if pitch.icy:
		notes.append("ice")
	if pitch.exposed and pitch.kind != Kind.RAPPEL:
		notes.append("exposed")
	var text := "%s · %s" % [range_text, body]
	if not notes.is_empty():
		text += " (%s)" % ", ".join(notes)
	return text


## Plain word for a surface, as a guidebook writes it
static func surface_word(surface: int) -> String:
	match surface:
		GameEnums.SurfaceType.SNOW_FIRM, GameEnums.SurfaceType.SNOW_PACKED:
			return "firm snow"
		GameEnums.SurfaceType.SNOW_SOFT:
			return "soft snow"
		GameEnums.SurfaceType.SNOW_POWDER:
			return "powder"
		GameEnums.SurfaceType.ICE:
			return "ice"
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY:
			return "rock"
		GameEnums.SurfaceType.ROCK_WET:
			return "wet rock"
		GameEnums.SurfaceType.SCREE:
			return "scree"
		GameEnums.SurfaceType.MIXED:
			return "mixed ground"
		GameEnums.SurfaceType.GRASS:
			return "grass"
		GameEnums.SurfaceType.MUD:
			return "mud"
	return "ground"


## Game minutes as "1h 25m"
static func format_minutes(minutes: float) -> String:
	var total := roundi(minutes)
	if total >= 60:
		return "%dh %02dm" % [total / 60, total % 60]
	return "%dm" % total
