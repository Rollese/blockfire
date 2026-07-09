class_name NetHost
extends Node
## Thin wrapper over ENetConnection (low-level ENet). We use ENet purely as a
## UDP transport with our own message layer on top — NOT Godot's high-level
## MultiplayerSynchronizer/RPC system, which does not scale to 128 players.
## See docs/adr/0001-core-runtime-language.md and the M1 netcode spec.
##
## Channels (see docs/specs/wire-protocol.md when written):
##   0 = reliable control/events (handshake, spawns, SELF_STATE, kills, rosters, lists)
##   1 = unreliable-sequenced snapshots (server -> client)
##   2 = unreliable-sequenced input (client -> server)
##   3 = reliable BULK structure traffic (baselines/deltas/collapse) — a separate reliable stream so a
##       dense-map structure-baseline flood can't head-of-line-block latency-critical SELF_STATE on
##       channel 0 (measured ~170 ms p99 stall at 48 bots; docs/reviews/2026-07-03…§D3). App dispatch is
##       by message id (receivers ignore the channel), so this is purely a transport-lane split.

signal peer_connected(peer: ENetPacketPeer)
signal peer_disconnected(peer: ENetPacketPeer)
signal packet_received(peer: ENetPacketPeer, channel: int, bytes: PackedByteArray)

const CHANNELS := 4
const CHANNEL_CONTROL := 0
const CHANNEL_SNAPSHOT := 1
const CHANNEL_INPUT := 2
const CHANNEL_BULK := 3   # reliable bulk structure traffic (own stream; see channel notes above)

var _host: ENetConnection


func start_server(port: int, max_peers: int = 128) -> Error:
	_host = ENetConnection.new()
	return _host.create_host_bound("*", port, max_peers, CHANNELS)


## Returns the server peer on success, or null on failure.
func start_client(ip: String, port: int) -> ENetPacketPeer:
	_host = ENetConnection.new()
	if _host.create_host(1, CHANNELS) != OK:
		return null
	return _host.connect_to_host(ip, port, CHANNELS)


## Drain all pending ENet events. Call once per tick, before stepping the sim.
func poll() -> void:
	# The EVENT_DISCONNECT branch below emits peer_disconnected, whose handler may synchronously
	# tear this host down (client_main._on_disconnected -> close() nulls _host). Re-check _host every
	# iteration — a one-time entry guard can't catch a teardown that happens mid-drain.
	while _host != null:
		var result := _host.service(0)
		var type: int = result[0]
		if type == ENetConnection.EVENT_NONE:
			break
		var peer: ENetPacketPeer = result[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				peer_connected.emit(peer)
			ENetConnection.EVENT_DISCONNECT:
				peer_disconnected.emit(peer)
			ENetConnection.EVENT_RECEIVE:
				var channel: int = result[3]
				packet_received.emit(peer, channel, peer.get_packet())


func send_to(peer: ENetPacketPeer, channel: int, bytes: PackedByteArray, flags: int) -> void:
	if peer != null:
		peer.send(channel, bytes, flags)


func peers() -> Array:
	return _host.get_peers() if _host != null else []


## Politely disconnect every connected peer (flushes queued reliable sends first).
## Used at the map-rotation match boundary (M8-P3).
func disconnect_all() -> void:
	for peer in peers():
		peer.peer_disconnect_later()


func close() -> void:
	if _host != null:
		_host.destroy()
		_host = null
