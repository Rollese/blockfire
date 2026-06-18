class_name WorldModel
extends RefCounted
## Snapshot-derived per-bot world view. Built fresh each AI tick by Perception.
## All fields derive ONLY from the interest snapshot (fair-play; see docs/specs/bot-ai.md §3).
var self_state: EntityState = null
var enemies: Array[Dictionary] = []        # {id, pos, stance, dist, last_seen_tick}; optional combat-scoring fields hp_frac/priority added when perception populates them
var allies: Array[Dictionary] = []          # {id, pos, dist}
var downed_allies: Array[Dictionary] = []   # {id, pos, dist}
var cover: Array[Vector3] = []               # candidate cover centres
var objectives: Array[Dictionary] = []      # {pos, owner}
var incoming_fire: float = 0.0               # 0..1 inferred pressure
var now_tick: int = 0
var metadata_hp_frac: float = 1.0            # self health fraction, filled by Perception/AiDriver
