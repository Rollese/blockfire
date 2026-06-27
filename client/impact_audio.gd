class_name ImpactAudio
extends Object
## Pure map from a bullet-impact surface kind (Protocol.IMPACT_*) to the audio event played at the
## hit point (M7, view-only — AGENTS.md §7). Pairs with BulletPassby: the crack/whiz is the round
## passing the listener, this is the thud where it terminates. Hard surfaces (wall/dirt) thud;
## flesh stays silent (it already gets a blood puff, and a concrete tink on a body reads wrong).

static func sound_for(kind: int) -> String:
	match kind:
		Protocol.IMPACT_WALL, Protocol.IMPACT_DIRT:
			return "impact"
		_:
			return ""
