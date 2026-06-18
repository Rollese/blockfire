extends TestCase
## Msg.COLLAPSE {building_id:u16} round-trip.

func test_collapse_round_trip() -> void:
	var bytes := Protocol.encode_collapse(4242)
	assert_eq(bytes[0], Protocol.Msg.COLLAPSE, "tagged as COLLAPSE")
	assert_eq(Protocol.decode_collapse(bytes), 4242, "building id round-trips")
