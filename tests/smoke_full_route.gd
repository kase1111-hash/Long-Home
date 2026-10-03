extends SceneTree
## Headless smoke test for the full route and the planning gear: plan both
## legs from the guidebook, leave base camp, reach the summit, come home,
## get a scored logbook entry; then a second run that turns back. Also
## checks that nothing is labelled on the mountain (no Label3D in the world).
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/smoke_full_route.gd
##
## Exit code 0 on PASS, 1 on FAIL. Project classes and autoloads are reached
## dynamically (a "-s" script compiles before the autoloads exist).

const MOUNTAIN := "knife_edge"
const STEP := 4.0

var _state_manager: Node
var _enums: Node
var _locator: Node
var _main: Node
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

	var packed: PackedScene = load("res://src/scenes/main.tscn")
	_main = packed.instantiate()
	root.add_child(_main)
	await _wait(3)

	var states: Dictionary = _enums.GameState
	var phases: Dictionary = _enums.RunPhase
	var db: Object = _locator.get_service("MountainDatabase")
	var saved_override: bool = db.full_route_override
	db.full_route_override = true
	_expect(db.select_mountain(MOUNTAIN, true), "select %s" % MOUNTAIN)
	_expect(db.set_route_mode(_enums.RouteMode["FULL_ROUTE"]), "full route chosen once unlocked")

	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await _wait(1)
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await _wait(1)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(4)

	# --- Planning: two legs, the guidebook, the day plan ---
	var planning: Object = _main.get("planning_screen")
	_expect(planning != null, "planning screen exists")
	if planning == null:
		_finish("no planning screen")
		return
	planning.refresh()
	await _wait(1)
	_expect(planning.route_mode == _enums.RouteMode["FULL_ROUTE"], "planning knows it is a full route")
	_expect(planning.leg_bar != null and planning.leg_bar.visible, "the ascent/descent legs are shown")
	_expect(planning.get_active_leg() == phases["ASCENT"], "planning starts on the way up")
	_expect(planning.guide_routes.size() >= 1, "the guidebook lists lines (%d)" % planning.guide_routes.size())
	_expect(planning.confirm_button.text == "Leave Base Camp", "the start button leaves base camp")

	planning._on_guide_pressed(0)
	_expect(planning.guide_card.get_child_count() > 3, "reading a line fills its route card")
	planning._on_follow_pressed()
	var map: Object = planning.map_display
	_expect(map.get_planned_route(phases["ASCENT"]).size() > 2, "following the line pencils the way up")
	planning._on_leg_pressed(phases["DESCENT"])
	planning._on_follow_pressed()
	_expect(map.get_planned_route(phases["DESCENT"]).size() > 2, "and the way down")
	var day_label: Label = planning.route_info_panel.get_node_or_null("DayPlanLabel")
	_expect(day_label != null and day_label.text.contains("Turnaround"), "the day plan sets a turnaround time")
	var guide_id: String = planning.get_selected_guide_id()
	_expect(guide_id == planning.guide_routes[0].id, "the plan remembers the guidebook line (%s)" % guide_id)

	planning.confirm_button.pressed.emit()
	await _wait(8)
	_expect(_state() == int(states["DESCENT"]), "the run starts (state %d)" % _state())

	var run: Object = _state_manager.current_run
	var player: Node3D = _locator.get_service("PlayerController") as Node3D
	var terrain: Object = _locator.get_service("TerrainService")
	if run == null or player == null or terrain == null:
		_finish("no run/player/terrain")
		return
	_expect(run.is_full_route() and run.phase == phases["ASCENT"], "the run is a full route, heading up")
	_expect(absf(run.start_conditions.time_of_day - 5.0) < 0.01, "an alpine start at 05:00")
	var planned_up: PackedVector3Array = run.get_meta("planned_ascent", PackedVector3Array())
	_expect(planned_up.size() > 2, "the run carries the planned ascent")

	var base: Vector3 = terrain.goal_position
	var summit: Vector3 = terrain.start_position
	var spawn: Vector3 = player.global_position
	_expect(_flat(spawn, base) < terrain.goal_radius, "the climber starts at base camp (%.1f m)" % _flat(spawn, base))
	var facing: Vector3 = -player.global_transform.basis.z
	var to_summit := Vector3(summit.x - spawn.x, 0.0, summit.z - spawn.z).normalized()
	_expect(Vector2(facing.x, facing.z).normalized().dot(Vector2(to_summit.x, to_summit.z)) > 0.7, "facing the summit")

	await _wait(40)
	_expect(_state() == int(states["DESCENT"]), "standing in base camp does not end a full route")
	var hud: Node = _main.get("descent_hud")
	if hud != null:
		hud.refresh()
		var caption: Label = hud.find_child("BasecampCaption", true, false)
		_expect(caption != null and caption.text == "Summit", "the HUD points to the summit on the way up")

	var labels := _count_label3d(_main.get("world"))
	_expect(labels == 0, "nothing on the mountain is labelled (%d Label3D)" % labels)
	_expect(_main.get("summit_goal") != null, "a summit cairn stands on top")

	# --- Up the line to the summit ---
	await _walk(player, terrain, planned_up)
	await _wait(10)
	_expect(run.summit_reached, "reaching the top marks the summit")
	_expect(run.phase == phases["DESCENT"], "the way home begins")
	_expect(run.get_decisions_by_type("summit_reached").size() == 1, "the summit is in the run's decisions")
	if hud != null:
		hud.refresh()
		await _wait(2)
		var caption2: Label = hud.find_child("BasecampCaption", true, false)
		_expect(caption2 != null and caption2.text == "Base camp", "the HUD points home after the summit")

	# --- Down the planned line to camp ---
	var planned_down: PackedVector3Array = run.get_meta("planned_route", PackedVector3Array())
	await _walk(player, terrain, planned_down)
	await _wait(20)
	_expect(_state() == int(states["RESOLUTION"]), "base camp ends the run after the summit (state %d)" % _state())
	var outcomes: Dictionary = _enums.ResolutionType
	_expect(run.outcome == outcomes["CLEAN_RETURN"] or run.outcome == outcomes["INJURED_RETURN"], "a return (%d)" % run.outcome)
	var score: Object = run.route_score
	_expect(score != null, "the run is scored")
	if score != null:
		_expect(score.mode == _enums.RouteMode["FULL_ROUTE"] and score.summit_reached, "the score is a full route with the summit")
		_expect(score.lines.size() >= 4 and score.total > 0, "the logbook entry has a breakdown and points (%d: %s)" % [score.total, score.get_title()])
		print("[smoke_full_route] score: %d - %s" % [score.total, score.get_title()])
		for line in score.lines:
			print("[smoke_full_route]   %s  %s" % [line["label"], line["value"]])
	var progress: Object = db.get_progress(MOUNTAIN)
	_expect(not progress.logbook.is_empty() and int(progress.logbook[0].get("mode", 0)) == _enums.RouteMode["FULL_ROUTE"], "the logbook files the full route")

	# --- A second run that turns back short of the summit ---
	_state_manager.transition_to(int(states["POST_GAME"]))
	await _wait(3)
	_state_manager.transition_to(int(states["PLANNING"]))
	await _wait(4)
	planning.confirm_button.pressed.emit()
	await _wait(8)
	run = _state_manager.current_run
	_expect(run != null and run.is_full_route() and not run.summit_reached, "a fresh full route starts")
	if run != null:
		var up: PackedVector3Array = run.get_meta("planned_ascent", PackedVector3Array())
		var part := _partial(up, 70.0)
		await _walk(player, terrain, part)
		await _wait(5)
		_expect(_state() == int(states["DESCENT"]), "still climbing after setting off")
		var back := part.duplicate()
		back.reverse()
		back.append(base)
		await _walk(player, terrain, back)
		await _wait(20)
		_expect(_state() == int(states["RESOLUTION"]), "walking back into camp ends the run as a retreat (state %d)" % _state())
		_expect(not run.summit_reached and run.end_cause.contains("Retreat"), "the retreat is recorded (%s)" % run.end_cause)
		var retreat_score: Object = run.route_score
		_expect(retreat_score != null and retreat_score.retreated, "the score knows it was a retreat")

	db.set_route_mode(_enums.RouteMode["DESCENT"])
	db.full_route_override = saved_override
	_finish("")


## Move the climber along a line in short steps, on the ground, so the run
## records a travelled path (not one teleport)
func _walk(player: Node3D, terrain: Object, line: PackedVector3Array) -> void:
	for i in range(line.size() - 1):
		var a: Vector3 = line[i]
		var b: Vector3 = line[i + 1]
		var steps := maxi(1, int(ceil(_flat(a, b) / STEP)))
		for k in range(1, steps + 1):
			if _state() != int(_enums.GameState["DESCENT"]):
				return
			var p := a.lerp(b, float(k) / float(steps))
			p.y = terrain.get_height_at(p) + 0.15
			player.global_position = p
			player.velocity = Vector3.ZERO
			await physics_frame
			await physics_frame


## The first metres of a line
func _partial(line: PackedVector3Array, metres: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if line.is_empty():
		return out
	out.append(line[0])
	var travelled := 0.0
	for i in range(1, line.size()):
		var seg := _flat(line[i - 1], line[i])
		if travelled + seg >= metres:
			out.append(line[i - 1].lerp(line[i], (metres - travelled) / maxf(seg, 0.001)))
			return out
		travelled += seg
		out.append(line[i])
	return out


func _count_label3d(node: Node) -> int:
	if node == null:
		return 0
	var count := 1 if node is Label3D else 0
	for child in node.get_children():
		count += _count_label3d(child)
	return count


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _state() -> int:
	var state: int = _state_manager.current_state
	return state


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _expect(condition: bool, what: String) -> void:
	if condition:
		print("[smoke_full_route] ok: %s" % what)
	else:
		print("[smoke_full_route] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[smoke_full_route] PASS")
		quit(0)
	else:
		print("[smoke_full_route] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
