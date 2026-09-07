class_name DescentGoal
extends Node3D
## Base camp: the end of the descent.
##
## Built from primitives only (no imported assets): a tent, a flag pole, a
## warm light and a tall translucent beam so the goal can be picked out from
## the summit. Every physics frame during DESCENT it checks whether the
## player has walked into the camp and completes the run once.
##
## Goal placement comes from TerrainService (goal_position / goal_radius).
## When the terrain has no goal yet, the lowest corner of the terrain bounds
## is used so a run is always completable.

# =============================================================================
# CONSTANTS
# =============================================================================

## Beam dimensions (metres)
const BEAM_RADIUS := 1.5
const BEAM_HEIGHT := 80.0

## Flag pole
const POLE_HEIGHT := 6.0

## How far below the terrain floor counts as "fell off the mountain"
const FALL_MARGIN := 100.0

## Inset from the terrain edge when falling back to a bounds corner
const BOUNDS_INSET := 0.08

## Palette
const TENT_COLOR := Color(0.92, 0.28, 0.1)
const TENT_DOOR_COLOR := Color(0.98, 0.55, 0.2)
const FLAG_COLOR := Color(1.0, 0.82, 0.2)
const POLE_COLOR := Color(0.55, 0.55, 0.58)
const CRATE_COLOR := Color(0.35, 0.28, 0.2)
const LIGHT_COLOR := Color(1.0, 0.8, 0.55)
const BEAM_COLOR := Color(1.0, 0.76, 0.42, 0.25)

# =============================================================================
# STATE
# =============================================================================

## Resolved goal centre (y = ground height)
var goal_position: Vector3 = Vector3.ZERO

## Radius of the camp area (metres, XZ)
var goal_radius: float = 15.0

## True once the goal has ended the run (fires once per run)
var has_fired: bool = false

## Explicit player reference (main sets this; ServiceLocator is the fallback)
var player_ref: Node3D = null

var _terrain: TerrainService = null
var _light: OmniLight3D = null

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	name = "DescentGoal"
	_terrain = ServiceLocator.get_service("TerrainService") as TerrainService
	_resolve_goal()
	global_position = goal_position
	_build_camp()
	print("[DescentGoal] Base camp at %s, radius %.1f m" % [goal_position, goal_radius])


func _physics_process(_delta: float) -> void:
	if has_fired:
		return
	if GameStateManager.current_state != GameEnums.GameState.DESCENT:
		return
	if not GameStateManager.is_run_active():
		return

	var player := _find_player()
	if player == null:
		return

	var pos := player.global_position

	# Safety net: fell clean off the world
	if _has_terrain_bounds() and pos.y < _terrain.terrain_bounds_min.y - FALL_MARGIN:
		has_fired = true
		print("[DescentGoal] Player below the terrain floor (%.1f m)" % pos.y)
		GameStateManager.complete_run(GameEnums.ResolutionType.FATALITY, "Fell from the mountain")
		return

	if get_distance_to_goal(pos) < goal_radius:
		_arrive()


# =============================================================================
# PUBLIC API
# =============================================================================

## Horizontal (XZ) distance from a world position to the camp centre
func get_distance_to_goal(world_pos: Vector3) -> float:
	var dx := world_pos.x - goal_position.x
	var dz := world_pos.z - goal_position.z
	return sqrt(dx * dx + dz * dz)


# =============================================================================
# GOAL RESOLUTION
# =============================================================================

func _resolve_goal() -> void:
	if _terrain != null:
		goal_radius = maxf(_terrain.goal_radius, 1.0)

		if _terrain.goal_position != Vector3.ZERO:
			goal_position = _terrain.goal_position
			var ground := _terrain.get_height_at(goal_position)
			if ground != 0.0:
				goal_position.y = ground
			return

		if _has_terrain_bounds():
			goal_position = _lowest_bounds_corner()
			print("[DescentGoal] Terrain has no goal; using lowest terrain corner")
			return

	push_warning("[DescentGoal] No terrain goal available; camp placed at the origin")
	goal_position = Vector3.ZERO


func _has_terrain_bounds() -> bool:
	if _terrain == null:
		return false
	return _terrain.terrain_bounds_min != _terrain.terrain_bounds_max


## Lowest of the four (inset) terrain corners, at ground height
func _lowest_bounds_corner() -> Vector3:
	var bmin := _terrain.terrain_bounds_min
	var bmax := _terrain.terrain_bounds_max
	var inset_x := (bmax.x - bmin.x) * BOUNDS_INSET
	var inset_z := (bmax.z - bmin.z) * BOUNDS_INSET

	var corners: Array[Vector3] = [
		Vector3(bmin.x + inset_x, 0.0, bmin.z + inset_z),
		Vector3(bmax.x - inset_x, 0.0, bmin.z + inset_z),
		Vector3(bmin.x + inset_x, 0.0, bmax.z - inset_z),
		Vector3(bmax.x - inset_x, 0.0, bmax.z - inset_z),
	]

	var best := corners[0]
	best.y = _terrain.get_height_at(best)
	for i in range(1, corners.size()):
		var corner := corners[i]
		corner.y = _terrain.get_height_at(corner)
		if corner.y < best.y:
			best = corner
	return best


# =============================================================================
# ARRIVAL
# =============================================================================

func _arrive() -> void:
	has_fired = true
	var run := GameStateManager.current_run

	EventBus.diegetic_message.emit("Base camp. You made it home.", 4.0)

	var outcome := GameEnums.ResolutionType.CLEAN_RETURN
	if run != null and run.body_state != null and not run.body_state.injuries.is_empty():
		outcome = GameEnums.ResolutionType.INJURED_RETURN

	print("[DescentGoal] Player reached base camp (%s)" % GameEnums.ResolutionType.keys()[outcome])
	GameStateManager.complete_run(outcome, "Reached base camp")


func _find_player() -> Node3D:
	if player_ref != null and is_instance_valid(player_ref) and player_ref.is_inside_tree():
		return player_ref
	var service: Object = ServiceLocator.get_service("PlayerController")
	if not is_instance_valid(service):
		return null
	var node := service as Node3D
	if node == null or not node.is_inside_tree():
		return null
	return node


# =============================================================================
# VISUALS (primitives only)
# =============================================================================

func _build_camp() -> void:
	# Main tent, door facing the summit side (-X of camp is arbitrary; keep it simple)
	var tent := _make_tent(3.2, 2.4, 1.8, TENT_COLOR)
	tent.position = Vector3(0.0, 0.0, 0.0)
	add_child(tent)

	# Smaller second tent
	var tent_b := _make_tent(2.4, 1.9, 1.4, TENT_DOOR_COLOR)
	tent_b.position = Vector3(4.5, 0.0, 2.5)
	tent_b.rotation.y = deg_to_rad(35.0)
	add_child(tent_b)

	# Supply crates
	var crate := _make_box(Vector3(0.8, 0.6, 0.8), CRATE_COLOR)
	crate.position = Vector3(-2.6, 0.3, 1.8)
	add_child(crate)
	var crate_b := _make_box(Vector3(0.6, 0.5, 0.9), CRATE_COLOR)
	crate_b.position = Vector3(-2.0, 0.25, 2.6)
	crate_b.rotation.y = deg_to_rad(20.0)
	add_child(crate_b)

	# Flag pole + flag
	var pole := MeshInstance3D.new()
	pole.name = "FlagPole"
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.04
	pole_mesh.bottom_radius = 0.05
	pole_mesh.height = POLE_HEIGHT
	pole_mesh.radial_segments = 8
	pole_mesh.material = _make_material(POLE_COLOR, 0.4)
	pole.mesh = pole_mesh
	pole.position = Vector3(2.2, POLE_HEIGHT * 0.5, -1.5)
	add_child(pole)

	var flag := _make_box(Vector3(1.1, 0.65, 0.03), FLAG_COLOR)
	flag.name = "Flag"
	flag.position = Vector3(2.2 + 0.58, POLE_HEIGHT - 0.4, -1.5)
	add_child(flag)

	# Warm camp light
	_light = OmniLight3D.new()
	_light.name = "CampLight"
	_light.light_color = LIGHT_COLOR
	_light.light_energy = 2.5
	_light.omni_range = 28.0
	_light.omni_attenuation = 1.2
	_light.shadow_enabled = false
	_light.position = Vector3(0.8, 2.6, 0.6)
	add_child(_light)

	# Tall translucent beam so the camp reads from the summit
	var beam := MeshInstance3D.new()
	beam.name = "Beacon"
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = BEAM_RADIUS * 0.6
	beam_mesh.bottom_radius = BEAM_RADIUS
	beam_mesh.height = BEAM_HEIGHT
	beam_mesh.radial_segments = 16
	beam_mesh.rings = 1
	var beam_material := StandardMaterial3D.new()
	beam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	beam_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	beam_material.albedo_color = BEAM_COLOR
	beam_material.emission_enabled = true
	beam_material.emission = Color(BEAM_COLOR.r, BEAM_COLOR.g, BEAM_COLOR.b)
	beam_material.emission_energy_multiplier = 0.6
	beam_material.disable_receive_shadows = true
	beam_mesh.material = beam_material
	beam.mesh = beam_mesh
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position = Vector3(0.0, BEAM_HEIGHT * 0.5, 0.0)
	add_child(beam)


## Triangular-prism tent: ridge along Z, open ends filled with triangles
func _make_tent(length: float, width: float, height: float, color: Color) -> MeshInstance3D:
	var half_w := width * 0.5
	var half_l := length * 0.5

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var ridge_front := Vector3(0.0, height, -half_l)
	var ridge_back := Vector3(0.0, height, half_l)
	var left_front := Vector3(-half_w, 0.0, -half_l)
	var left_back := Vector3(-half_w, 0.0, half_l)
	var right_front := Vector3(half_w, 0.0, -half_l)
	var right_back := Vector3(half_w, 0.0, half_l)

	# Left slope (two triangles)
	_add_tri(st, left_front, ridge_front, ridge_back)
	_add_tri(st, left_front, ridge_back, left_back)
	# Right slope
	_add_tri(st, right_front, ridge_back, ridge_front)
	_add_tri(st, right_front, right_back, ridge_back)
	# Front / back end walls
	_add_tri(st, left_front, right_front, ridge_front)
	_add_tri(st, right_back, left_back, ridge_back)
	# Floor (so nothing shows through from below on slopes)
	_add_tri(st, left_front, left_back, right_back)
	_add_tri(st, left_front, right_back, right_front)

	st.generate_normals()
	var mesh := st.commit()

	var instance := MeshInstance3D.new()
	instance.name = "Tent"
	instance.mesh = mesh
	var material := _make_material(color, 0.85)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	instance.material_override = material
	return instance


func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


func _make_box(size: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	box.material = _make_material(color, 0.9)
	instance.mesh = box
	return instance


func _make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
