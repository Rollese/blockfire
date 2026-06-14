class_name Protocol
extends Object
## Wire protocol message (de)serialization. The single source of truth for the
## byte layout used by client, server, and bot driver. This file is the reason
## the three roles can never disagree about the protocol — they all encode/decode
## through here. See docs/AGENTS.md §7.
##
## M0 covers only the connection handshake. M1 extends this with input command
## frames and delta-compressed snapshots (see docs/specs/wire-protocol.md).

const VERSION := 1

enum Msg {
	HELLO = 1,    ## client -> server: protocol version + display name
	WELCOME = 2,  ## server -> client: assigned peer id + server tick rate
	REJECT = 3,   ## server -> client: rejection reason (then disconnect)
	INPUT = 4,    ## client -> server: input command frame (see input_command.gd)
	SNAPSHOT = 5, ## server -> client: delta snapshot (see snapshot.gd)
	KILL = 6,     ## server -> clients: kill event (victim, killer, weapon, headshot)
}


static func encode_hello(player_name: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.HELLO)
	buf.put_u16(VERSION)
	buf.put_utf8_string(player_name)
	return buf.data_array


static func encode_welcome(peer_id: int, tick_rate: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.WELCOME)
	buf.put_u32(peer_id)
	buf.put_u16(tick_rate)
	return buf.data_array


static func encode_reject(reason: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.REJECT)
	buf.put_utf8_string(reason)
	return buf.data_array


## Type byte of a message (0 if empty).
static func msg_type(bytes: PackedByteArray) -> int:
	return bytes[0] if not bytes.is_empty() else 0


## Returns a buffer seeked past the 1-byte type, ready to read the body fields.
static func body_reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)
	return buf


static func encode_kill(victim_id: int, killer_id: int, weapon_id: int, headshot: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.KILL)
	buf.put_u32(victim_id)
	buf.put_u32(killer_id)
	buf.put_u8(weapon_id)
	buf.put_u8(1 if headshot else 0)
	return buf.data_array


static func decode_kill(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"victim": r.get_u32(), "killer": r.get_u32(), "weapon": r.get_u8(), "headshot": r.get_u8() == 1}
