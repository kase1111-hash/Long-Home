extends SceneTree
## Headless checks for the mountain physics model (TractionModel): footing,
## downclimbing support, walking pace, glissade braking, self-arrest and ski
## numbers. Each check states the real-world rule it encodes, so a tuning
## change that breaks one says which rule it broke.
##
##   godot --headless --path . -s res://tests/test_physics_model.gd
##
## A "-s" script is compiled before the autoloads exist, so the model and
## GameEnums are reached dynamically (see smoke_goal.gd).

var _tm: GDScript
var _surface: Dictionary
var _footwear: Dictionary
var _failures: Array[String] = []
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var enums: Node = root.get_node_or_null("/root/GameEnums")
	if enums == null:
		_finish("GameEnums autoload missing; run with --path <project root>")
		return
	_surface = enums.SurfaceType
	_footwear = enums.Footwear
	_tm = load("res://src/entities/player/traction_model.gd") as GDScript

	_check_footing()
	_check_downclimbing()
	_check_walking_pace()
	_check_glissade()
	_check_self_arrest()
	_check_skis()
	_finish("")


# =============================================================================
# FOOTING
# =============================================================================

func _check_footing() -> void:
	var boots: int = _footwear["BOOTS"]
	var crampons: int = _footwear["CRAMPONS"]

	var firm_boots: float = _tm.foot_grip(_surface["SNOW_FIRM"], boots)
	var hold: float = _tm.max_holding_slope(firm_boots)
	_expect(hold > 32.0 and hold < 37.0,
		"boots hold firm snow to the low-to-mid 30s (%.1f deg)" % hold)

	var ice_boots: float = _tm.foot_grip(_surface["ICE"], boots)
	_expect(_tm.required_grip(10.0, 0.0) > ice_boots,
		"boots cannot stand on 10 deg ice (grip %.2f)" % ice_boots)

	var ice_crampons: float = _tm.foot_grip(_surface["ICE"], crampons)
	_expect(ice_crampons > _tm.required_grip(45.0, 0.0),
		"crampons stand on 45 deg ice (grip %.2f)" % ice_crampons)

	var worn: float = _tm.foot_grip(_surface["ICE"], crampons, 0.4)
	_expect(worn < ice_crampons and worn > ice_boots,
		"worn crampons grip between boots and new points (%.2f)" % worn)

	var slush_boots: float = _tm.foot_grip(_surface["SNOW_SOFT"], boots, 1.0, 2.0)
	var slush_crampons: float = _tm.foot_grip(_surface["SNOW_SOFT"], crampons, 1.0, 2.0)
	_expect(slush_crampons < slush_boots,
		"crampons ball up in warm soft snow and grip worse than boots (%.2f < %.2f)" % [slush_crampons, slush_boots])

	var rock_boots: float = _tm.foot_grip(_surface["ROCK_DRY"], boots)
	var rock_crampons: float = _tm.foot_grip(_surface["ROCK_DRY"], crampons)
	_expect(rock_crampons < rock_boots,
		"crampons skate on dry rock compared with rubber soles")

	_expect(_tm.required_grip(20.0, 2.0) > _tm.required_grip(20.0, 0.0),
		"moving fast on a slope needs more grip than standing")

	_expect(_tm.slip_rate(0.3) < 0.01, "a generous grip margin almost never slips")
	_expect(_tm.slip_rate(0.05) > 0.3, "a thin grip margin slips every few seconds")
	_expect(_tm.slip_rate(-0.01) >= 10.0, "no grip margin means slipping now")
	_expect(_tm.slip_escalation_chance(0.2) < _tm.slip_escalation_chance(0.02),
		"slips on thin margins turn into slides and falls more often")


# =============================================================================
# DOWNCLIMBING
# =============================================================================

func _check_downclimbing() -> void:
	var boots: int = _footwear["BOOTS"]
	var crampons: int = _footwear["CRAMPONS"]

	var rock_50: float = _rock_downclimb_margin(50.0, boots)
	_expect(rock_50 > 0.0, "50 deg rock can be downclimbed facing in (margin %.2f)" % rock_50)
	var rock_62: float = _rock_downclimb_margin(62.0, boots)
	_expect(rock_62 < 0.0, "62 deg rock needs the rope (margin %.2f)" % rock_62)

	var snow: int = _surface["SNOW_FIRM"]
	var snow_support: float = _tm.downclimb_support(snow, true, 1.0, 0.8, crampons)
	var snow_margin: float = _tm.foot_grip(snow, crampons) + snow_support - _tm.required_grip(50.0, 0.4)
	_expect(snow_margin > 0.2, "50 deg firm snow with crampons and axe is solid (margin %.2f)" % snow_margin)

	var ice: int = _surface["ICE"]
	var ice_boots: float = _tm.foot_grip(ice, boots) + _tm.downclimb_support(ice, true, 1.0, 0.8, boots) - _tm.required_grip(40.0, 0.3)
	_expect(ice_boots < 0.0, "40 deg ice in boots cannot be downclimbed even with an axe")

	var snow_speed: float = _tm.downclimb_speed(45.0, snow, crampons)
	var rock_speed: float = _tm.downclimb_speed(55.0, _surface["ROCK_DRY"], boots)
	_expect(snow_speed > rock_speed and snow_speed < 0.7,
		"downclimbing is slow (snow %.2f m/s) and slower on steep rock (%.2f m/s)" % [snow_speed, rock_speed])
	var boot_ice: float = _tm.downclimb_speed(45.0, ice, boots)
	var point_ice: float = _tm.downclimb_speed(45.0, ice, crampons)
	_expect(boot_ice < point_ice, "front-pointing on ice beats shuffling in boots")


func _rock_downclimb_margin(slope: float, footwear: int) -> float:
	var rock: int = _surface["ROCK_DRY"]
	var grip: float = _tm.foot_grip(rock, footwear)
	var support: float = _tm.downclimb_support(rock, true, 1.0, 0.8, footwear)
	return grip + support - _tm.required_grip(slope, 0.3)


# =============================================================================
# WALKING
# =============================================================================

func _check_walking_pace() -> void:
	var firm: int = _surface["SNOW_FIRM"]
	var flat: float = _tm.tobler_factor(0.0, 0.0, firm)
	_expect(absf(flat - 1.0) < 0.01, "walking pace is unchanged on the flat")

	var grade_25 := tan(deg_to_rad(25.0))
	var down: float = _tm.tobler_factor(-grade_25, 0.0, firm)
	var up: float = _tm.tobler_factor(grade_25, 0.0, firm)
	_expect(down > 0.4 and down < 0.7, "a 25 deg descent is slower than the flat (%.2f)" % down)
	_expect(up < 0.3 and up < down, "a 25 deg climb is much slower than the descent (%.2f)" % up)

	var gentle: float = _tm.tobler_factor(-0.05, 0.0, firm)
	_expect(gentle >= flat, "a gentle downhill is the quickest walking")

	var plunge: float = _tm.tobler_factor(-grade_25, 0.0, _surface["SNOW_SOFT"])
	_expect(plunge > down, "plunge-stepping down soft snow beats firm snow (%.2f > %.2f)" % [plunge, down])

	var across: float = _tm.tobler_factor(0.0, grade_25, firm)
	_expect(across < 0.9, "walking across a steep side slope is slower than the flat")

	var crampons: int = _footwear["CRAMPONS"]
	var boots: int = _footwear["BOOTS"]
	_expect(_tm.walk_surface_speed(_surface["ROCK_DRY"], crampons) < _tm.walk_surface_speed(_surface["ROCK_DRY"], boots),
		"crampons slow you down on rock")
	_expect(_tm.walk_surface_speed(_surface["SNOW_POWDER"], boots) < _tm.walk_surface_speed(firm, boots),
		"postholing in powder is slower than firm snow")


# =============================================================================
# GLISSADE
# =============================================================================

func _check_glissade() -> void:
	var soft: int = _surface["SNOW_SOFT"]
	var firm: int = _surface["SNOW_FIRM"]
	var ice: int = _surface["ICE"]

	var soft_braked: float = _tm.slope_acceleration(35.0, _tm.glide_friction(soft) + _tm.brake_friction(soft, true))
	_expect(soft_braked < -1.5, "braking a soft-snow glissade on 35 deg slows you hard (%.2f m/s^2)" % soft_braked)

	var firm_free: float = _tm.slope_acceleration(35.0, _tm.glide_friction(firm))
	_expect(firm_free > 3.0, "an unbraked glissade on 35 deg firm snow runs away (%.2f m/s^2)" % firm_free)

	var firm_braked_30: float = _tm.slope_acceleration(30.0, _tm.glide_friction(firm) + _tm.brake_friction(firm, true))
	_expect(firm_braked_30 < 0.0, "heels and spike can stop a firm-snow glissade on 30 deg (%.2f m/s^2)" % firm_braked_30)

	var ice_braked: float = _tm.slope_acceleration(35.0, _tm.glide_friction(ice) + _tm.brake_friction(ice, true))
	_expect(ice_braked > 3.0, "nothing brakes a slide on 35 deg ice (%.2f m/s^2)" % ice_braked)

	var firm_hold: float = _tm.max_holding_slope(_tm.body_static_friction(firm))
	var soft_hold: float = _tm.max_holding_slope(_tm.body_static_friction(soft))
	_expect(firm_hold < 22.0 and soft_hold > firm_hold,
		"a sliding body comes to rest on gentle firm snow (%.0f deg) and steeper soft snow (%.0f deg)" % [firm_hold, soft_hold])

	var v_term: float = _tm.terminal_speed(35.0, _tm.glide_friction(firm), _tm.BODY_DRAG)
	_expect(v_term > 15.0 and v_term < 30.0, "a body on 35 deg firm snow tops out at %.0f m/s" % v_term)


# =============================================================================
# SELF-ARREST
# =============================================================================

func _check_self_arrest() -> void:
	var firm: int = _surface["SNOW_FIRM"]
	var ice: int = _surface["ICE"]

	var firm_stop: float = _tm.stopping_distance(8.0, 35.0, _tm.arrest_friction(firm, true))
	_expect(firm_stop < 12.0, "an axe arrest from 8 m/s on 35 deg firm snow stops in %.1f m" % firm_stop)

	var ice_stop: float = _tm.stopping_distance(8.0, 35.0, _tm.arrest_friction(ice, true))
	_expect(is_inf(ice_stop), "an axe arrest cannot stop a slide on 35 deg ice")

	var hands_stop: float = _tm.stopping_distance(8.0, 35.0, _tm.arrest_friction(firm, false))
	_expect(is_inf(hands_stop) or hands_stop > firm_stop * 3.0,
		"without an axe a 35 deg firm-snow slide is nearly unstoppable")

	var soft_hands: float = _tm.stopping_distance(4.0, 28.0, _tm.arrest_friction(_surface["SNOW_SOFT"], false))
	_expect(soft_hands < 15.0, "hands and boots can stop a slow slide on soft 28 deg snow (%.1f m)" % soft_hands)

	_expect(_tm.arrest_hold_speed(ice) < _tm.arrest_hold_speed(firm),
		"the pick is torn out at lower speed on ice than on snow")


# =============================================================================
# SKIS
# =============================================================================

func _check_skis() -> void:
	var firm: int = _surface["SNOW_FIRM"]
	var powder: int = _surface["SNOW_POWDER"]
	var ice: int = _surface["ICE"]

	var straight: float = _tm.terminal_speed(35.0, _tm.ski_glide(firm), _tm.SKI_DRAG_UPRIGHT)
	_expect(straight > 30.0, "straight-lining 35 deg firm snow on skis reaches %.0f m/s: speed is controlled by turning" % straight)

	var firm_edge: float = _tm.ski_edge_grip(firm, false)
	var ice_edge: float = _tm.ski_edge_grip(ice, false)
	_expect(_tm.max_holding_slope(firm_edge) > 40.0, "a set edge holds across 40 deg firm snow")
	_expect(_tm.max_holding_slope(ice_edge) < 20.0, "edges skitter across ice")
	_expect(_tm.ski_edge_grip(firm, true) < firm_edge, "a splitboard edge holds a little less than two skis")

	var brake_firm: float = _tm.ski_brake_grip(firm)
	_expect(brake_firm * cos(deg_to_rad(30.0)) > sin(deg_to_rad(30.0)) * 0.9,
		"a hockey stop can stop you on 30 deg firm snow")
	var brake_ice: float = _tm.ski_brake_grip(ice)
	_expect(brake_ice < tan(deg_to_rad(30.0)), "a skid cannot stop you on 30 deg ice")

	_expect(_tm.ski_sink_drag(powder, false) > _tm.ski_sink_drag(firm, false), "deep powder slows skis")
	_expect(_tm.ski_sink_drag(powder, true) < _tm.ski_sink_drag(powder, false), "a board floats better in powder")
	_expect(not _tm.is_skiable(_surface["ROCK_DRY"]) and _tm.is_skiable(firm), "skis do not run on rock")


# =============================================================================
# HARNESS
# =============================================================================

func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_physics_model] ok: %s" % what)
	else:
		print("[test_physics_model] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	if _failures.is_empty():
		print("[test_physics_model] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_physics_model] FAIL (%d of %d): %s" % [_failures.size(), _checks, "; ".join(_failures)])
		quit(1)
