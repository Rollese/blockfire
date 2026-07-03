extends TestCase
## M8-P3: NetHost.disconnect_all — server-initiated disconnect of every peer
## (map-rotation boundary). Loopback ENet on an uncommon port.

const PORT := 28471

func test_disconnect_all_disconnects_connected_peer() -> void:
	var server := NetHost.new()
	autofree(server)
	assert_eq(server.start_server(PORT, 4), OK)
	var client := NetHost.new()
	autofree(client)
	var peer := client.start_client("127.0.0.1", PORT)
	assert_true(peer != null)
	# Pump both hosts until the server sees the peer (bounded).
	for i in range(200):
		server.poll(); client.poll()
		if server.peers().size() == 1: break
		OS.delay_msec(5)
	assert_eq(server.peers().size(), 1)
	var got := [false]
	client.peer_disconnected.connect(func(_p): got[0] = true)
	server.disconnect_all()
	for i in range(200):
		server.poll(); client.poll()
		if got[0]: break
		OS.delay_msec(5)
	assert_true(got[0])

func test_disconnect_all_on_idle_host_is_safe() -> void:
	var host := NetHost.new()
	autofree(host)
	host.disconnect_all()   # no _host yet — must not error
	assert_true(true)
