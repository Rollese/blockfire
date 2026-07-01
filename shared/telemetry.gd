class_name Telemetry
extends RefCounted
## Rolling per-window counters. The server logs and resets these once per second;
## the printed lines are the recorded evidence for the M1 gate.

var _tick_samples: Array[float] = []
var bytes_sent_per_client: Dictionary = {}   # id -> int (this window)
var starvation: int = 0

## ENet's PEER_PACKET_LOSS statistic is a rolling mean scaled by 65536 (full loss). Given the raw
## per-peer values (one per connected client), return the mean loss as a percentage. Pure — the
## server reads `peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS)` per client and passes the list.
const PACKET_LOSS_SCALE := 65536.0
static func mean_packet_loss_pct(raw_losses: Array) -> float:
	if raw_losses.is_empty():
		return 0.0
	var sum := 0.0
	for v in raw_losses:
		sum += float(v)
	return (sum / float(raw_losses.size())) / PACKET_LOSS_SCALE * 100.0

func record_tick_ms(ms: float) -> void:
	_tick_samples.append(ms)

func add_bytes(client_id: int, n: int) -> void:
	bytes_sent_per_client[client_id] = int(bytes_sent_per_client.get(client_id, 0)) + n

func mean_tick_ms() -> float:
	if _tick_samples.is_empty():
		return 0.0
	var s := 0.0
	for v in _tick_samples:
		s += v
	return s / _tick_samples.size()

func p99_tick_ms() -> float:
	if _tick_samples.is_empty():
		return 0.0
	var sorted := _tick_samples.duplicate()
	sorted.sort()
	var idx := mini(int(ceil(0.99 * sorted.size())), sorted.size() - 1)
	return sorted[idx]

## Peak bytes/sec for any single client this window (window assumed ~1s).
func peak_bytes_per_client() -> int:
	var peak := 0
	for id in bytes_sent_per_client:
		peak = maxi(peak, int(bytes_sent_per_client[id]))
	return peak

func total_bytes() -> int:
	var sum := 0
	for id in bytes_sent_per_client:
		sum += int(bytes_sent_per_client[id])
	return sum

func reset_window() -> void:
	_tick_samples.clear()
	bytes_sent_per_client.clear()
	starvation = 0
