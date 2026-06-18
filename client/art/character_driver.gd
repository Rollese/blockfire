class_name CharacterDriver
extends Object
## Plays a named clip on a model's AnimationPlayer idempotently (no restart if already current).
## Presentation-only (AGENTS.md §7). Sets the clip's loop_mode each call so the same clip can be
## reused looped (walk) or one-shot (die).

static func drive(ap: AnimationPlayer, clip: String, loop: bool) -> void:
	if ap == null or not ap.has_animation(clip):
		return
	var a := ap.get_animation(clip)
	a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	if ap.current_animation != clip:
		ap.play(clip)
