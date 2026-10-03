class_name AlpineGrade
extends RefCounted
## The IFAS alpine grade scale (F, PD, AD, D, TD, ED with - and +) worked out
## from what a line actually asks of the climber, plus a commitment grade
## (I-VI) from how long it takes.
##
## Guidebook authors grade snow and ice routes mostly by the steepest
## sustained ground, then adjust for how long the steep ground goes on, for
## abseils, for exposure (what a slip would cost) and for ice. The numbers
## below follow the usual angle bands:
##   F   up to ~30 deg        easy snow, walking with an axe
##   PD  30-35 deg (PD+ ~40)  some steep snow, short exposed steps
##   AD  35-45 deg            sustained steep snow/ice, rope often used
##   D   45-55 deg            serious, abseils likely
##   TD  55-70 deg            very sustained, several abseils
##   ED  70 deg and beyond    extreme
##
## grade_value() returns a continuous index (0 = F ... 16 = ED3); scoring
## uses the continuous value, the guidebook prints the rounded name.

# =============================================================================
# CONSTANTS
# =============================================================================

const NAMES: Array[String] = [
	"F", "F+", "PD-", "PD", "PD+", "AD-", "AD", "AD+",
	"D-", "D", "D+", "TD-", "TD", "TD+", "ED1", "ED2", "ED3"
]

## Steepest sustained slope (deg) -> grade index, piecewise linear
const SLOPE_BANDS: Array[Vector2] = [
	Vector2(25.0, 0.0),
	Vector2(30.0, 1.5),
	Vector2(35.0, 3.5),
	Vector2(40.0, 5.5),
	Vector2(45.0, 7.5),
	Vector2(55.0, 10.5),
	Vector2(70.0, 13.5),
	Vector2(85.0, 16.0),
]

## Commitment grade upper bounds (guidebook hours) for I..V; beyond is VI
const COMMITMENT_HOURS: Array[float] = [2.0, 4.0, 7.0, 12.0, 20.0]
const COMMITMENT_NAMES: Array[String] = ["I", "II", "III", "IV", "V", "VI"]

const MAX_INDEX := 16


# =============================================================================
# GRADING
# =============================================================================

## Continuous grade index for a line.
##   sustained_slope  steepest ~20 m stretch walked or climbed (deg, abseils excluded)
##   steep_metres     horizontal metres at downclimbing angles (>= 35 deg)
##   rappels          abseils needed (or made)
##   exposure         fraction of the line with a drop close below (0-1)
##   ice_metres       horizontal metres of ice steeper than 30 deg
##   glacier_metres   horizontal metres on a crevassed glacier
static func grade_value(
	sustained_slope: float,
	steep_metres: float,
	rappels: int,
	exposure: float,
	ice_metres: float,
	glacier_metres: float = 0.0
) -> float:
	var value := slope_index(sustained_slope)

	# Steep ground that goes on: a long 40 deg face is harder than one move
	if steep_metres > 40.0:
		value += clampf((steep_metres - 40.0) / 120.0, 0.0, 1.0)

	# Abseils: any line that needs the rope is at least AD-, each extra
	# abseil adds commitment (you pull the rope; there is no way back up)
	if rappels > 0:
		value = maxf(value, 5.0) + minf(0.4 * float(rappels - 1), 2.0)

	# What a slip would cost
	value += 1.2 * clampf(exposure, 0.0, 1.0)

	# Steep ice is harder than snow at the same angle
	if ice_metres > 15.0:
		value += clampf((ice_metres - 15.0) / 60.0, 0.0, 1.0)

	# Crevassed glacier: route finding, probing, the chance of a bridge going
	if glacier_metres > 40.0:
		value += 0.5 + clampf((glacier_metres - 40.0) / 300.0, 0.0, 0.5)

	return clampf(value, 0.0, float(MAX_INDEX))


## Grade index from the steepest sustained slope alone
static func slope_index(slope_degrees: float) -> float:
	if slope_degrees <= SLOPE_BANDS[0].x:
		return 0.0
	for i in range(1, SLOPE_BANDS.size()):
		var hi: Vector2 = SLOPE_BANDS[i]
		if slope_degrees <= hi.x:
			var lo: Vector2 = SLOPE_BANDS[i - 1]
			var t := (slope_degrees - lo.x) / (hi.x - lo.x)
			return lerpf(lo.y, hi.y, t)
	return float(MAX_INDEX)


static func grade_index(value: float) -> int:
	return clampi(roundi(value), 0, MAX_INDEX)


## Printed grade ("AD+") for a continuous value
static func grade_name(value: float) -> String:
	return NAMES[grade_index(value)]


## The adjectival name of the grade family
static func grade_word(value: float) -> String:
	var index := grade_index(value)
	if index <= 1:
		return "Facile"
	elif index <= 4:
		return "Peu Difficile"
	elif index <= 7:
		return "Assez Difficile"
	elif index <= 10:
		return "Difficile"
	elif index <= 13:
		return "Très Difficile"
	return "Extrêmement Difficile"


## One-line plain-language reading of the grade, for the guidebook
static func grade_summary(value: float) -> String:
	var index := grade_index(value)
	if index <= 1:
		return "Easy snow and walking; an axe in hand on the steeper bits."
	elif index <= 4:
		return "Some steep snow and short exposed steps. Crampons and axe."
	elif index <= 7:
		return "Sustained steep ground, facing in. A rope is often used."
	elif index <= 10:
		return "Serious: steep faces and abseils. Not a place to slip."
	elif index <= 13:
		return "Very sustained steep ground with several abseils."
	return "Extreme. Every move counts."


## Colour family for UI (green F -> purple ED)
static func grade_color(value: float) -> Color:
	var index := grade_index(value)
	if index <= 1:
		return Color(0.35, 0.72, 0.42)
	elif index <= 4:
		return Color(0.6, 0.74, 0.3)
	elif index <= 7:
		return Color(0.86, 0.64, 0.22)
	elif index <= 10:
		return Color(0.86, 0.36, 0.22)
	elif index <= 13:
		return Color(0.72, 0.22, 0.32)
	return Color(0.58, 0.24, 0.6)


# =============================================================================
# COMMITMENT
# =============================================================================

## Commitment grade (I-VI) from the guidebook time in game minutes
static func commitment(minutes: float) -> String:
	var hours := minutes / 60.0
	for i in range(COMMITMENT_HOURS.size()):
		if hours < COMMITMENT_HOURS[i]:
			return COMMITMENT_NAMES[i]
	return COMMITMENT_NAMES[COMMITMENT_NAMES.size() - 1]


## "AD+ III" style full grade
static func full_grade(value: float, minutes: float) -> String:
	return "%s %s" % [grade_name(value), commitment(minutes)]
