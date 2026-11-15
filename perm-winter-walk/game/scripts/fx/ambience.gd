extends Node
## Soft wind: one seamless 60 s stereo loop with a slow random swell on top.

const WIND := preload("res://audio/wind_loop.ogg")

@export var volume_db := -15.0
@export var swell_db := 3.0

var _player: AudioStreamPlayer
var _t := 0.0
var _phase := randf() * 100.0


func _ready() -> void:
	# Looping is set in wind_loop.ogg.import (loop=true), so the stream is used as is.
	_player = AudioStreamPlayer.new()
	_player.name = "Wind"
	_player.stream = WIND
	_player.volume_db = -60.0
	add_child(_player)
	_player.play()
	# Fade in instead of starting abruptly.
	create_tween().tween_property(_player, "volume_db", volume_db, 3.0)


func _process(delta: float) -> void:
	_t += delta
	if _t < 3.0:
		return
	var s := sin((_t + _phase) * 0.13) * 0.6 + sin((_t + _phase) * 0.051) * 0.4
	_player.volume_db = volume_db + s * swell_db


func _exit_tree() -> void:
	_player.stop()
	_player.stream = null


func is_playing() -> bool:
	return _player.playing
