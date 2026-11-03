load helper
bats_require_minimum_version 1.5.0

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN/gates" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts"
	write_run '{"backend":"herdr-app","space":"sp2","orchestrator":{"address":"t9","kind":"claude-code","space":"sp1"},"tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21","needs_you":false}}}'
}

mk() { "$S/mark.sh" "$@"; }

@test "app_sends_exact_gate_message" {
	run mk 101 spec "Spec ready" docs/spec.md
	[ "$status" -eq 0 ]
	[ "$output" = "marked 🤓 smith-101: spec" ]
	[ "$(stub_calls hc | rg '^send ' | wc -l | tr -d ' ')" -eq 1 ]
	line=$(stub_calls hc | rg '^send ')
	eval "set -- $line"
	[ "$1" = send ]
	[ "$2" = t9 ]
	[ "$3" = "[smith] GATE spec 🤓 smith-101: Spec ready | docs/spec.md" ]
	[ "$#" -eq 3 ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = true ]
}

@test "app_sets_gate_label" {
	run mk 101 implemented "Done" abc123
	[ "$status" -eq 0 ]
	stub_calls hc | rg -q '^label t21 smith.gate=implemented'
}

@test "app_send_refused_sets_gate_sent_false" {
	stub_reply hc send '{}' 1
	run mk 101 pr "PR open" https://github.com/o/r/pull/5
	[ "$status" -eq 0 ]
	[ "$output" = "marked 🤓 smith-101: pr (orchestrator not reached; the watcher will report it)" ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = false ]
	[ "$(jq -r '.tasks["101"].pr' "$RUN/run.json")" = "https://github.com/o/r/pull/5" ]
}

@test "app_missing_orchestrator_address_is_failed_send" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","hc":"t21"}}}'
	run mk 101 spec "x" ref
	[ "$status" -eq 0 ]
	[[ $output == *"orchestrator not reached"* ]]
	[ -z "$(stub_calls hc | rg '^send ' || true)" ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = false ]
}

@test "app_label_failure_does_not_stop_gate" {
	stub_reply hc label '{}' 1
	run --separate-stderr mk 101 spec "x" ref
	[ "$status" -eq 0 ]
	[[ $stderr == *"hc label failed for 🤓 smith-101; gate still recorded"* ]]
	[ "$(jq -r '.tasks["101"].gate' "$RUN/run.json")" = spec ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = true ]
}

@test "app_sets_needs_you" {
	run mk 101 spec "x" ref
	[ "$(jq -r '.tasks["101"].needs_you' "$RUN/run.json")" = true ]
	stub_reply hc send '{}' 1
	jq '.tasks["101"].needs_you = false' "$RUN/run.json" >"$RUN/t" && mv "$RUN/t" "$RUN/run.json"
	run mk 101 spec "x" ref
	[ "$(jq -r '.tasks["101"].needs_you' "$RUN/run.json")" = true ]
}

@test "app_makes_no_herdr_calls" {
	run mk 101 spec "x" ref
	[ -z "$(stub_calls herdr)" ]
}

@test "tui_run_never_calls_hc" {
	write_run '{"space":"sp2","tasks":{"101":{"id":"101","agent":"smith-101","pane":"p1"}}}'
	run mk 101 spec "x" ref
	[ "$status" -eq 0 ]
	stub_calls herdr | rg -q 'pane report-metadata'
	[ ! -f "$STUB_DIR/hc.log" ]
}

@test "tui_output_unchanged" {
	write_run '{"space":"sp2","tasks":{"101":{"id":"101","agent":"smith-101","pane":"p1"}}}'
	run mk 101 spec "x" ref
	[ "$output" = "marked 🤓 smith-101: spec" ]
}

@test "app_send_watchdog_kills_hung_send" {
	stub_reply hc send '{}'
	echo 47 >"$STUB_DIR/hc.send.sleep"
	start=$SECONDS
	MARK_SEND_TIMEOUT=1 run --separate-stderr mk 101 spec "x" ref
	[ $((SECONDS - start)) -lt 5 ]
	[ "$status" -eq 0 ]
	[ "$output" = "marked 🤓 smith-101: spec (orchestrator not reached; the watcher will report it)" ]
	[ -z "$stderr" ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = false ]
	[ "$(jq -r '.tasks["101"].needs_you' "$RUN/run.json")" = true ]
	[ -z "$(pgrep -f 'sleep 47' || true)" ]
}

@test "app_send_success_leaves_no_process" {
	MARK_SEND_TIMEOUT=53 run mk 101 spec "x" ref
	[ "$status" -eq 0 ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = true ]
	[ -z "$(pgrep -f 'sleep 53' || true)" ]
}
