extends SceneTree
## Headless smoke test for the descent loop: spawn on the summit plateau,
## stay on the ground, reach base camp, land on the resolution screen.
##
## Run from the project root:
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_goal.gd
## Exit code 0 on PASS, 1 on FAIL (prints "[smoke_goal] PASS" / "FAIL: ...").
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time. Everything is
## reached dynamically via /root/<autoload> nodes and load() after _run()
## starts (see tests/screenshot_tour.gd for the same pattern).

const MOUNTAIN := "knife_edge"
const SETTLE_FRAMES := 90
const ARRIVAL_FRAMES := 30
const MAX_SINK := 3.0  # metres the player may drop while settling on the ground

var _state_manager: Node = null
var _enums: Node = null
var _locator: Node = null
var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	if _state_manager == null or _enums == null or _locator == null:
		_finish("autoloads missing; run with --path <project root>")
		return

	var packed: PackedScene = load("res://src/scenes/main.tscn") as PackedScene
	if packed == null:
		_finish("could not load main.tscn")
		return
	var main_scene: Node = packed.instantiate()
	root.add_child(main_scene)
	await _wait(3)

	# --- Drive the menu states into a descent ---
	var states: Dictionary = _enums.GameState
	_expect(_state() == int(states["MAIN_MENU"]), "boot lands on MAIN_MENU (got %d)" % _state())

	var mountain_db: Object = _locator.get_service("MountainDatabase")
	_expect(is_instance_valid(mountain_db), "MountainDatabase service exists")
	if is_instance_valid(mountain_db):
		_expect(mountain_db.select_mountain(MOUNTAIN), "select_mountain('%s')" % MOUNTAIN)

	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(1)

	var conditions_script: GDScript = load("res://src/core/data/start_conditions.gd") as GDScript
	var conditions: Resource = conditions_script.create_moderate()
	conditions.mountain_id = MOUNTAIN
	var run: Object = _state_manager.start_run(MOUNTAIN, conditions)
	_expect(run != null, "start_run returns a run")
	_state_manager.transition_to(int(states["DESCENT"]))
	await _wait(5)
	_expect(_state() == int(states["DESCENT"]), "state is DESCENT (got %d)" % _state())

	# --- Player spawned on the ground at the terrain start ---
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	_expect(player != null, "PlayerController registered")
	var terrain: Object = _locator.get_service("TerrainService")
	_expect(is_instance_valid(terrain), "TerrainService registered")
	if player == null or not is_instance_valid(terrain) or run == null:
		_finish("cannot continue without player/terrain/run")
		return

	var spawn: Vector3 = player.global_position
	var start_pos: Vector3 = terrain.start_position
	var goal_pos: Vector3 = terrain.goal_position
	_expect(start_pos != Vector3.ZERO, "terrain has a start position")
	_expect(goal_pos != Vector3.ZERO, "terrain has a goal position")
	_expect(spawn.distance_to(start_pos) < 2.0, "player spawned at the start plateau (%.1f m away)" % spawn.distance_to(start_pos))
	_expect(run.start_elevation > 1000.0, "run.start_elevation set (%.1f)" % run.start_elevation)
	_expect(run.target_elevation > 1000.0 and run.target_elevation < run.start_elevation,
		"run.target_elevation below start (%.1f < %.1f)" % [run.target_elevation, run.start_elevation])

	await _wait(SETTLE_FRAMES)
	var settled: Vector3 = player.global_position
	_expect(spawn.y - settled.y < MAX_SINK, "player rests on the terrain (sank %.2f m)" % (spawn.y - settled.y))
	_expect(player.is_on_floor(), "player is_on_floor after settling")
	_expect(run.current_elevation > 1000.0, "run tracks current_elevation (%.1f)" % run.current_elevation)
	_expect(run.real_time_elapsed > 0.5, "run clock advances (%.2f s)" % run.real_time_elapsed)

	var goal_node: Node = main_scene.get("descent_goal")
	_expect(goal_node != null and is_instance_valid(goal_node), "DescentGoal exists under World")
	var hud_node: Node = main_scene.get("descent_hud")
	if hud_node == null:
		print("[smoke_goal] note: no DescentHUD (scene missing)")

	# --- Walk in and arrive at base camp ---
	player.global_position = goal_pos + Vector3(0, 1.0, 0)
	await _wait(ARRIVAL_FRAMES)
	_expect(_state() == int(states["RESOLUTION"]), "reaching base camp ends the run (state %d)" % _state())
	var outcomes: Dictionary = _enums.ResolutionType
	var outcome: int = run.outcome
	_expect(outcome == int(outcomes["CLEAN_RETURN"]) or outcome == int(outcomes["INJURED_RETURN"]),
		"outcome is a return (got %d)" % outcome)
	_expect(run.is_complete, "run is complete")

	_finish("")


func _state() -> int:
	var state: int = _state_manager.current_state
	return state


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("[smoke_goal] ok: %s" % what)
	else:
		print("[smoke_goal] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[smoke_goal] PASS")
		quit(0)
	else:
		print("[smoke_goal] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
