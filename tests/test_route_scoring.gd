extends SceneTree
## Headless checks for route grading, guidebook survey and route scoring:
## AlpineGrade bands, RouteMetrics on real terrain (book times, abseils),
## RouteSurvey's lines on every mountain, RouteScorer on synthetic runs
## (outcome, style, pace, plan, travel modes, full route, retreat) and the
## logbook. Each check says the rule it encodes.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_route_scoring.gd
##
## A "-s" script is compiled before the autoloads exist, so project classes
## are reached with load() and autoloads through /root (see smoke_goal.gd).

const MOUNTAINS := ["knife_edge", "north_face", "the_couloir", "storm_peak", "long_way_down"]

var _enums: Node
var _locator: Node
var _main: Node
var _grade: GDScript
var _metrics: GDScript
var _survey: GDScript
var _scorer: GDScript
var _run_script: GDScript
var _conditions_script: GDScript
var _gear_script: GDScript
var _db_script: GDScript
var _failures: Array[String] = []
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	if _enums == null or _locator == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_grade = load("res://src/systems/planning/alpine_grade.gd")
	_metrics = load("res://src/systems/planning/route_metrics.gd")
	_survey = load("res://src/systems/planning/route_survey.gd")
	_scorer = load("res://src/systems/planning/route_scorer.gd")
	_run_script = load("res://src/core/data/run_context.gd")
	_conditions_script = load("res://src/core/data/start_conditions.gd")
	_gear_script = load("res://src/core/data/gear_state.gd")
	_db_script = load("res://src/data/mountain_database.gd")

	_check_grade_scale()

	var packed: PackedScene = load("res://src/scenes/main.tscn")
	_main = packed.instantiate()
	root.add_child(_main)
	for _i in range(4):
		await process_frame

	for id in MOUNTAINS:
		_main._ensure_terrain_loaded(id)
		await process_frame
		_check_survey(id)

	_main._ensure_terrain_loaded("long_way_down")
	await process_frame
	_check_scoring()
	_check_logbook()
	_finish("")


# =============================================================================
# GRADE SCALE
# =============================================================================

func _check_grade_scale() -> void:
	_expect(_grade.grade_name(_grade.grade_value(22.0, 0.0, 0, 0.0, 0.0)) == "F",
		"easy ground under 25 deg is F")
	_expect(_grade.grade_name(_grade.grade_value(33.0, 0.0, 0, 0.0, 0.0)).begins_with("PD"),
		"a 33 deg snow slope is PD (%s)" % _grade.grade_name(_grade.grade_value(33.0, 0.0, 0, 0.0, 0.0)))
	_expect(_grade.grade_name(_grade.grade_value(42.0, 0.0, 0, 0.0, 0.0)).begins_with("AD"),
		"42 deg sustained is AD (%s)" % _grade.grade_name(_grade.grade_value(42.0, 0.0, 0, 0.0, 0.0)))
	_expect(_grade.grade_name(_grade.grade_value(50.0, 0.0, 0, 0.0, 0.0)).begins_with("D"),
		"50 deg is D (%s)" % _grade.grade_name(_grade.grade_value(50.0, 0.0, 0, 0.0, 0.0)))
	_expect(_grade.grade_name(_grade.grade_value(80.0, 0.0, 0, 0.0, 0.0)).begins_with("ED"),
		"80 deg is ED (%s)" % _grade.grade_name(_grade.grade_value(80.0, 0.0, 0, 0.0, 0.0)))

	var previous := -1.0
	var monotonic := true
	for slope in range(20, 86, 2):
		var v: float = _grade.slope_index(float(slope))
		if v < previous:
			monotonic = false
		previous = v
	_expect(monotonic, "grade never drops as the slope steepens")

	var easy_rappel: float = _grade.grade_value(26.0, 0.0, 1, 0.0, 0.0)
	_expect(easy_rappel >= 5.0, "a line that needs an abseil is at least AD- (%s)" % _grade.grade_name(easy_rappel))
	_expect(_grade.grade_value(38.0, 0.0, 0, 0.5, 0.0) > _grade.grade_value(38.0, 0.0, 0, 0.0, 0.0),
		"exposure raises the grade")
	_expect(_grade.grade_value(38.0, 150.0, 0, 0.0, 0.0) > _grade.grade_value(38.0, 10.0, 0, 0.0, 0.0),
		"a long steep face grades harder than one steep move")
	_expect(_grade.grade_value(38.0, 0.0, 0, 0.0, 80.0) > _grade.grade_value(38.0, 0.0, 0, 0.0, 0.0),
		"steep ice grades harder than snow at the same angle")
	_expect(_grade.commitment(60.0) == "I" and _grade.commitment(150.0) == "II" and _grade.commitment(600.0) == "IV",
		"commitment grade follows the book time (I < 2 h, II < 4 h, IV < 12 h)")


# =============================================================================
# SURVEY AND BOOK TIMES
# =============================================================================

func _check_survey(id: String) -> void:
	var terrain: Object = _locator.get_service("TerrainService")
	_survey.clear_cache()
	var routes: Array = _survey.survey(terrain)
	_expect(routes.size() >= 2, "%s: the guidebook has at least two lines (%d)" % [id, routes.size()])
	if routes.is_empty():
		return
	var normal = routes[0]
	_expect(normal.name == "Normal Route", "%s: the first line is the normal route" % id)
	_expect(normal.metrics.rappels == 0, "%s: the normal route needs no abseil" % id)
	var easiest := true
	for route in routes:
		if route.metrics.grade_value + 0.001 < normal.metrics.grade_value:
			easiest = false
	_expect(easiest, "%s: the normal route is the easiest line (%s)" % [id, normal.metrics.grade])
	_expect(normal.metrics.sustained_slope <= 30.0,
		"%s: the normal route stays walkable (%.1f deg sustained)" % [id, normal.metrics.sustained_slope])

	var names := {}
	for route in routes:
		var m = route.metrics
		_expect(route.line.size() >= 2 and not route.name.is_empty(), "%s: %s has a line and a name" % [id, route.name])
		_expect(not names.has(route.name), "%s: line names are unique (%s)" % [id, route.name])
		names[route.name] = true
		_expect(not m.pitches.is_empty(), "%s: %s has a pitch topo" % [id, route.name])
		# Book pace: between a slow crawl and a jog, in game time
		var pace: float = m.length / maxf(m.minutes * 60.0, 1.0)
		_expect(pace > 0.02 and pace < 0.4, "%s: %s book pace is plausible (%.3f m/s game, %s)" % [id, route.name, pace, _metrics.format_minutes(m.minutes)])
		var pitch_minutes := 0.0
		for pitch in m.pitches:
			pitch_minutes += pitch.minutes
		_expect(absf(pitch_minutes - m.minutes) < 0.5, "%s: %s pitch times add up to the book time" % [id, route.name])
		var up = route.get_ascent_metrics(terrain)
		if not up.ascent_blocked:
			_expect(up.minutes > m.minutes, "%s: %s takes longer up than down (%s vs %s)" % [id, route.name, _metrics.format_minutes(up.minutes), _metrics.format_minutes(m.minutes)])

	for i in range(routes.size()):
		for j in range(i + 1, routes.size()):
			var separation: float = _survey._mean_separation(routes[j].line, routes[i].line)
			_expect(separation >= _survey.DUPLICATE_DISTANCE, "%s: %s and %s are distinct lines (%.0f m apart)" % [id, routes[i].name, routes[j].name, separation])

	if id == "long_way_down":
		var any_rappel := false
		for route in routes:
			if route.metrics.rappels > 0:
				any_rappel = true
		_expect(any_rappel, "long_way_down: some line abseils the cliff bands")


# =============================================================================
# SCORING
# =============================================================================

func _make_run(path: PackedVector3Array, outcome: int, book_minutes: float) -> Object:
	var conditions: Object = _conditions_script.create_moderate()
	conditions.mountain_id = "long_way_down"
	conditions.knowledge_level = _enums.KnowledgeLevel["FAMILIAR"]
	var run: Object = _run_script.create_new_run("long_way_down", conditions)
	run.path_history = path
	var modes := PackedByteArray()
	modes.resize(path.size())
	modes.fill(0)
	run.path_modes = modes
	run.game_time_elapsed = book_minutes / 60.0
	run.current_time = 12.0 + run.game_time_elapsed
	run.is_complete = true
	run.outcome = outcome
	run.set_meta("planned_route", path)
	return run


func _dense(line: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in range(line.size() - 1):
		var a: Vector3 = line[i]
		var b: Vector3 = line[i + 1]
		var steps := maxi(1, int(ceil(a.distance_to(b) / 1.5)))
		for k in range(steps):
			out.append(a.lerp(b, float(k) / float(steps)))
	out.append(line[line.size() - 1])
	return out


func _check_scoring() -> void:
	var terrain: Object = _locator.get_service("TerrainService")
	var routes: Array = _survey.survey(terrain)
	var outcomes: Dictionary = _enums.ResolutionType
	var normal = routes[0]
	var path := _dense(normal.line)
	# The scorer's book time is for this pack (weight, rope, crampons)
	var probe: Object = _scorer.score_run(_make_run(path, outcomes["CLEAN_RETURN"], 60.0), terrain, routes)
	var book: float = probe.book_minutes
	_expect(book >= normal.metrics.minutes, "a full pack is no faster than the guidebook's party (%s vs %s)" % [_metrics.format_minutes(book), _metrics.format_minutes(normal.metrics.minutes)])

	var clean: Object = _scorer.score_run(_make_run(path, outcomes["CLEAN_RETURN"], book), terrain, routes)
	_expect(clean.total > 0, "a clean return on the normal route scores (%d)" % clean.total)
	_expect(clean.route_name == "Normal Route", "the scorer recognises the guidebook line followed (%s)" % clean.route_name)
	_expect(clean.grade == normal.metrics.grade, "the travelled line grades like the book (%s vs %s)" % [clean.grade, normal.metrics.grade])
	_expect(absf(clean.pace_factor - 1.0) < 0.06, "book pace scores even pace (x%.2f)" % clean.pace_factor)
	_expect(clean.plan_share > 0.95, "following the plan is on plan (%d%%)" % roundi(clean.plan_share * 100.0))
	_expect(clean.style_label == "Clean", "no incidents is clean style")

	var dead: Object = _scorer.score_run(_make_run(path, outcomes["FATALITY"], book), terrain, routes)
	_expect(dead.total == 0, "not coming home scores nothing (%d)" % dead.total)
	var hurt: Object = _scorer.score_run(_make_run(path, outcomes["INJURED_RETURN"], book), terrain, routes)
	_expect(hurt.total < clean.total and hurt.total > 0, "an injured return scores less than a clean one (%d < %d)" % [hurt.total, clean.total])

	var fast: Object = _scorer.score_run(_make_run(path, outcomes["CLEAN_RETURN"], book * 0.6), terrain, routes)
	var slow: Object = _scorer.score_run(_make_run(path, outcomes["CLEAN_RETURN"], book * 2.0), terrain, routes)
	_expect(fast.pace_factor > 1.0 and slow.pace_factor < 1.0, "beating the book pays, dawdling costs (x%.2f / x%.2f)" % [fast.pace_factor, slow.pace_factor])
	_expect(_scorer.pace_factor(1.0, 1000.0) <= _scorer.PACE_MAX and _scorer.pace_factor(1000.0, 1.0) >= _scorer.PACE_MIN, "pace is bounded")

	var scrappy_run: Object = _make_run(path, outcomes["CLEAN_RETURN"], book)
	for _k in range(2):
		scrappy_run.incidents.append({"type": "slide_from_slip"})
	scrappy_run.incidents.append({"type": "fall_started"})
	var scrappy: Object = _scorer.score_run(scrappy_run, terrain, routes)
	_expect(scrappy.style_factor < 0.8 and scrappy.total < clean.total, "slides and a fall cost style (x%.2f, %s)" % [scrappy.style_factor, scrappy.style_label])

	var off_plan_run: Object = _make_run(path, outcomes["CLEAN_RETURN"], book)
	if routes.size() > 1:
		off_plan_run.set_meta("planned_route", routes[routes.size() - 1].line)
		var off_plan: Object = _scorer.score_run(off_plan_run, terrain, routes)
		_expect(off_plan.plan_factor < clean.plan_factor, "leaving the planned line costs (x%.2f < x%.2f)" % [off_plan.plan_factor, clean.plan_factor])

	# A hard line: harder grade, more points (clean, at book pace)
	var hardest = routes[0]
	for route in routes:
		if route.metrics.grade_value > hardest.metrics.grade_value:
			hardest = route
	if hardest != normal:
		var hard_run: Object = _make_run(_dense(hardest.line), outcomes["CLEAN_RETURN"], hardest.metrics.minutes)
		var rappels := 0
		for pitch in hardest.metrics.pitches:
			rappels += pitch.rappels
		for _r in range(rappels):
			hard_run.decisions.append({"type": "rappel_complete", "game_time": 0.1})
		var hard: Object = _scorer.score_run(hard_run, terrain, routes)
		_expect(hard.total > clean.total, "the harder line (%s) scores more than the normal route (%d > %d)" % [hard.grade, hard.total, clean.total])

	# Out of control: falling down ground earns no difficulty
	var adrift_run: Object = _make_run(_dense(hardest.line), outcomes["CLEAN_RETURN"], hardest.metrics.minutes)
	var adrift_modes := PackedByteArray()
	adrift_modes.resize(adrift_run.path_history.size())
	adrift_modes.fill(_metrics.MODE_ADRIFT)
	adrift_run.path_modes = adrift_modes
	var adrift: Object = _scorer.score_run(adrift_run, terrain, routes)
	_expect(adrift.grade_value < 0.5, "a line covered out of control grades as nothing (%.2f)" % adrift.grade_value)

	# Teleports are not travel
	var jump := PackedVector3Array([path[0], path[path.size() - 1]])
	var teleport: Object = _scorer.score_run(_make_run(jump, outcomes["CLEAN_RETURN"], book), terrain, routes)
	_expect(teleport.route_name.is_empty() and teleport.grade_value < 0.5, "a teleport is no line (%s, %.2f)" % [teleport.route_name, teleport.grade_value])

	# Full route: up the normal route, down it again
	var up_path := _dense(normal.get_ascent_line())
	var full_path := up_path.duplicate()
	full_path.append_array(path)
	var up_probe_run: Object = _make_run(up_path, outcomes["CLEAN_RETURN"], 60.0)
	var up_book: float = _scorer.score_run(up_probe_run, terrain, routes).book_minutes
	var full_run: Object = _make_run(full_path, outcomes["CLEAN_RETURN"], up_book + book)
	full_run.route_mode = _enums.RouteMode["FULL_ROUTE"]
	full_run.summit_reached = true
	full_run.summit_path_index = up_path.size() - 1
	full_run.summit_time = up_book / 60.0
	full_run.set_meta("planned_ascent", up_path)
	var full: Object = _scorer.score_run(full_run, terrain, routes)
	_expect(full.total > clean.total, "up and down scores more than down alone (%d > %d)" % [full.total, clean.total])
	_expect(full.ascent_route_name == "Normal Route" and full.route_name == "Normal Route", "both legs are recognised (%s / %s)" % [full.ascent_route_name, full.route_name])
	_expect(absf(full.pace_factor - 1.0) < 0.06, "both legs at book pace is even pace (x%.2f)" % full.pace_factor)

	var retreat_run: Object = _make_run(up_path.slice(0, up_path.size() / 2), outcomes["CLEAN_RETURN"], up_book * 0.6)
	retreat_run.route_mode = _enums.RouteMode["FULL_ROUTE"]
	var retreat: Object = _scorer.score_run(retreat_run, terrain, routes)
	_expect(retreat.retreated and retreat.total < clean.total, "turning back short of the summit keeps a fraction (%d)" % retreat.total)


# =============================================================================
# LOGBOOK AND UNLOCK
# =============================================================================

func _check_logbook() -> void:
	var progress: Object = _db_script.MountainProgress.new()
	var first: bool = progress.record_score({"total": 200, "mode": 0, "grade": "F"})
	var lower: bool = progress.record_score({"total": 150, "mode": 0, "grade": "F"})
	var full: bool = progress.record_score({"total": 500, "mode": 1, "grade": "PD"})
	_expect(first and not lower and progress.best_score == 200, "the best descent score is kept (%d)" % progress.best_score)
	_expect(full and progress.best_full_score == 500 and progress.best_score == 200, "full routes keep their own best")
	_expect(progress.logbook.size() == 3 and int(progress.logbook[0]["total"]) == 500, "the logbook lists the newest entry first")
	var restored: Object = _db_script.MountainProgress.from_dict(JSON.parse_string(JSON.stringify(progress.to_dict())))
	_expect(restored.best_score == 200 and restored.best_full_score == 500 and restored.logbook.size() == 3, "scores and logbook survive a save")
	for _k in range(40):
		progress.record_score({"total": 1, "mode": 0})
	_expect(progress.logbook.size() == _db_script.LOGBOOK_SIZE, "the logbook keeps the last %d entries" % _db_script.LOGBOOK_SIZE)

	var db: Object = _locator.get_service("MountainDatabase")
	var saved = db.progress.get("long_way_down")
	var saved_override: bool = db.full_route_override
	db.full_route_override = false
	db.progress["long_way_down"] = _db_script.MountainProgress.new()
	_expect(not db.is_full_route_unlocked(), "the full route is locked before the final mountain")
	_expect(not db.set_route_mode(_enums.RouteMode["FULL_ROUTE"]) and db.get_route_mode() == _enums.RouteMode["DESCENT"], "a locked full route cannot be chosen")
	db.progress["long_way_down"].best_outcome = _enums.ResolutionType["INJURED_RETURN"]
	_expect(db.is_full_route_unlocked(), "coming down The Long Way Down unlocks the full route")
	_expect(db.set_route_mode(_enums.RouteMode["FULL_ROUTE"]) and db.get_route_mode() == _enums.RouteMode["FULL_ROUTE"], "an unlocked full route can be chosen")
	db.set_route_mode(_enums.RouteMode["DESCENT"])
	if saved != null:
		db.progress["long_way_down"] = saved
	else:
		db.progress.erase("long_way_down")
	db.full_route_override = saved_override


# =============================================================================
# HARNESS
# =============================================================================

func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_route_scoring] ok: %s" % what)
	else:
		print("[test_route_scoring] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[test_route_scoring] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_route_scoring] FAIL: %d of %d: %s" % [_failures.size(), _checks, "; ".join(_failures)])
		quit(1)
