extends SceneTree
## Front-end test: the screens around a descent and what they are fed.
##
## Run from the project root:
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_front_end.gd
## Exit code 0 on PASS, 1 on FAIL (prints "[test_front_end] PASS" / "FAIL: ...").
##
## What it covers:
##   - key moments: which recorded decisions and incidents are worth a line in
##     the logbook and on the map replay, and how the line reads (RunMoments)
##
## Implementation note: a "-s" script is compiled BEFORE the project autoloads
## are registered, so this file must not name GameStateManager, GameEnums,
## ServiceLocator or any project class_name at compile time (see
## tests/smoke_goal.gd).

var _failures: Array[String] = []
var _checks: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_key_moments()
	_finish("")


# =============================================================================
# KEY MOMENTS
# =============================================================================

func _test_key_moments() -> void:
	var moments: GDScript = load("res://src/ui/analysis/run_moments.gd") as GDScript
	var kinds: Dictionary = moments.Kind

	_expect(moments.describe("start_slide", {}, false) == "Started sliding", "a slide is a key moment")
	_expect(moments.describe("start_downclimb", {"slope": 41.6}, false) == "Began downclimbing (42°)",
		"a downclimb says how steep it was")
	_expect(moments.describe("obstacle_impact", {"object": "boulder"}, true) == "Hit a boulder"
		and moments.describe("obstacle_impact", {"object": "tree"}, true) == "Hit a tree",
		"a collision says what was hit")
	_expect(moments.describe("micro_slip", {}, true) == "", "the slips that happen all day are not listed")
	_expect(moments.describe("fall", {"severity": "TUMBLE"}, true) == "",
		"the risk system's jolt is not reported as a fall (the climber did not fall)")
	_expect(moments.describe("fall_from_slip", {}, true) == "Slipped and fell", "a real fall is")
	_expect(moments.describe("tension_shot", {}, false) == "" and moments.describe("cut", {}, false) == "",
		"the camera director's own decisions say nothing to the climber")
	_expect(moments.describe("something_new", {}, true) == "Something New",
		"an incident nobody wrote a line for is still listed")
	_expect(moments.describe("something_new", {}, false) == "", "a decision nobody wrote a line for is not")
	_expect(moments.describe("probe", {"hollow": false}, false) == ""
		and moments.describe("probe", {"hollow": true}, false) == "Probed a hidden crevasse",
		"probing is a moment only when it finds something")

	_expect(int(moments.kind_of("terminal_slide", true)) == int(kinds["FATAL"])
		and int(moments.kind_of("start_slide", false)) == int(kinds["SLIDE"])
		and int(moments.kind_of("deploy_rope", false)) == int(kinds["ROPE"])
		and int(moments.kind_of("whumpf", false)) == int(kinds["HAZARD"])
		and int(moments.kind_of("hard_landing", true)) == int(kinds["HURT"])
		and int(moments.kind_of("summit_reached", false)) == int(kinds["DECISION"]),
		"moments are sorted into kinds for the map's colours")

	_expect(moments.elapsed(1.25) == "1:15" and moments.elapsed(0.0) == "0:00" and moments.elapsed(0.999) == "1:00",
		"time into the run reads as hours and minutes")

	# A run's record, out of order and with noise in it
	var run: Object = (load("res://src/core/data/run_context.gd") as GDScript).new()
	var conditions: Object = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	conditions.time_of_day = 23.5
	run.start_conditions = conditions
	run.decisions.append({"type": "deploy_rope", "game_time": 0.75, "position": Vector3(3, 0, 0), "details": {}})
	run.decisions.append({"type": "start_slide", "game_time": 0.25, "position": Vector3(1, 0, 0), "details": {}})
	run.decisions.append({"type": "tension_shot", "game_time": 0.3, "position": Vector3.ZERO, "details": "a string"})
	run.incidents.append({"type": "micro_slip", "game_time": 0.1, "position": Vector3.ZERO, "details": {}})
	run.incidents.append({"type": "hard_landing", "game_time": 0.5, "position": Vector3(2, 0, 0), "details": {}})
	var listed: Array = moments.collect(run)
	var order: Array[String] = []
	for moment in listed:
		order.append(str(moment["type"]))
	_expect(order == ["start_slide", "hard_landing", "deploy_rope"],
		"a run's moments come out in the order they happened, without the noise (%s)" % ", ".join(order))
	_expect(listed.size() == 3 and listed[1]["is_incident"] and not listed[0]["is_incident"]
		and listed[2]["position"] == Vector3(3, 0, 0) and listed[1]["text"] == "Hard landing",
		"each with where it happened and its line")
	_expect(moments.clock(run, 0.25) == "23:45" and moments.clock(run, 0.75) == "00:15",
		"the time of day of a moment carries past midnight (%s, %s)" % [moments.clock(run, 0.25), moments.clock(run, 0.75)])
	_expect(moments.collect(null).is_empty(), "no run, no moments")


# =============================================================================
# HELPERS
# =============================================================================

func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_front_end] ok: %s" % what)
	else:
		print("[test_front_end] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[test_front_end] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_front_end] FAIL: %d problem(s): %s" % [_failures.size(), "; ".join(_failures)])
		quit(1)
