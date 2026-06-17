extends TestCase

# Mirrors server scoring: a kill credits the killer (kills+1, score+KILL_SCORE) and debits the
# victim (deaths+1). KILL_SCORE matches the server constant.
const KILL_SCORE := 100

func _on_kill(clients: Dictionary, killer_id: int, victim_id: int) -> void:
	if clients.has(killer_id) and killer_id != victim_id:
		clients[killer_id]["kills"] += 1
		clients[killer_id]["score"] += KILL_SCORE
	if clients.has(victim_id):
		clients[victim_id]["deaths"] += 1

func test_kill_credits_killer_and_debits_victim() -> void:
	var clients := {
		7: {"kills": 0, "deaths": 0, "score": 0},
		9: {"kills": 0, "deaths": 0, "score": 0},
	}
	_on_kill(clients, 7, 9)
	assert_eq(clients[7]["kills"], 1)
	assert_eq(clients[7]["score"], 100)
	assert_eq(clients[9]["deaths"], 1)

func test_suicide_does_not_credit_kills() -> void:
	var clients := {7: {"kills": 0, "deaths": 0, "score": 0}}
	_on_kill(clients, 7, 7)
	assert_eq(clients[7]["kills"], 0, "self-kill is not a kill credit")
	assert_eq(clients[7]["deaths"], 1)
