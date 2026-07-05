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

func test_poll_survives_host_teardown_inside_disconnect_handler() -> void:
	# Regression (round-4 playtest crash): a peer_disconnected handler that tears the host down
	# (client_main._on_disconnected -> _teardown_net -> close() nulls _host) used to crash poll()'s
	# drain loop — it re-entered _host.service() on the now-null host after emitting the event.
	# poll() must re-check _host every iteration, not just once on entry.
	var server := NetHost.new()
	autofree(server)
	assert_eq(server.start_server(PORT + 1, 4), OK)
	var client := NetHost.new()
	autofree(client)
	var peer := client.start_client("127.0.0.1", PORT + 1)
	assert_true(peer != null)
	for i in range(200):
		server.poll(); client.poll()
		if server.peers().size() == 1: break
		OS.delay_msec(5)
	assert_eq(server.peers().size(), 1)
	var fired := [false]
	# Null the host synchronously inside the signal, exactly like the in-game disconnect path does.
	client.peer_disconnected.connect(func(_p):
		fired[0] = true
		client.close())
	server.disconnect_all()
	# With the bug, this client.poll() aborts with "Cannot call method 'service' on a null value".
	for i in range(200):
		server.poll(); client.poll()
		if fired[0]: break
		OS.delay_msec(5)
	assert_true(fired[0], "disconnect handler tore the host down without crashing poll()")
