class_name RunMoments
extends RefCounted
## What happened on a run, in the words the post-game screens use.
##
## The logbook's "Key Moments" and the map replay both list the decisions and
## incidents a run recorded. This is the one place that says which of them are
## worth a line and how the line reads, so the two screens cannot disagree.
##
## A moment is a Dictionary:
##   type         what was recorded ("start_slide", "obstacle_impact", ...)
##   time         game hours since the run started
##   position     where the climber was
##   details      what the system that recorded it attached
##   is_incident  recorded as an incident (something that happened to you)
##   text         the line to show, without a time
##   kind         a Kind, for colour

## Broad kinds of moment (the map replay colours its markers by these)
enum Kind { DECISION, SLIDE, ROPE, HAZARD, HURT, FATAL }

## Recorded for bookkeeping, or so often that listing them buries the rest.
## "fall" is the risk system's jolt (a camera shake when the odds were bad),
## not the climber falling: real falls are "fall_from_slip", "hard_landing",
## "fall_injury" and the slides.
const NOT_MOMENTS: Array[String] = [
	"micro_slip", "slide_ended", "fall_started", "fall", "run_complete", "self_arrest_success",
]

const SLIDE_TYPES: Array[String] = [
	"start_slide", "self_arrest", "self_arrest_failed", "slide_from_slip", "slide_upset",
	"slide_impact", "ski_crash", "skis_broken",
]
const ROPE_TYPES: Array[String] = [
	"deploy_rope", "rappel_complete", "anchor_failure", "rope_jam", "rope_lost",
	"rope_end_reached", "rope_deployment_failed",
]
const HAZARD_TYPES: Array[String] = [
	"whumpf", "shooting_cracks", "snow_pit", "probe", "airbag_deployed", "avalanche_triggered",
	"avalanche_natural", "avalanche_caught", "avalanche_burial", "avalanche_survived", "dug_out",
	"serac_fall", "crevasse_fall", "crevasse_slip", "crevasse_climbed_out",
]
const FATAL_TYPES: Array[String] = ["terminal_slide", "fatal_fall", "exposure_death", "avalanche_fatal"]


## Every moment of a run worth a line, in the order they happened
static func collect(run: RunContext) -> Array[Dictionary]:
	var moments: Array[Dictionary] = []
	if run == null:
		return moments
	for decision in run.decisions:
		_add(moments, decision, false)
	for incident in run.incidents:
		_add(moments, incident, true)
	moments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] < b["time"])
	return moments


static func _add(moments: Array[Dictionary], entry: Dictionary, is_incident: bool) -> void:
	var type: String = str(entry.get("type", ""))
	var attached: Variant = entry.get("details", {})
	var details: Dictionary = attached if attached is Dictionary else {}
	var text := describe(type, details, is_incident)
	if text.is_empty():
		return
	moments.append({
		"type": type,
		"time": float(entry.get("game_time", 0.0)),
		"position": entry.get("position", Vector3.ZERO),
		"details": details,
		"is_incident": is_incident,
		"text": text,
		"kind": kind_of(type, is_incident),
	})


## The line for one recorded decision or incident; "" for one not worth a line
static func describe(type: String, details: Dictionary, is_incident: bool) -> String:
	if type in NOT_MOMENTS:
		return ""
	match type:
		"start_slide":
			return "Started sliding"
		"start_downclimb":
			return "Began downclimbing (%.0f°)" % float(details.get("slope", 0.0))
		"start_skiing":
			return "Clicked in and skied"
		"deploy_rope":
			return "Deployed rope"
		"rappel_complete":
			return "Abseiled"
		"self_arrest":
			return "Self-arrested"
		"self_arrest_failed":
			return "The self-arrest did not hold"
		"slide_from_slip":
			return "Slipped into a slide"
		"slide_upset":
			return "Flipped in the slide"
		"slide_impact":
			return "Hit rock in the slide"
		"fall_from_slip":
			return "Slipped and fell"
		"fall_over":
			return "Went down on the spot"
		"hard_landing":
			return "Hard landing"
		"fall_injury":
			return "%s from fall" % str(details.get("type", "injury")).capitalize()
		"injury":
			return "Hurt"
		"collapse":
			return "Collapsed from exhaustion"
		"incapacitated":
			return "Became incapacitated"
		"terminal_slide", "fatal_fall", "exposure_death", "avalanche_fatal":
			return "Fatal incident"
		"summit_reached":
			return "Summit"
		"ski_crash":
			return "Crashed on the skis"
		"skis_broken":
			return "A binding tore out"
		"anchor_failure":
			return "The anchor failed"
		"rope_jam":
			return "The rope jammed"
		"rope_lost":
			return "Lost the rope"
		"rope_end_reached":
			return "Reached the end of the rope"
		"rope_deployment_failed":
			return "Found nothing to anchor to"
		"avalanche_triggered":
			return "Triggered an avalanche"
		"avalanche_natural":
			return "An avalanche ran nearby"
		"serac_fall":
			return "A serac fell from the icefall"
		"avalanche_caught":
			return "Caught in an avalanche"
		"avalanche_burial":
			return "Buried in the debris"
		"avalanche_survived":
			return "Out of the avalanche"
		"dug_out":
			return "Dug out"
		"airbag_deployed":
			return "Pulled the airbag"
		"whumpf":
			return "The snowpack collapsed underfoot"
		"shooting_cracks":
			return "Shooting cracks"
		"snow_pit":
			return "Dug a snow pit: %s" % str(details.get("result", "")).get_slice(".", 0)
		"crevasse_fall":
			return "Fell into a crevasse"
		"crevasse_slip":
			return "Slipped back down the crevasse wall"
		"crevasse_climbed_out":
			return "Climbed out of the crevasse"
		"probe":
			return "Probed a hidden crevasse" if details.get("hollow", false) else ""
		"obstacle_impact":
			return "Hit a %s" % ("boulder" if str(details.get("object", "tree")) == "boulder" else "tree")
	# An incident nobody wrote a line for still happened; a decision without
	# one (the camera director logs its own) says nothing to the climber
	if is_incident and not type.is_empty():
		return type.replace("_", " ").capitalize()
	return ""


static func kind_of(type: String, is_incident: bool) -> Kind:
	if type in FATAL_TYPES:
		return Kind.FATAL
	if type in SLIDE_TYPES:
		return Kind.SLIDE
	if type in ROPE_TYPES:
		return Kind.ROPE
	if type in HAZARD_TYPES:
		return Kind.HAZARD
	return Kind.HURT if is_incident else Kind.DECISION


## Game hours as "H:MM" into the run
static func elapsed(game_hours: float) -> String:
	var minutes := int(round(maxf(game_hours, 0.0) * 60.0))
	return "%d:%02d" % [minutes / 60, minutes % 60]


## The time of day ("HH:MM") a number of game hours into a run
static func clock(run: RunContext, game_hours: float) -> String:
	var start := 6.0
	if run != null and run.start_conditions != null:
		start = run.start_conditions.time_of_day
	var minutes := int(round(fposmod(start + game_hours, 24.0) * 60.0)) % (24 * 60)
	return "%02d:%02d" % [minutes / 60, minutes % 60]
