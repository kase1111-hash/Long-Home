class_name ScatterMeshes
extends RefCounted
## Low-poly meshes for the objects scattered over a mountain: conifers,
## krummholz shrubs, dead snags, boulders and small rocks. Built from
## primitives with SurfaceTool, flat-shaded, coloured per vertex, with snow
## dusted on the up-facing faces.
##
## Every mesh is authored in a unit frame: base on y = 0, height 1 (trees,
## shrubs, snags) or about 1 m across (rocks), so an instance's scale is its
## size in metres.
##
## Swapping in better meshes: put a Mesh resource (.tres/.res/.mesh) or a
## model scene (.glb/.gltf/.tscn/.scn) in res://assets/scatter/ named
## <kind>_<variant> (e.g. conifer_0.glb, boulder_2.tres) or just <kind> for
## every variant. load_override() returns it with a transform that fits it
## into the unit frame from its bounding box, so it can be authored at any
## scale; its own materials are kept.

# =============================================================================
# CONSTANTS
# =============================================================================

const OVERRIDE_EXTENSIONS: Array[String] = ["tres", "res", "mesh", "glb", "gltf", "tscn", "scn"]

const TRUNK_COLOR := Color(0.32, 0.21, 0.13)
const SNAG_COLOR := Color(0.55, 0.52, 0.47)
const SNOW_COLOR := Color(0.92, 0.94, 0.97)
const FOLIAGE_COLORS: Array[Color] = [
	Color(0.13, 0.27, 0.16),  # Spruce: dark, blue-green
	Color(0.17, 0.32, 0.17),  # Fir: green
	Color(0.21, 0.33, 0.15),  # Young pine: yellow-green
]
const SHRUB_COLORS: Array[Color] = [
	Color(0.2, 0.3, 0.16),
	Color(0.27, 0.31, 0.17),
]
const ROCK_COLORS: Array[Color] = [
	Color(0.47, 0.45, 0.42),  # Grey granite
	Color(0.52, 0.45, 0.4),   # Warm granite
	Color(0.36, 0.35, 0.34),  # Dark basalt
	Color(0.6, 0.58, 0.54),   # Pale limestone
]
const LICHEN_COLOR := Color(0.55, 0.56, 0.36)


# =============================================================================
# OVERRIDES
# =============================================================================

## A replacement mesh for a kind/variant, or {} when none is installed.
## Returns {"mesh": Mesh, "fit": Transform3D} where fit maps the mesh into the
## unit frame (base at y = 0, height 1).
static func load_override(directory: String, kind_name: String, variant: int) -> Dictionary:
	if directory.is_empty():
		return {}
	for base_name in ["%s_%d" % [kind_name, variant], kind_name]:
		for extension in OVERRIDE_EXTENSIONS:
			var path := "%s/%s.%s" % [directory, base_name, extension]
			if not ResourceLoader.exists(path):
				continue
			var mesh := _mesh_from_resource(load(path))
			if mesh == null:
				continue
			return {"mesh": mesh, "fit": fit_to_unit(mesh.get_aabb())}
	return {}


## Transform that puts a mesh with this bounding box base-down at y = 0,
## 1 unit tall
static func fit_to_unit(aabb: AABB) -> Transform3D:
	var height := maxf(aabb.size.y, 0.001)
	var scale := 1.0 / height
	return Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3(0.0, -aabb.position.y * scale, 0.0))


static func _mesh_from_resource(resource: Resource) -> Mesh:
	if resource is Mesh:
		return resource
	if resource is PackedScene:
		var scene: Node = (resource as PackedScene).instantiate()
		var found := _first_mesh(scene)
		scene.free()
		return found
	return null


static func _first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var mesh := _first_mesh(child)
		if mesh != null:
			return mesh
	return null


# =============================================================================
# TREES
# =============================================================================

## A conifer: a hexagonal trunk under stacked seven-sided cones.
##   style 0 spruce (slim, four tiers), 1 fir (broad, three), 2 young pine (two, round)
static func build_conifer(seed_value: int, style: int, snow: float) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var foliage: Color = FOLIAGE_COLORS[clampi(style, 0, FOLIAGE_COLORS.size() - 1)]

	var tiers := 5
	var width := 0.2
	var first_base := 0.08
	var tier_height := 0.3
	var trunk_top := 0.22
	match style:
		1:
			tiers = 4
			width = 0.25
			first_base = 0.07
			tier_height = 0.36
		2:
			tiers = 3
			width = 0.25
			first_base = 0.14
			tier_height = 0.42
			trunk_top = 0.3

	_add_prism(st, Vector3.ZERO, 0.032, trunk_top, 6, TRUNK_COLOR, 0.0)

	var step := (1.0 - first_base - tier_height) / maxf(1.0, float(tiers - 1))
	for i in range(tiers):
		var base_y := first_base + step * float(i)
		var top_y := base_y + tier_height
		if i == tiers - 1:
			top_y = 1.0
		var t := float(i) / maxf(1.0, float(tiers - 1))
		var radius := width * lerpf(1.0, 0.4, t) * rng.randf_range(0.9, 1.1)
		var apex_offset := Vector3(rng.randf_range(-0.015, 0.015), 0.0, rng.randf_range(-0.015, 0.015))
		var tint := foliage * rng.randf_range(0.9, 1.1)
		tint.a = 1.0
		# Higher tiers catch more snow
		_add_cone(st, rng, Vector3(0.0, base_y, 0.0), radius, top_y - base_y, 7, tint, snow * lerpf(0.75, 1.1, t), apex_offset)

	return _commit(st)


## Krummholz: wind-flattened dwarf conifer, wider than tall
static func build_shrub(seed_value: int, style: int, snow: float) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var color: Color = SHRUB_COLORS[clampi(style, 0, SHRUB_COLORS.size() - 1)]
	var lobes := 3 + style
	for i in range(lobes):
		var angle := TAU * float(i) / float(lobes) + rng.randf_range(-0.4, 0.4)
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(0.18, 0.42)
		var tint := color * rng.randf_range(0.88, 1.12)
		tint.a = 1.0
		_add_cone(st, rng, offset + Vector3(0.0, -0.05, 0.0), rng.randf_range(0.42, 0.62), rng.randf_range(0.7, 1.0), 6, tint, snow, Vector3.ZERO)
	_add_cone(st, rng, Vector3(0.0, -0.05, 0.0), 0.5, 1.05, 6, color, snow, Vector3.ZERO)
	return _commit(st)


## A dead snag: a grey, branch-stubbed trunk at the treeline
static func build_snag(seed_value: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	# Tapered trunk in two stacked prisms
	_add_frustum(st, Vector3.ZERO, 0.045, 0.03, 0.55, 6, SNAG_COLOR)
	_add_frustum(st, Vector3(0.0, 0.55, 0.0), 0.03, 0.012, 0.45, 6, SNAG_COLOR * 1.05)
	# Bare branch stubs
	var stubs := rng.randi_range(4, 6)
	for i in range(stubs):
		var y := rng.randf_range(0.3, 0.9)
		var angle := rng.randf_range(0.0, TAU)
		var length := rng.randf_range(0.08, 0.2) * (1.1 - y * 0.6)
		var direction := Vector3(cos(angle), rng.randf_range(0.15, 0.6), sin(angle)).normalized()
		_add_stick(st, Vector3(0.0, y, 0.0), direction, length, 0.009, SNAG_COLOR * 0.92)
	return _commit(st)


# =============================================================================
# ROCKS
# =============================================================================

## A boulder: a lumpy, squashed icosphere, flat-shaded, with lichen and snow
## on top. About 1 unit across, 0.7 tall, sitting slightly into the ground.
static func build_boulder(seed_value: int, style: int, snow: float, subdivisions: int = 1) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var base: Color = ROCK_COLORS[clampi(style, 0, ROCK_COLORS.size() - 1)]

	var sphere := _icosphere(subdivisions)
	var verts: PackedVector3Array = sphere[0]
	var faces: PackedInt32Array = sphere[1]
	var stretch := Vector3(rng.randf_range(0.9, 1.15), rng.randf_range(0.62, 0.8), rng.randf_range(0.85, 1.1))
	# Fracture planes: rock breaks along joints, so slice the lump flat in a
	# few directions (vertices beyond a plane are pulled back onto it)
	var cuts: Array[Plane] = []
	for _c in range(rng.randi_range(3, 5)):
		var direction := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 1), rng.randf_range(-1, 1)).normalized()
		cuts.append(Plane(direction, rng.randf_range(0.62, 0.85)))
	for i in range(verts.size()):
		var lump := rng.randf_range(0.86, 1.12)
		var v := verts[i] * lump
		for cut in cuts:
			var over := cut.distance_to(v)
			if over > 0.0:
				v -= cut.normal * over
		verts[i] = Vector3(v.x * 0.5 * stretch.x, v.y * 0.5 * stretch.y + 0.2, v.z * 0.5 * stretch.z)

	for f in range(0, faces.size(), 3):
		var a := verts[faces[f]]
		var b := verts[faces[f + 1]]
		var c := verts[faces[f + 2]]
		var normal := (b - a).cross(c - a).normalized()
		# Faces vary like broken rock; undersides sit in their own shadow
		var color := base * rng.randf_range(0.8, 1.08) * lerpf(0.7, 1.0, clampf(normal.y + 0.6, 0.0, 1.0))
		if normal.y > -0.2 and rng.randf() < 0.14:
			color = color.lerp(LICHEN_COLOR, 0.35)
		color = _snowed(color, normal, snow * 0.6)
		color.a = 1.0
		_add_triangle(st, a, b, c, color)
	return _commit(st)


## Small rock: a coarse, squashed icosahedron
static func build_rock(seed_value: int, style: int, snow: float) -> ArrayMesh:
	return build_boulder(seed_value, style, snow * 0.8, 0)


# =============================================================================
# PRIMITIVES
# =============================================================================

static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


static func _commit(st: SurfaceTool) -> ArrayMesh:
	return st.commit()


## One flat-shaded triangle (counter-clockwise seen from outside)
static func _add_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < 1.0e-12:
		return
	normal = normal.normalized()
	st.set_color(color)
	st.set_normal(normal)
	# Godot's front faces wind clockwise
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)


## Snow on up-facing faces
static func _snowed(color: Color, normal: Vector3, snow: float) -> Color:
	if snow <= 0.0 or normal.y <= 0.3:
		return color
	var amount := clampf((normal.y - 0.3) / 0.6, 0.0, 1.0) * clampf(snow, 0.0, 1.0)
	return color.lerp(SNOW_COLOR, amount)


## A cone with a jagged rim: the low-poly conifer tier
static func _add_cone(
	st: SurfaceTool, rng: RandomNumberGenerator, base_center: Vector3, radius: float,
	height: float, sides: int, color: Color, snow: float, apex_offset: Vector3
) -> void:
	var apex := base_center + Vector3(0.0, height, 0.0) + apex_offset
	var rim: Array[Vector3] = []
	var phase := rng.randf_range(0.0, TAU)
	for i in range(sides):
		var angle := phase + TAU * float(i) / float(sides)
		var r := radius * rng.randf_range(0.85, 1.12)
		# Branch tips hang below where they leave the trunk
		var droop := -rng.randf_range(0.04, 0.12) * height
		rim.append(base_center + Vector3(cos(angle) * r, droop, sin(angle) * r))
	# Hollow underside: seen from below a tier is a skirt of branches, not a disc
	var center := base_center + Vector3(0.0, height * 0.32, 0.0)
	var under := color * 0.8
	under.a = 1.0
	for i in range(sides):
		var a := rim[i]
		var b := rim[(i + 1) % sides]
		var normal := (apex - a).cross(b - a).normalized()
		# Side faces point outward and up
		var shade := color * rng.randf_range(0.92, 1.06)
		shade.a = 1.0
		_add_triangle(st, a, apex, b, _snowed(shade, -normal if normal.y < 0.0 else normal, snow))
		# Underside, so the tier is closed when seen from below on a slope
		_add_triangle(st, b, center, a, under)


## Straight prism (trunk)
static func _add_prism(st: SurfaceTool, base_center: Vector3, radius: float, height: float, sides: int, color: Color, _snow: float) -> void:
	_add_frustum(st, base_center, radius, radius * 0.8, height, sides, color)


static func _add_frustum(st: SurfaceTool, base_center: Vector3, bottom_radius: float, top_radius: float, height: float, sides: int, color: Color) -> void:
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := base_center + Vector3(cos(a0) * bottom_radius, 0.0, sin(a0) * bottom_radius)
		var b1 := base_center + Vector3(cos(a1) * bottom_radius, 0.0, sin(a1) * bottom_radius)
		var t0 := base_center + Vector3(cos(a0) * top_radius, height, sin(a0) * top_radius)
		var t1 := base_center + Vector3(cos(a1) * top_radius, height, sin(a1) * top_radius)
		var shade := color * (0.85 + 0.15 * cos(a0 * 1.0))
		shade.a = 1.0
		_add_triangle(st, b0, t0, b1, shade)
		_add_triangle(st, b1, t0, t1, shade)


## A thin square stick from a point along a direction (branch stub)
static func _add_stick(st: SurfaceTool, origin: Vector3, direction: Vector3, length: float, thickness: float, color: Color) -> void:
	var tip := origin + direction * length
	var side := direction.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized() * thickness
	var up := side.cross(direction).normalized() * thickness
	var corners: Array[Vector3] = [side + up, -side + up, -side - up, side - up]
	var shade := color
	shade.a = 1.0
	for i in range(4):
		var c0 := corners[i]
		var c1 := corners[(i + 1) % 4]
		_add_triangle(st, origin + c0, tip + c0 * 0.4, origin + c1, shade)
		_add_triangle(st, origin + c1, tip + c0 * 0.4, tip + c1 * 0.4, shade)


## Unit icosphere: [vertices, triangle indices]
static func _icosphere(subdivisions: int) -> Array:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts := PackedVector3Array([
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	])
	for i in range(verts.size()):
		verts[i] = verts[i].normalized()
	var faces := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	for _s in range(subdivisions):
		# Packed arrays are passed by value, so midpoints are added here
		var midpoints := {}
		var next := PackedInt32Array()
		for f in range(0, faces.size(), 3):
			var corner := [faces[f], faces[f + 1], faces[f + 2]]
			var mids: Array[int] = []
			for e in range(3):
				var i0: int = corner[e]
				var i1: int = corner[(e + 1) % 3]
				var key := Vector2i(mini(i0, i1), maxi(i0, i1))
				if not midpoints.has(key):
					verts.append(((verts[i0] + verts[i1]) * 0.5).normalized())
					midpoints[key] = verts.size() - 1
				mids.append(midpoints[key])
			var a: int = corner[0]
			var b: int = corner[1]
			var c: int = corner[2]
			var ab := mids[0]
			var bc := mids[1]
			var ca := mids[2]
			next.append_array(PackedInt32Array([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]))
		faces = next
	return [verts, faces]
