class_name SummitGoal
extends Node3D
## The summit: a stone cairn with a string of faded prayer flags, built from
## primitives. It stands on every run (you start beside it on a descent), and
## it carries no label, beacon or marker: you know you are on top because the
## ground falls away on every side and the cairn is there.
##
## On a full route it is also the turn: reaching the top of the summit
## plateau during the ascent marks the summit (RunContext.reach_summit) and
## the way home begins.

# =============================================================================
# CONSTANTS
# =============================================================================

## How close to the highest point counts as the summit (metres, XZ); the
## generator's summit plateau has a 9 m radius
const SUMMIT_RADIUS := 7.0
## The cairn stands this far from the summit centre, so a descent's spawn
## point is clear of it (metres)
const CAIRN_OFFSET := Vector3(2.6, 0.0, -1.8)

const STONE_COLORS: Array[Color] = [
	Color(0.38, 0.36, 0.34), Color(0.45, 0.43, 0.4), Color(0.32, 0.31, 0.3)
]
const FLAG_COLORS: Array[Color] = [
	Color(0.32, 0.45, 0.7), Color(0.85, 0.85, 0.82), Color(0.72, 0.28, 0.24),
	Color(0.36, 0.6, 0.36), Color(0.85, 0.72, 0.3)
]

# =============================================================================
# STATE
# =============================================================================

## Summit centre on the ground
var summit_position: Vector3 = Vector3.ZERO

## Explicit player reference (main sets this; ServiceLocator is the fallback)
var player_ref: Node3D = null

## True once this run's summit has been reached (fires once)
var has_fired: bool = false

var _terrain: TerrainService = null


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	name = "SummitGoal"
	_terrain = ServiceLocator.get_service("TerrainService") as TerrainService
	if _terrain != null and _terrain.start_position != Vector3.ZERO:
		summit_position = _terrain.start_position
		summit_position.y = _terrain.get_height_at(summit_position)
	global_position = summit_position
	_build_cairn()


func _physics_process(_delta: float) -> void:
	if has_fired:
		return
	if GameStateManager.current_state != GameEnums.GameState.DESCENT:
		return
	var run := GameStateManager.current_run
	if run == null or run.is_complete or not run.is_full_route() or run.summit_reached:
		return
	var player := _find_player()
	if player == null:
		return
	if get_distance_to_summit(player.global_position) <= SUMMIT_RADIUS:
		_reach_summit(run)


## Horizontal (XZ) distance from a world position to the summit centre
func get_distance_to_summit(world_pos: Vector3) -> float:
	return Vector2(world_pos.x - summit_position.x, world_pos.z - summit_position.z).length()


func _reach_summit(run: RunContext) -> void:
	has_fired = true
	run.reach_summit()
	EventBus.summit_reached.emit(run)
	var clock := "%02d:%02d" % [int(run.current_time), int(fmod(run.current_time * 60.0, 60.0))]
	EventBus.diegetic_message.emit("The summit, %s. Halfway: now get down." % clock, 5.0)
	print("[SummitGoal] Summit reached at %s (%.0f m)" % [clock, summit_position.y])


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

func _build_cairn() -> void:
	var cairn := Node3D.new()
	cairn.name = "Cairn"
	cairn.position = CAIRN_OFFSET
	if _terrain != null:
		var ground := _terrain.get_height_at(summit_position + CAIRN_OFFSET)
		cairn.position.y = ground - summit_position.y
	add_child(cairn)

	# Stacked stones, wide at the bottom, a little off-plumb
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(summit_position))
	var y := 0.0
	var sizes: Array[float] = [0.95, 0.8, 0.66, 0.52, 0.4, 0.28]
	for i in range(sizes.size()):
		var size := sizes[i]
		var stone := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = size * 0.5
		mesh.height = size * 0.62
		mesh.radial_segments = 7
		mesh.rings = 4
		mesh.material = _make_material(STONE_COLORS[i % STONE_COLORS.size()], 0.95)
		stone.mesh = mesh
		stone.position = Vector3(rng.randf_range(-0.06, 0.06), y + size * 0.28, rng.randf_range(-0.06, 0.06))
		stone.rotation = Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(0.0, TAU), rng.randf_range(-0.2, 0.2))
		cairn.add_child(stone)
		y += size * 0.5

	# A pole wedged in the top, and a line of flags running down to a stone
	var pole_height := 1.6
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.02
	pole_mesh.bottom_radius = 0.03
	pole_mesh.height = pole_height
	pole_mesh.radial_segments = 6
	pole_mesh.material = _make_material(Color(0.42, 0.34, 0.24), 0.9)
	pole.mesh = pole_mesh
	pole.position = Vector3(0.0, y + pole_height * 0.5 - 0.1, 0.0)
	cairn.add_child(pole)

	var top := Vector3(0.0, y + pole_height - 0.15, 0.0)
	var anchor := Vector3(3.2, 0.25, 1.4)
	if _terrain != null:
		var anchor_world := global_position + cairn.position + anchor
		anchor.y = _terrain.get_height_at(anchor_world) - (summit_position.y + cairn.position.y) + 0.25
	var flags := 9
	for k in range(flags):
		var t := (float(k) + 0.5) / float(flags)
		var p := top.lerp(anchor, t)
		p.y -= sin(t * PI) * 0.35  # sag
		var flag := MeshInstance3D.new()
		var quad := BoxMesh.new()
		quad.size = Vector3(0.22, 0.17, 0.01)
		var material := _make_material(FLAG_COLORS[k % FLAG_COLORS.size()], 0.9)
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		quad.material = material
		flag.mesh = quad
		flag.position = p - Vector3(0.0, 0.09, 0.0)
		flag.rotation.y = atan2(anchor.x - top.x, anchor.z - top.z) + PI * 0.5
		flag.rotation.z = rng.randf_range(-0.12, 0.12)
		cairn.add_child(flag)


func _make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
