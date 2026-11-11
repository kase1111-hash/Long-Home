class_name AudioFader
extends RefCounted
## Eases a looping player's volume and pitch toward targets
##
## Layers of a soundscape (the wind, a slide, rope running) are never switched
## on and off: they are told what level to be at and drift there. The fader
## starts its player when it becomes audible and stops it once it has faded
## out, so silent layers cost nothing.
##
## The owner calls update() every frame.

## Below this gain (about -60 dB) the layer is off
const SILENT := 0.001

## How far below zero a fade-out aims (see update)
const FADE_OUT_UNDERSHOOT := 0.02

## AudioStreamPlayer or AudioStreamPlayer3D
var player: Node

## Where the gain is heading (linear; 1.0 plays the stream at trim_db)
var level: float = 0.0

## Where the pitch is heading
var pitch: float = 1.0

## Fixed level of this layer in the mix (dB)
var trim_db: float = 0.0

## Seconds to rise and to fall (time constants)
var attack: float = 0.4
var release: float = 0.9

## Current gain
var gain: float = 0.0


func _init(target: Node, trim: float = 0.0, attack_time: float = 0.4, release_time: float = 0.9) -> void:
	player = target
	trim_db = trim
	attack = attack_time
	release = release_time


func update(delta: float) -> void:
	if not is_instance_valid(player):
		return
	var time := attack if level > gain else release
	# A fade to nothing aims a little below it, so it arrives instead of
	# creeping toward silence for ever (about four time constants)
	var aim := level if level > 0.0 else -FADE_OUT_UNDERSHOOT
	gain = maxf(0.0, lerpf(gain, aim, 1.0 - exp(-delta / maxf(time, 0.001))))
	if level <= 0.0 and gain < SILENT:
		gain = 0.0

	if gain >= SILENT and player.get("stream") != null:
		player.set("volume_db", linear_to_db(gain) + trim_db)
		var current: float = player.get("pitch_scale")
		player.set("pitch_scale", maxf(0.05, lerpf(current, pitch, 1.0 - exp(-delta / 0.15))))
		if not player.get("playing"):
			# Start somewhere in the loop, so layers begun together do not line up
			var stream: AudioStream = player.get("stream")
			player.call("play", AudioService.roll() * maxf(stream.get_length() - 0.1, 0.0))
	elif player.get("playing"):
		player.call("stop")


## Stop at once (a cut, not a fade)
func cut() -> void:
	level = 0.0
	gain = 0.0
	if is_instance_valid(player) and player.get("playing"):
		player.call("stop")


func is_audible() -> bool:
	return gain >= SILENT
