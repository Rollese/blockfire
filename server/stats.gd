class_name ServerStats
extends RefCounted
## The server's per-telemetry-window counter wall + the [telemetry] line, extracted from
## server_main (batch 5.2). Every counter resets each window in reset_window() EXCEPT
## cap_events_total (cumulative, feeds the match-end summary). The line format is
## gate-scraper-critical: docker/_gate_lib.sh greps anchored `(^| )name=` fields out of
## it — tests/server_stats_test.gd pins the format.

# Combat
var kills := 0
var shots := 0
var hits := 0
var rewind_clamped := 0
# Conquest
var cap_events := 0          # per-window (reset each second)
var cap_events_total := 0    # cumulative over the match (match-end summary) — NOT window-reset
# Structures / building
var builds := 0
var removes := 0
var shots_blocked := 0
var pen := 0                 # bullet penetrations through a piece
var dmg := 0                 # damage events applied
var destroyed := 0           # pieces removed by damage/blast
var collapsed := 0           # buildings collapsed
# Ordnance
var nades := 0               # frag detonations
var splash_kills := 0        # pawn deaths from blasts
var smokes := 0              # smoke zones deployed
var rockets_det := 0         # RPG rockets detonated
var rstruct := 0             # structures hit by rockets
var c4_det := 0              # C4 detonations (per detonate action)
var mine_trips := 0          # claymore/mine detonations
# Stepped projectiles
var proj_fired := 0
var proj_hits := 0
var proj_live_max := 0       # max concurrent live projectiles observed
var proj_dropped := 0        # spawns refused because the pool was full
var dbg_last_min_y := INF    # test seam only: lowest y any stepped projectile reached
# DBNO / support
var downed := 0
var bleedouts := 0
var revives := 0
var bleeds_started := 0      # M16: standing bleeds started (below-threshold bullet/blast hits)
var bandages := 0            # M16: completed bandage channels (standing-bleed stopped + healed)
var bleed_downs := 0         # M16: pawns downed by a standing bleed draining to 0
var heals := 0               # active+bag HP-dispensing events
var ammo_gives := 0          # active+bag ammo-resupply events
var bags_thrown := 0
var bags_exhausted := 0      # bags that hit pool 0 and vanished
# Movement
var climbs := 0
var vaults := 0
var drop_shoot_blocked := 0  # shots rejected by the prone-transition gate
# Vehicles
var enters := 0
var exits := 0
var veh_destroyed := 0
var repairs := 0             # HP restored
var repair_overheats := 0
var rkt_vs_veh := 0
var transport_max := 0.0     # max carried distance observed
# Misc
var ac_viol := 0             # view-rate anomalies (telemetry-only)
var swaps := 0               # weapon quick-swaps
var suppress_events := 0     # near-miss suppression accruals (M5.5-P2)
# Melee / flash / impact (M5.5-P3)
var melees := 0
var backstabs := 0
var sledge_hits := 0
var flashes := 0
var flash_blinds := 0
var impacts := 0
# Shovel construction / FOBs (M12)
var built_small := 0
var built_large := 0
var build_blocked_solo := 0
var dismantled := 0
var repaired := 0
var fobs_built := 0
var fob_spawns := 0
var fob_disabled := 0
var fobs_destroyed := 0


## The once-a-second [telemetry] line. Externals the counters can't know are passed in
## precomputed: player/alive counts, Telemetry window stats, mean pkt loss, tickets,
## the conquest points ownership string and the structure-store count.
func telemetry_line(players: int, alive: int, tick_mean: float, tick_p99: float,
		mbit: float, pktloss: float, starv: int, t0: int, t1: int, pts: String,
		struct_count: int) -> String:
	var hit_rate := 0.0 if shots == 0 else float(hits) / float(shots)
	return ("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s pktloss=%.2f%% kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d t0=%d t1=%d pts=%s cap_events=%d struct=%d bld=%d rmv=%d blk=%d pen=%d dmg=%d destroyed=%d collapsed=%d nades=%d splash=%d smoke=%d rockets=%d rstruct=%d proj=%d projhit=%d projlive=%d projdrop=%d downed=%d bleedouts=%d revives=%d bleeds=%d bandages=%d bleeddowns=%d c4=%d mines=%d heals=%d ammo=%d bags=%d bagx=%d climbs=%d vaults=%d dropblk=%d enters=%d exits=%d veh_dead=%d repairs=%d repair_oh=%d rkt_veh=%d transport_m=%.1f ac_viol=%d swaps=%d supp=%d melees=%d backstabs=%d sledge=%d flashes=%d flashblinds=%d impacts=%d built_small=%d built_large=%d bsolo=%d dismantled=%d repaired=%d fobs_built=%d fob_spawns=%d fob_disabled=%d fobs_destroyed=%d"
		% [players, alive, tick_mean, tick_p99, mbit, pktloss, kills, shots, hit_rate, starv, rewind_clamped, t0, t1, pts, cap_events, struct_count, builds, removes, shots_blocked, pen, dmg, destroyed, collapsed, nades, splash_kills, smokes, rockets_det, rstruct, proj_fired, proj_hits, proj_live_max, proj_dropped, downed, bleedouts, revives, bleeds_started, bandages, bleed_downs, c4_det, mine_trips, heals, ammo_gives, bags_thrown, bags_exhausted, climbs, vaults, drop_shoot_blocked, enters, exits, veh_destroyed, repairs, repair_overheats, rkt_vs_veh, transport_max, ac_viol, swaps, suppress_events, melees, backstabs, sledge_hits, flashes, flash_blinds, impacts, built_small, built_large, build_blocked_solo, dismantled, repaired, fobs_built, fob_spawns, fob_disabled, fobs_destroyed])


func reset_window() -> void:
	kills = 0; shots = 0; hits = 0; rewind_clamped = 0; cap_events = 0
	builds = 0; removes = 0; shots_blocked = 0; pen = 0
	dmg = 0; destroyed = 0; collapsed = 0
	nades = 0; splash_kills = 0; smokes = 0; rockets_det = 0; rstruct = 0
	c4_det = 0; mine_trips = 0
	proj_fired = 0; proj_hits = 0; proj_live_max = 0; proj_dropped = 0; dbg_last_min_y = INF
	downed = 0; bleedouts = 0; revives = 0; heals = 0; ammo_gives = 0
	bleeds_started = 0; bandages = 0; bleed_downs = 0
	bags_thrown = 0; bags_exhausted = 0
	climbs = 0; vaults = 0; drop_shoot_blocked = 0
	enters = 0; exits = 0; veh_destroyed = 0; repairs = 0; repair_overheats = 0
	rkt_vs_veh = 0; transport_max = 0.0
	ac_viol = 0; swaps = 0; suppress_events = 0
	melees = 0; backstabs = 0; sledge_hits = 0; flashes = 0; flash_blinds = 0; impacts = 0
	built_small = 0; built_large = 0; build_blocked_solo = 0; dismantled = 0; repaired = 0
	fobs_built = 0; fob_spawns = 0; fob_disabled = 0; fobs_destroyed = 0
