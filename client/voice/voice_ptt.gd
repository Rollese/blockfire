class_name VoicePtt
extends RefCounted
## PTT channel selection. Squad takes precedence when both keys are held so squad comms
## are never accidentally broadcast on the enemy-audible proximity channel. Pure.

const NONE := -1

var _prox_down: bool = false
var _squad_down: bool = false

func set_keys(prox_down: bool, squad_down: bool) -> void:
	_prox_down = prox_down
	_squad_down = squad_down

func active_channel() -> int:
	if _squad_down:
		return VoicePacket.KIND_SQUAD
	if _prox_down:
		return VoicePacket.KIND_PROXIMITY
	return NONE

func transmitting() -> bool:
	return active_channel() != NONE
