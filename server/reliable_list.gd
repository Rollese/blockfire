class_name ReliableList
extends RefCounted
## The changed+heartbeat send decision for reliable list broadcasts (GADGET_LIST,
## SUPPORT_LIST, DOWNED_LIST, FOB_LIST): the list is rebuilt every tick from live state,
## sent reliably only when the encoded bytes CHANGE, plus a ~1 Hz heartbeat while
## non-empty so late joiners converge without per-client bookkeeping. An empty list
## never heartbeats (nothing to miss). One instance per message kind.

const HEARTBEAT_TICKS := 30   # ~1 Hz @30Hz

var _sent = null       # last payload sent: PackedByteArray, or Dictionary for per-team packets
var _hb_tick := 0


## Decide-and-latch: true means "send now" (the payload+clock are recorded as sent).
## `payload` compares by content (PackedByteArray or Dictionary both deep-compare).
func should_send(payload, non_empty: bool, tick: int) -> bool:
	var changed: bool = payload != _sent
	var heartbeat: bool = non_empty and tick - _hb_tick >= HEARTBEAT_TICKS
	if not changed and not heartbeat:
		return false
	_sent = payload
	_hb_tick = tick
	return true
