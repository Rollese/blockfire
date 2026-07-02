class_name BotRoles
extends RefCounted
## Explicit, DISJOINT gate-exerciser role assignment for the bot fleet (batch 5.5).
##
## The old scattered index-modulo checks silently overlapped: %4==0 (weapon swapper) is
## exactly %8==0 (climb driller) ∪ %8==4 (shovel driller) — so every "swapper" was a
## driller being interrupted mid-drill, and NO plain rifleman ever exercised the swap path.
## Each bot now gets exactly ONE role, first match wins. Slots are per-process indexes
## (BOT_COUNT=8 in the Docker fleet, 48 in the CI smoke), so every deployment shape keeps
## at least one bot per role per process where the count allows.
##
##   CREW     index % 5 == 1, capped at MAX_VEHICLE_BOTS per process (vehicle gates)
##   SHOVEL   index % 8 == 4  (build/shovel drill; LARGE-coop sub-subset: % 16 == 4)
##   CLIMB    index % 8 == 0  (ladder/vault drill)
##   SWAP     index % 8 == 2  (weapon quick-swap cycle — now disjoint from the drillers)
##   FIREMODE index % 8 == 3  (fire-mode cycle; the driver still skips Engineers — SMG lacks BURST)
##   RIFLE    everyone else (the majority — plain combat)
##
## Class-gated exercisers (Engineer sledge/RPG) stay decided in the driver: class is a
## runtime property, these roles are pure index math so gate populations are provable.

const RIFLE := 0
const CREW := 1
const SHOVEL := 2
const CLIMB := 3
const SWAP := 4
const FIREMODE := 5

const MAX_VEHICLE_BOTS := 6   # crew bots per process; minority so the win-convergence holds


static func of(index: int) -> int:
	if index % 5 == 1 and index < MAX_VEHICLE_BOTS * 5:
		return CREW
	if index % 8 == 4:
		return SHOVEL
	if index % 8 == 0:
		return CLIMB
	if index % 8 == 2:
		return SWAP
	if index % 8 == 3:
		return FIREMODE
	return RIFLE


## LARGE-cooperation shovel sub-subset: converges on the shared per-team heavy_barricade.
static func large_coop(index: int) -> bool:
	return index % 16 == 4 and of(index) == SHOVEL
