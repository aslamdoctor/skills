load helper
bats_require_minimum_version 1.5.0

board() { "$S/board.sh"; }

@test "app_state_from_hc" {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9"},"tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21","kind":"claude","gate":"spec","gate_text":"ready | two","pr":"u1"},"102":{"id":"102","agent":"smith-102","hc":"t22","kind":"agy","gate":"","gate_text":"","pr":""}}}'
	stub_reply hc get.t21 '{"state":"live","status":{"app":"claude-code","state":"blocked"}}'
	stub_reply hc get.t22 '{"state":"finished"}'
	run board
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "| Task | Worker | Kind | Gate | Status | PR |" ]
	[ "${lines[2]}" = "| #101 | 😎 SMITH-101 (blocked) | claude | spec | ready / two | u1 |" ]
	[ "${lines[3]}" = "| #102 | 😎 SMITH-102 (gone) | agy |  |  |  |" ]
	[ -z "$(stub_calls herdr)" ]
}

@test "tui_board_unchanged" {
	write_run '{"tasks":{"101":{"id":"101","agent":"smith-101","kind":"claude","gate":"spec","gate_text":"ready | two","pr":"u1"},"102":{"id":"102","agent":"smith-102","kind":"custom","pane":"p2","gate":"pr","gate_text":"x","pr":""}}}'
	stub_reply herdr agent.get.smith-101 '{"result":{"agent":{"agent_status":"working"}}}'
	run board
	[ "$status" -eq 0 ]
	[ "$output" = "| Task | Worker | Kind | Gate | Status | PR |
|---|---|---|---|---|---|
| #101 | 😎 SMITH-101 (working) | claude | ready / two | u1 |  |
| #102 | 😎 SMITH-102 (alive) | custom | pr | x |  |" ]
	[ -z "$(stub_calls hc)" ]
}
