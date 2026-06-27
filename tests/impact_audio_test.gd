extends TestCase
## ImpactAudio (M7): maps a bullet-impact surface kind to the audio event that plays at the hit
## point. Pairs with BulletPassby — the crack is the round passing, this is where it lands.

func test_wall_hit_thuds() -> void:
	assert_eq(ImpactAudio.sound_for(Protocol.IMPACT_WALL), "impact", "a round into a wall thuds")

func test_dirt_hit_thuds() -> void:
	assert_eq(ImpactAudio.sound_for(Protocol.IMPACT_DIRT), "impact", "a round into the ground thuds")

func test_flesh_hit_is_silent() -> void:
	# A hard concrete-thud on a body reads wrong; flesh hits get visual blood, not a stone tink.
	assert_eq(ImpactAudio.sound_for(Protocol.IMPACT_FLESH), "", "a flesh hit plays no concrete impact")

func test_unknown_kind_is_silent() -> void:
	assert_eq(ImpactAudio.sound_for(99), "", "an unknown surface kind plays nothing (no crash)")
