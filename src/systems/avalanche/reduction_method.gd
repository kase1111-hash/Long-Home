class_name ReductionMethod
extends RefCounted
## Werner Munter's reduction method: a planning check that weighs the
## day's danger against the line's terrain.
##
##   danger potential (2, 4, 8, 16 for Low..High)
##   ÷ first-class factor (the steepest slope of the line: 35-39 deg 2,
##     under 35 deg 4; 40 deg or more gets none)
##   ÷ second-class factor (keeping off the north sector NW-N-NE 2, off the
##     northern half 3, off the aspects the bulletin names 4; not valid in
##     wet snow)
##   = residual risk; 1 or less is acceptable.
##
## A solo climber gets no group factor. The method is a filter for
## planning, not a guarantee; the game prints it the way a hut book would.

const POTENTIAL: Array[float] = [0.0, 2.0, 4.0, 8.0, 16.0, 32.0]
## North sector (NW, N, NE) and northern half (NW, N, NE, E: WNW to ESE)
const NORTH_SECTOR := 0b10000011
const NORTH_HALF := 0b10000111


## Evaluate a line (its avalanche terrain) against today's conditions
static func evaluate(conditions: AvalancheConditions, metrics: RouteMetrics.Result) -> Dictionary:
	var out := {
		"applies": false, "danger": 1, "potential": 2.0, "rf1": 1.0, "rf2": 1.0,
		"rf1_reason": "", "rf2_reason": "", "residual": 0.0, "acceptable": true, "text": "",
	}
	if conditions == null or metrics == null:
		return out
	var danger := _line_danger(conditions, metrics)
	out.danger = danger
	out.potential = POTENTIAL[danger]
	if metrics.avalanche_metres < 6.0:
		out.text = "Reduction method: the line has no open slopes of 30° or more."
		return out
	out.applies = true

	var steepest := metrics.avalanche_max_slope
	if steepest < 35.0:
		out.rf1 = 4.0
		out.rf1_reason = "steepest slope under 35°"
	elif steepest < 40.0:
		out.rf1 = 2.0
		out.rf1_reason = "steepest slope %d°" % floori(steepest)
	else:
		out.rf1_reason = "slopes of 40° or more"

	var main := conditions.get_main_problem()
	var aspects := metrics.avalanche_aspects()
	if main != null and main.is_wet():
		out.rf2_reason = "wet snow: aspect factors do not apply"
	else:
		var named := 0
		for p in conditions.problems:
			if not p.is_wet():
				named |= p.aspects
		if named != 0 and aspects & named == 0:
			out.rf2 = 4.0
			out.rf2_reason = "avoids the aspects the bulletin names"
		elif aspects & NORTH_HALF == 0:
			out.rf2 = 3.0
			out.rf2_reason = "keeps off the northern half"
		elif aspects & NORTH_SECTOR == 0:
			out.rf2 = 2.0
			out.rf2_reason = "keeps off the north sector"
		else:
			out.rf2_reason = "on the aspects of concern"

	out.residual = float(out.potential) / (float(out.rf1) * float(out.rf2))
	out.acceptable = float(out.residual) <= 1.0
	out.text = "Reduction method: %d ÷ %d (%s) ÷ %d (%s) = %s → %s" % [
		roundi(out.potential), roundi(out.rf1), out.rf1_reason, roundi(out.rf2), out.rf2_reason,
		_number(out.residual), "acceptable" if out.acceptable else "not recommended"
	]
	return out


## The highest danger among the elevation bands the line passes through
static func _line_danger(conditions: AvalancheConditions, metrics: RouteMetrics.Result) -> int:
	var low := minf(metrics.start_elevation, metrics.end_elevation)
	var high := maxf(metrics.start_elevation, metrics.end_elevation)
	var danger := 1
	for band in range(conditions.band_of(low), conditions.band_of(high) + 1):
		danger = maxi(danger, conditions.danger[band])
	return danger


static func _number(value: float) -> String:
	if value >= 10.0 or is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return "%.1f" % value
