load helper

d() { "$S/done.sh" "$@"; }

@test "all_at_last_gate_is_done" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","type":"code","agent":"code-101","hc":"t21","gate":"pr"},"5737":{"id":"5737","type":"review","agent":"review-5737","hc":"t22","gate":"posted"}}}'
	run d
	[ "$status" -eq 0 ]
	[ "$output" = "all 2 workers done" ]
}

@test "busy_worker_is_listed" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","type":"code","agent":"code-101","hc":"t21","gate":"pr"},"102":{"id":"102","type":"code","agent":"code-102","hc":"t22","gate":"spec"},"5737":{"id":"5737","type":"review","agent":"review-5737","hc":"t23","gate":"pr"}}}'
	stub_reply hc get.t22 '{"state":"live","status":{"state":"working"}}'
	stub_reply hc get.t23 '{"state":"live","status":{"state":"idle"}}'
	run d
	[ "$status" -eq 1 ]
	[ "$output" = "still working: code-102 (spec), review-5737 (pr)" ]
}

@test "gone_worker_counts_as_done" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","agent":"code-101","hc":"t21","gate":"implemented"}}}'
	stub_reply hc get.t21 '{"state":"finished"}'
	run d
	[ "$status" -eq 0 ]
}

@test "closed_tasks_are_ignored" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","agent":"code-101","hc":"t21","gate":"spec","closed":true},"102":{"id":"102","agent":"code-102","hc":"t22","gate":"pr"}}}'
	stub_reply hc get.t21 '{"state":"live","status":{"state":"working"}}'
	run d
	[ "$status" -eq 0 ]
	[ "$output" = "all 1 workers done" ]
}

@test "no_open_tasks_is_nothing_to_offer" {
	write_run '{"tasks":{"101":{"id":"101","agent":"code-101","gate":"pr","closed":true}}}'
	run d --ask
	[ "$status" -eq 3 ]
	[ "$output" = "no open workers" ]
}

@test "ask_offers_once" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","agent":"code-101","hc":"t21","gate":"pr"}}}'
	run d --ask
	[ "$status" -eq 0 ]
	[ "$(jq -r .cleanup_offered "$RUN/run.json")" = true ]
	run d --ask
	[ "$status" -eq 3 ]
	run d
	[ "$status" -eq 0 ]
}

@test "herdr_tui_uses_agent_state" {
	write_run '{"tasks":{"101":{"id":"101","agent":"code-101","pane":"p1","gate":"implemented"}}}'
	stub_reply herdr agent.get.code-101 '{"result":{"agent":{"agent_status":"idle"}}}'
	run d
	[ "$status" -eq 1 ]
	[ "$output" = "still working: code-101 (implemented)" ]
}

@test "send_resets_the_offer" {
	write_run '{"cleanup_offered":true,"tasks":{"101":{"id":"101","agent":"code-101","pane":"p1","gate":"pr"}}}'
	export HERDR_ENV=1
	stub_reply herdr agent.prompt '{"result":{"type":"agent_prompted"}}'
	stub_reply herdr agent.get.code-101 '{"result":{"agent":{"agent_status":"working"}}}'
	run "$S/send.sh" 101 <<<"follow up"
	[ "$(jq -r '.cleanup_offered // "unset"' "$RUN/run.json")" = unset ]
}
