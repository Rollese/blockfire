class_name SimLoop
extends RefCounted
## Fixed-timestep deterministic simulation — the keystone of the netcode.
## M0 is a stub: it just counts ticks. M1 implements the real authoritative step
## (movement, ballistics, capture logic) here so that the SAME code runs on the
## server (authority), the client (prediction), and each bot. Keeping rules in
## shared/ is what prevents prediction/authority drift. See docs/AGENTS.md §7.
##
## ADR-0001: this stays GDScript until M1 profiling proves we must escalate the
## hot path to a GDExtension; callers depend only on this narrow interface.

var tick: int = 0


## Advance the world by exactly one fixed tick given the inputs collected this tick.
## inputs: role-defined collection of per-entity input command frames (M1).
func step(_dt: float, _inputs: Variant = null) -> void:
	tick += 1
