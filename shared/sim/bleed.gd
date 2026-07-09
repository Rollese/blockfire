class_name Bleed
extends Object
## Pure standing-bleed rules (M16). No side effects and no Pawn references — the server holds
## the bleed flag on Pawn and calls these helpers to decide start/drain, keeping the rules in
## shared/ (AGENTS.md §7). See docs/superpowers/specs/2026-07-03-standing-bleed-bandage-design.md.
##
## Distinct from the DOWNED halving-bleedout (shared/sim/revive.gd): this drains the STANDING
## `health` pool after a below-threshold hit; a bleed-out routes into the same DBNO death path.

const BLEED_THRESHOLD := 60   # post-hit HP below which a qualifying hit starts a standing bleed
const BLEED_RATE_TICKS := 6   # ticks per 1 HP lost while standing-bleeding (~5 HP/s @30 Hz)

## A qualifying hit starts a bleed when it leaves the pawn alive but wounded (below the threshold)
## and the source is a bullet or blast. Fall damage never bleeds; a lethal hit (hp<=0) is a kill,
## not a bleed.
static func should_start(post_hit_hp: int, source: int) -> bool:
	return post_hit_hp > 0 and post_hit_hp < BLEED_THRESHOLD \
		and (source == Revive.Source.BULLET or source == Revive.Source.BLAST)

## True on the ticks where a standing bleed loses 1 HP.
static func drain_this_tick(tick: int) -> bool:
	return tick % BLEED_RATE_TICKS == 0
