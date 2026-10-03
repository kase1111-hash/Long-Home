extends SceneTree
## Headless checks for the trees and boulders (TerrainScatter, ScatterMeshes):
## where they grow and lie, what stays clear, that they sit on the ground, are
## deterministic, collide, can be swapped for authored meshes, serve as rope
## anchors and show on the map; then, in a live descent, that walking into a
## boulder is blocked harmlessly and sliding into a tree hurts, and that
## incidents announced on the EventBus reach the run.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_scatter.gd
##
## A "-s" script is compiled before the autoloads exist, so project classes
## are reached with load() and autoloads through /root (see smoke_goal.gd).

const CONIFER := 0
const SNAG := 1
const SHRUB := 2
const BOULDER := 3
const ROCK := 4

var _enums: Node
var _locator: Node
var _state_manager: Node
var _main: Node
var _scatter_script: GDScript
var _meshes: GDScript
var _failures: Array[String] = []
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	if _enums == null or _locator == null or _state_manager == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_scatter_script = load("res://src/systems/terrain/terrain_scatter.gd")
	_meshes = load("res://src/systems/terrain/scatter_meshes.gd")

	_check_meshes()

	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for _i in range(4):
		await process_frame

	_main._ensure_terrain_loaded("long_way_down")
	await process_frame
	var terrain: Object = _locator.get_service("TerrainService")
	var cold_trees: int = terrain.scatter.count_by_kind()[CONIFER]

	_main._ensure_terrain_loaded("knife_edge")
	await process_frame
	_check_placement(terrain, cold_trees)
	_check_determinism(terrain)
	_check_override(terrain)
	_check_anchors(terrain)
	_check_map(terrain)
	await _check_collisions(terrain)
	_finish("")


# =============================================================================
# MESHES
# =============================================================================

func _check_meshes() -> void:
	for style in range(3):
		var tree: ArrayMesh = _meshes.build_conifer(11 + style, style, 0.6)
		var box: AABB = tree.get_aabb()
		_expect(tree.get_surface_count() == 1 and absf(box.size.y - 1.0) < 0.12 and box.position.y > -0.15,
			"conifer style %d is one unit tall, base at the ground (%.2f, %.2f)" % [style, box.size.y, box.position.y])
		_expect(box.size.x < 0.75 and box.size.z < 0.75, "conifer style %d is a slim tree (%.2f wide)" % [style, box.size.x])
	var boulder: ArrayMesh = _meshes.build_boulder(5, 1, 0.5)
	var rock_box: AABB = boulder.get_aabb()
	_expect(rock_box.size.x > 0.6 and rock_box.size.x < 1.3 and rock_box.size.y < rock_box.size.x,
		"a boulder is about a unit across and lower than wide (%.2f x %.2f)" % [rock_box.size.x, rock_box.size.y])
	_expect(rock_box.position.y < 0.0, "a boulder sits into the ground")
	var snag: ArrayMesh = _meshes.build_snag(3)
	_expect(absf(snag.get_aabb().size.y - 1.0) < 0.15, "a snag is one unit tall")
	var fit: Transform3D = _meshes.fit_to_unit(AABB(Vector3(-2, -1, -2), Vector3(4, 8, 4)))
	var top: Vector3 = fit * Vector3(0, 7, 0)
	var bottom: Vector3 = fit * Vector3(0, -1, 0)
	_expect(absf(top.y - 1.0) < 0.001 and absf(bottom.y) < 0.001, "an authored mesh of any size is fitted base-down, one unit tall")


# =============================================================================
# PLACEMENT
# =============================================================================

func _check_placement(terrain: Object, cold_trees: int) -> void:
	var scatter: Object = terrain.scatter
	var counts: Dictionary = scatter.count_by_kind()
	_expect(counts[CONIFER] > 300, "a mild mountain is wooded (%d conifers)" % counts[CONIFER])
	_expect(counts[BOULDER] > 50 and counts[ROCK] > 200, "boulders and rocks lie about (%d, %d)" % [counts[BOULDER], counts[ROCK]])
	_expect(counts[SHRUB] > 0 and counts[SNAG] > 0, "the treeline has krummholz and snags (%d, %d)" % [counts[SHRUB], counts[SNAG]])
	_expect(cold_trees < counts[CONIFER] / 2, "a cold giant has far fewer trees (%d vs %d)" % [cold_trees, counts[CONIFER]])

	var summit: Vector3 = terrain.start_position
	var base: Vector3 = terrain.goal_position
	var corridor: PackedVector3Array = terrain.corridor
	var bmin: Vector3 = terrain.terrain_bounds_min
	var span: float = terrain.terrain_bounds_max.y - bmin.y
	var bad_clear := 0
	var bad_ground := 0
	var bad_tree_ground := 0
	var above_treeline := 0
	var with_collider := 0
	var nearest_corridor := INF
	for obj in scatter.objects:
		var flat := Vector2(obj.position.x, obj.position.z)
		if flat.distance_to(Vector2(summit.x, summit.z)) < _scatter_script.SUMMIT_CLEARANCE - 0.01:
			bad_clear += 1
		if flat.distance_to(Vector2(base.x, base.z)) < _scatter_script.BASE_CAMP_CLEARANCE - 0.01:
			bad_clear += 1
		var to_corridor := INF
		for i in range(0, corridor.size(), 2):
			to_corridor = minf(to_corridor, flat.distance_to(Vector2(corridor[i].x, corridor[i].z)))
		if obj.kind != ROCK:
			nearest_corridor = minf(nearest_corridor, to_corridor)
		if to_corridor < float(_scatter_script.CORRIDOR_CLEARANCE[obj.kind]) - 1.5:
			bad_clear += 1
		var ground: float = terrain.get_height_at(obj.position)
		if obj.position.y > ground + 0.01 or ground - obj.position.y > 3.0:
			bad_ground += 1
			print("[test_scatter] off ground: kind %d size %.2f at %s, ground %.2f" % [obj.kind, obj.size, str(obj.position), ground])
		if obj.kind == CONIFER or obj.kind == SNAG or obj.kind == SHRUB:
			var cell: Object = terrain.get_cell_at(obj.position)
			if cell != null and (cell.slope_angle > _scatter_script.MAX_TREE_SLOPE + 0.5 or cell.surface_type == _enums.SurfaceType["ICE"]):
				bad_tree_ground += 1
				print("[test_scatter] tree ground: kind %d slope %.1f surface %d at %s" % [obj.kind, cell.slope_angle, cell.surface_type, str(obj.position)])
			if (obj.position.y - bmin.y) / span > scatter.treeline_fraction + 0.03:
				above_treeline += 1
		if obj.collider_radius > 0.0:
			with_collider += 1
	_expect(bad_clear == 0, "the summit, base camp and the normal route are kept clear (%d intrusions, nearest %.1f m from the route)" % [bad_clear, nearest_corridor])
	_expect(bad_ground == 0, "everything sits on the ground, none floating (%d off)" % bad_ground)
	_expect(bad_tree_ground == 0, "no tree on ice or steeper than %d deg" % int(_scatter_script.MAX_TREE_SLOPE))
	_expect(above_treeline == 0, "no tree above the treeline (%d)" % above_treeline)
	_expect(scatter.get_collider_count() == with_collider and with_collider > 300, "trunks and big boulders have colliders (%d)" % with_collider)

	var body: StaticBody3D = scatter.find_child("ScatterColliders", false, false)
	_expect(body != null and body.collision_layer == _scatter_script.OBSTACLE_LAYER and body.is_in_group("scatter_obstacle"),
		"colliders are on the obstacle layer")
	var player_scene: PackedScene = load("res://src/entities/player/player.tscn")
	var probe: CharacterBody3D = player_scene.instantiate()
	_expect(probe.collision_mask & _scatter_script.OBSTACLE_LAYER != 0 and probe.collision_mask & 1 != 0,
		"the climber collides with terrain and obstacles (mask %d)" % probe.collision_mask)
	probe.free()

	var instances := 0
	var meshes: Node = scatter.find_child("ScatterMeshes", false, false)
	for child in meshes.get_children():
		instances += (child as MultiMeshInstance3D).multimesh.instance_count
	_expect(instances == scatter.objects.size(), "every object is drawn (%d instances)" % instances)


func _check_determinism(terrain: Object) -> void:
	var scatter: Object = terrain.scatter
	var before: Array[Vector3] = []
	for i in range(mini(25, scatter.objects.size())):
		before.append(scatter.objects[i].position)
	var count: int = scatter.objects.size()
	scatter.rebuild(terrain)
	var same: bool = scatter.objects.size() == count
	for i in range(before.size()):
		if scatter.objects[i].position.distance_to(before[i]) > 0.001:
			same = false
	_expect(same, "the same mountain grows the same trees")


func _check_override(terrain: Object) -> void:
	var scatter: Object = terrain.scatter
	var directory := "user://scatter_override_test"
	DirAccess.make_dir_recursive_absolute(directory)
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 4.0, 2.0)
	ResourceSaver.save(box, directory + "/boulder.tres")
	var saved_directory: String = scatter.override_directory
	scatter.override_directory = directory
	scatter.rebuild(terrain)
	var swapped := true
	var fitted := true
	var meshes: Node = scatter.find_child("ScatterMeshes", false, false)
	for child in meshes.get_children():
		var instance := child as MultiMeshInstance3D
		if not instance.name.begins_with("boulder"):
			continue
		if not (instance.multimesh.mesh is BoxMesh):
			swapped = false
		if instance.multimesh.instance_count > 0:
			var transform := instance.multimesh.get_instance_transform(0)
			var height := (transform * Vector3(0, 2, 0)).distance_to(transform * Vector3(0, -2, 0))
			fitted = fitted and height > 0.3 and height < 5.0
	_expect(swapped, "a mesh in the override folder replaces every boulder variant")
	_expect(fitted, "an authored mesh is scaled to each boulder's size")
	scatter.override_directory = saved_directory
	DirAccess.remove_absolute(directory + "/boulder.tres")
	scatter.rebuild(terrain)


# =============================================================================
# ANCHORS AND MAP
# =============================================================================

func _check_anchors(terrain: Object) -> void:
	var scatter: Object = terrain.scatter
	var detector: Node = (load("res://src/systems/rope/anchor_detector.gd") as GDScript).new()
	detector.terrain_service = terrain
	var tree = null
	for obj in scatter.objects:
		if obj.kind == CONIFER and obj.size > 7.0:
			var cell: Object = terrain.get_cell_at(obj.position)
			if cell != null and cell.surface_type != _enums.SurfaceType["ICE"]:
				tree = obj
				break
	_expect(tree != null, "there is a big tree to sling")
	if tree != null:
		var stand: Vector3 = tree.position + Vector3(1.5, 0.0, 0.0)
		var anchor: Object = detector.find_anchor(stand, false)
		var tree_type: int = (load("res://src/systems/rope/anchor_point.gd") as GDScript).AnchorType["TREE"]
		_expect(anchor != null and anchor.anchor_type == tree_type, "a sound tree within reach is the anchor of choice")
	var boulder = null
	for obj in scatter.objects:
		if obj.kind == BOULDER and obj.size > 2.0:
			boulder = obj
			break
	if boulder != null:
		var anchors: Array = detector.scatter_anchors(boulder.position, 1.0)
		_expect(not anchors.is_empty(), "a big boulder takes a sling")
	detector.free()


func _check_map(terrain: Object) -> void:
	var generator: Object = (load("res://src/systems/terrain/topo_map_generator.gd") as GDScript).new()
	var map: Object = generator.get_terrain_map(terrain)
	var counts: Dictionary = terrain.scatter.count_by_kind()
	_expect(map.tree_points.size() == counts[CONIFER] + counts[SNAG], "the map prints the woodland (%d trees)" % map.tree_points.size())
	_expect(map.boulder_points.size() > 0, "the map stipples the big boulders (%d)" % map.boulder_points.size())
	var image: Image = generator.get_terrain_image(terrain, Vector2i(640, 640))
	var tree_point: Vector2 = map.tree_points[0]
	var px := Vector2i(int((tree_point.x - map.bounds_min.x) / (map.bounds_max.x - map.bounds_min.x) * 640.0),
		int((tree_point.y - map.bounds_min.y) / (map.bounds_max.y - map.bounds_min.y) * 640.0))
	var colour := image.get_pixelv(px.clamp(Vector2i.ZERO, Vector2i(639, 639)))
	_expect(colour.g > colour.r and colour.g > colour.b, "woodland is printed green (%s)" % str(colour))


# =============================================================================
# COLLISIONS IN A LIVE DESCENT
# =============================================================================

func _check_collisions(terrain: Object) -> void:
	var states: Dictionary = _enums.GameState
	var db: Object = _locator.get_service("MountainDatabase")
	db.select_mountain("knife_edge", true)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await process_frame
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await process_frame
	_state_manager.transition_to(int(states["PLANNING"]))
	await process_frame
	var conditions: Resource = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	conditions.mountain_id = "knife_edge"
	var run: Object = _state_manager.start_run("knife_edge", conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	for _i in range(30):
		await process_frame
	var player: CharacterBody3D = _locator.get_service("PlayerController") as CharacterBody3D

	# Incidents announced on the EventBus reach the run's history
	var before: int = run.incidents.size()
	root.get_node("/root/EventBus").record_incident("micro_slip", {"test": true})
	_expect(run.incidents.size() == before + 1, "incidents announced by systems are kept in the run")
	root.get_node("/root/EventBus").record_decision("context_shot", {})
	root.get_node("/root/EventBus").record_decision("deploy_rope", {})
	_expect(run.get_decisions_by_type("deploy_rope").size() == 1 and run.get_decisions_by_type("context_shot").is_empty(),
		"climber decisions are kept, camera bookkeeping is not")

	var scatter: Object = terrain.scatter
	var flat_boulder = _find_on_gentle_ground(terrain, BOULDER, 1.6)
	if flat_boulder != null:
		var direction := Vector3(1, 0, 0)
		var start: Vector3 = flat_boulder.position - direction * (flat_boulder.collider_radius + 2.5)
		start.y = terrain.get_height_at(start) + 0.3
		player.global_position = start
		player.velocity = Vector3.ZERO
		await physics_frame
		var impacts_before: int = run.get_incidents_by_type("obstacle_impact").size()
		for _f in range(90):
			player.velocity.x = direction.x * 2.4
			player.velocity.z = direction.z * 2.4
			await physics_frame
		var gap := Vector2(player.global_position.x - flat_boulder.position.x, player.global_position.z - flat_boulder.position.z).length()
		_expect(gap > flat_boulder.collider_radius * 0.8, "walking into a boulder, the climber is stopped at it (%.2f m from its centre, radius %.2f)" % [gap, flat_boulder.collider_radius])
		_expect(run.get_incidents_by_type("obstacle_impact").size() == impacts_before, "bumping a boulder at walking pace does not hurt")

	var tree = _find_on_gentle_ground(terrain, CONIFER, 6.0)
	_expect(tree != null, "a tree on gentle ground to slide into")
	if tree != null:
		var direction2 := Vector3(0, 0, 1)
		var start2: Vector3 = tree.position - direction2 * (tree.collider_radius + 3.0)
		start2.y = terrain.get_height_at(start2) + 0.2
		player.global_position = start2
		player.velocity = Vector3.ZERO
		await physics_frame
		player.start_slide(true, "test")
		var injuries_before: int = run.body_state.injuries.size()
		for _f in range(40):
			if run.get_incidents_by_type("obstacle_impact").size() > 0:
				break
			player.velocity.x = direction2.x * 9.0
			player.velocity.z = direction2.z * 9.0
			await physics_frame
		var hits: Array = run.get_incidents_by_type("obstacle_impact")
		_expect(not hits.is_empty(), "sliding into a tree at 9 m/s is a collision")
		if not hits.is_empty():
			var detail: Dictionary = hits[hits.size() - 1].get("details", {})
			_expect(str(detail.get("object", "")) == "conifer", "the collision knows it was a tree (%s)" % str(detail.get("object", "")))
		_expect(run.body_state.injuries.size() > injuries_before, "and it hurts (%d injuries)" % run.body_state.injuries.size())
		var speed := Vector2(player.velocity.x, player.velocity.z).length()
		_expect(speed < 4.0, "the tree stops the slide (%.1f m/s)" % speed)


func _find_on_gentle_ground(terrain: Object, kind: int, min_size: float):
	for obj in terrain.scatter.objects:
		if obj.kind != kind or obj.size < min_size or obj.collider_radius <= 0.0:
			continue
		var cell: Object = terrain.get_cell_at(obj.position)
		if cell == null or cell.slope_angle > 14.0:
			continue
		# Nothing else in the way of the run-up
		var crowded := false
		for other in terrain.scatter.get_objects_near(obj.position, obj.collider_radius + 5.0):
			if other != obj and other.collider_radius > 0.0:
				crowded = true
				break
		if not crowded:
			return obj
	return null


# =============================================================================
# HARNESS
# =============================================================================

func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_scatter] ok: %s" % what)
	else:
		print("[test_scatter] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[test_scatter] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_scatter] FAIL: %d of %d: %s" % [_failures.size(), _checks, "; ".join(_failures)])
		quit(1)
