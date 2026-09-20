class_name HorizonRange
extends Node3D
## Distant mountain ranges ringing the playable terrain, plus a hazy valley
## floor beneath them, so the world no longer ends at the edge of the 640 m
## heightfield. Two rings of ridges at different radii give parallax as the
## climber descends; the depth fog's aerial perspective does the rest.
## Built once per mountain from seeded noise with SurfaceTool (vertex
## colours, no assets). Purely visual: nothing here has collision.

# =============================================================================
# CONSTANTS
# =============================================================================

## Segments around each ring
const RING_SEGMENTS := 360

## Ring radii (metres from the terrain centre). The climber starts on the
## highest ground around, so most crests sit a little below eye level with
## only the odd peak above it; the far ring must stay inside the camera's
## 4 km far plane including its back slope
const NEAR_RADIUS := 2000.0
const FAR_RADIUS := 3200.0

## Crest elevation range of each ring as a fraction of the playable
## terrain's range (0 = lowest terrain, 1 = summit), plus metres above the
## summit for the tallest peaks
const NEAR_CREST_LOW := 0.15
const NEAR_CREST_HIGH_ABOVE_MAX := 160.0
const FAR_CREST_LOW := 0.35
const FAR_CREST_HIGH_ABOVE_MAX := 380.0

## The valley floor sits this far below the lowest playable terrain
const FLOOR_BELOW_MIN := 150.0

## Snow covers the ranges above this fraction of the terrain's elevation
## range (mottled by noise); bare rock shows below it
const SNOW_LINE_FRACTION := 0.5

## Valley floor disc radius
const FLOOR_RADIUS := 4200.0

## Vertex colours
const SNOW_COLOR := Color(0.90, 0.92, 0.97)
const SNOW_SHADE := Color(0.78, 0.82, 0.90)
const ROCK_COLOR := Color(0.38, 0.36, 0.37)
const ROCK_DARK := Color(0.26, 0.25, 0.27)

# =============================================================================
# STATE
# =============================================================================

## Valley floor disc; its colour tracks the fog colour every refresh
var _floor: MeshInstance3D
var _floor_material: StandardMaterial3D

## Ridge rings
var _rings: Array[MeshInstance3D] = []

## Material shared by both rings
var _ridge_material: StandardMaterial3D

## What the current geometry was built for (skip identical rebuilds)
var _built_key: String = ""


# =============================================================================
# LIFECYCLE
# =============================================================================

func _init() -> void:
	name = "HorizonRange"

	_ridge_material = StandardMaterial3D.new()
	_ridge_material.vertex_color_use_as_albedo = true
	_ridge_material.roughness = 0.95
	_ridge_material.metallic = 0.0
	_ridge_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# The ranges fade out as the fog thickens (see set_fade): fully fogged
	# geometry and the fogged sky never match exactly, and the ghost of a
	# ridge line through a whiteout gives the horizon away
	_ridge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ridge_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS

	_floor_material = StandardMaterial3D.new()
	_floor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_floor_material.albedo_color = Color(0.72, 0.78, 0.86)

	_floor = MeshInstance3D.new()
	_floor.name = "ValleyFloor"
	var disc := CylinderMesh.new()
	disc.top_radius = FLOOR_RADIUS
	disc.bottom_radius = FLOOR_RADIUS
	disc.height = 0.5
	disc.radial_segments = 48
	disc.rings = 1
	_floor.mesh = disc
	_floor.material_override = _floor_material
	_floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor.ignore_occlusion_culling = true
	add_child(_floor)


# =============================================================================
# PUBLIC API
# =============================================================================

## (Re)build the ranges around [param center] for terrain spanning
## [param ground_min] .. [param ground_max] metres of elevation.
func build(center: Vector3, ground_min: float, ground_max: float, range_seed: int) -> void:
	var key := "%s|%.1f|%.1f|%d" % [str(center), ground_min, ground_max, range_seed]
	if key == _built_key:
		return
	_built_key = key

	for ring in _rings:
		ring.queue_free()
	_rings.clear()

	var floor_y := ground_min - FLOOR_BELOW_MIN
	_floor.position = Vector3(center.x, floor_y, center.z)
	var span := maxf(ground_max - ground_min, 50.0)
	var snow_line := ground_min + span * SNOW_LINE_FRACTION

	var near := _build_ring(
		center, NEAR_RADIUS, floor_y, snow_line,
		ground_min + span * NEAR_CREST_LOW, ground_max + NEAR_CREST_HIGH_ABOVE_MAX,
		range_seed, 0
	)
	near.name = "NearRange"
	add_child(near)
	_rings.append(near)

	var far := _build_ring(
		center, FAR_RADIUS, floor_y, snow_line,
		ground_min + span * FAR_CREST_LOW, ground_max + FAR_CREST_HIGH_ABOVE_MAX,
		range_seed, 1
	)
	far.name = "FarRange"
	add_child(far)
	_rings.append(far)

	print("[HorizonRange] Built two ranges around %s (floor %.0f m, snow line %.0f m, crests up to %.0f m)" % [
		str(center), floor_y, snow_line, ground_max + FAR_CREST_HIGH_ABOVE_MAX
	])


## The valley floor takes the colour of the haze so its edge never shows
func set_haze_color(color: Color) -> void:
	_floor_material.albedo_color = Color(color.r, color.g, color.b, 1.0)


## Opacity of the ridges (1 = clear day, 0 = swallowed by the murk)
func set_fade(alpha: float) -> void:
	alpha = clampf(alpha, 0.0, 1.0)
	_ridge_material.albedo_color = Color(1.0, 1.0, 1.0, alpha)
	for ring in _rings:
		ring.visible = alpha > 0.01


# =============================================================================
# GEOMETRY
# =============================================================================

## One ring of ridges: a crest line from ridged noise, a front slope down to
## the floor facing the terrain, and a shorter back slope so the crest is
## never a knife edge when seen from above.
func _build_ring(
	center: Vector3, radius: float, floor_y: float, snow_line: float,
	crest_min: float, crest_max: float, range_seed: int, ring_index: int
) -> MeshInstance3D:
	var noise := FastNoiseLite.new()
	noise.seed = range_seed + ring_index * 7919
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.frequency = 1.0

	# Crest heights and snow lines around the ring. Noise is sampled on a
	# circle so the profile is seamless where the ring closes.
	var crests := PackedFloat32Array()
	var snow_lines := PackedFloat32Array()
	var foot_offsets := PackedFloat32Array()
	crests.resize(RING_SEGMENTS + 1)
	snow_lines.resize(RING_SEGMENTS + 1)
	foot_offsets.resize(RING_SEGMENTS + 1)
	for s in range(RING_SEGMENTS + 1):
		var angle := TAU * float(s % RING_SEGMENTS) / float(RING_SEGMENTS)
		var cx := cos(angle)
		var sz := sin(angle)
		# Massifs: a broad envelope decides where the range is high and
		# where it drops to a low col or a gap
		var massif := noise.get_noise_2d(cx * 1.3 + 40.0, sz * 1.3 + 40.0) * 0.5 + 0.5
		massif = smoothstep(0.15, 0.85, massif)
		# Ridged noise: sharp peaks along the massif with cols between them
		var ridge := 1.0 - absf(noise.get_noise_2d(cx * 5.0, sz * 5.0))
		var fine := noise.get_noise_2d(cx * 16.0 + 80.0, sz * 16.0 + 80.0)
		var t := clampf(massif * (0.45 + ridge * 0.55) + fine * 0.08, 0.0, 1.0)
		crests[s] = lerpf(crest_min, crest_max, t * t * 0.6 + t * 0.4)
		snow_lines[s] = snow_line + noise.get_noise_2d(cx * 4.0 + 120.0, sz * 4.0 + 120.0) * 70.0
		# Some faces are steep walls, others long gentle flanks
		foot_offsets[s] = noise.get_noise_2d(cx * 2.2 + 200.0, sz * 2.2 + 200.0) * 220.0

	# Row profile: (radius offset from the crest, height fraction 0 = floor, 1 = crest).
	# The front foot offset is stretched per segment by foot_offsets
	var profile: Array[Vector2] = [
		Vector2(-640.0, 0.0),
		Vector2(-430.0, 0.2),
		Vector2(-270.0, 0.45),
		Vector2(-140.0, 0.72),
		Vector2(-45.0, 0.93),
		Vector2(0.0, 1.0),
		Vector2(80.0, 0.86),
		Vector2(260.0, 0.45),
		Vector2(480.0, 0.0),
	]

	var rows: Array[PackedVector3Array] = []
	var row_colors: Array[PackedColorArray] = []
	for r in range(profile.size()):
		var row := PackedVector3Array()
		var colors := PackedColorArray()
		row.resize(RING_SEGMENTS + 1)
		colors.resize(RING_SEGMENTS + 1)
		for s in range(RING_SEGMENTS + 1):
			var angle := TAU * float(s % RING_SEGMENTS) / float(RING_SEGMENTS)
			var cx := cos(angle)
			var sz := sin(angle)
			# Wobble the slope so faces catch the light unevenly
			var wobble := noise.get_noise_2d(cx * 6.0 + r * 13.0, sz * 6.0 + r * 13.0)
			var offset := profile[r].x
			if offset < 0.0:
				offset *= 1.0 + foot_offsets[s] / 640.0
			var ring_radius := radius + offset + wobble * 25.0
			var height := lerpf(floor_y, crests[s], profile[r].y)
			if r != 5:
				height += wobble * 30.0 * profile[r].y * (1.0 - profile[r].y)
			row[s] = Vector3(center.x + cx * ring_radius, height, center.z + sz * ring_radius)
			colors[s] = _ridge_color(height, snow_lines[s], wobble)
		rows.append(row)
		row_colors.append(colors)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in range(profile.size() - 1):
		var a_row := rows[r]
		var b_row := rows[r + 1]
		var a_col := row_colors[r]
		var b_col := row_colors[r + 1]
		for s in range(RING_SEGMENTS):
			var a0 := a_row[s]
			var a1 := a_row[s + 1]
			var b0 := b_row[s]
			var b1 := b_row[s + 1]
			# Faces should point toward the terrain centre (and up)
			var mid := (a0 + a1 + b0 + b1) * 0.25
			var want := (Vector3(center.x, mid.y, center.z) - mid).normalized() + Vector3.UP * 0.5
			_add_tri(st, a0, b0, a1, a_col[s], b_col[s], a_col[s + 1], want)
			_add_tri(st, a1, b0, b1, a_col[s + 1], b_col[s], b_col[s + 1], want)
	st.generate_normals()
	var mesh := st.commit()

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _ridge_material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.ignore_occlusion_culling = true
	return instance


## Add a triangle wound so its normal faces [param want]
func _add_tri(
	st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
	ca: Color, cb: Color, cc: Color, want: Vector3
) -> void:
	# Plane(a, b, c).normal is what SurfaceTool.generate_normals() computes
	# for this winding, so test the same thing and flip when it faces away
	if Plane(a, b, c).normal.dot(want) < 0.0:
		var tmp_v := b
		b = c
		c = tmp_v
		var tmp_c := cb
		cb = cc
		cc = tmp_c
	st.set_color(ca)
	st.add_vertex(a)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_color(cc)
	st.add_vertex(c)


## Snow above the snow line, rock below, with a soft mottled blend
func _ridge_color(height: float, snow_line: float, wobble: float) -> Color:
	var snow_mix := smoothstep(snow_line - 60.0, snow_line + 60.0, height + wobble * 40.0)
	var rock := ROCK_COLOR.lerp(ROCK_DARK, clampf(wobble * 0.5 + 0.5, 0.0, 1.0))
	var snow := SNOW_COLOR.lerp(SNOW_SHADE, clampf(wobble * 0.5 + 0.5, 0.0, 1.0))
	return rock.lerp(snow, snow_mix)
