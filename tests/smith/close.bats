load helper
bats_require_minimum_version 1.5.0

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN/gates" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts/app"
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t7","space":"sp1","tab":"tb1"},"tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21","tab":"tb21","worktree":"/wt/101"},"102":{"id":"102","agent":"smith-102","hc":"t22","tab":"tb22","worktree":"/wt/102"}}}'
	# The user's terminals t7/t8 and the run's worker tabs share space sp1.
	stub_reply herdr-app ls '{"spaces":[{"id":"sp1","name":"mine","tabs":[{"id":"tb1","name":"x","terminals":[{"terminal":"t7"},{"terminal":"t8"}]},{"id":"tb21","name":"🤓 smith-101","terminals":[{"terminal":"t21"}]},{"id":"tb22","name":"🤓 smith-102","terminals":[{"terminal":"t22"}]}]}]}'
}

cls() { "$S/close.sh" "$@"; }

@test "close_touches_only_run_terminals" {
	run cls 101 102
	[ "$status" -eq 0 ]
	[ "$(stub_calls hc | rg '^kill ' | sort | tr '\n' '|')" = "kill t21 |kill t22 |" ]
	[ "$(stub_calls hc | rg '^rm ' | sort | tr '\n' '|')" = "rm t21 |rm t22 |" ]
	[ -z "$(stub_calls hc | rg -w 't7|t8' || true)" ]
	[ -z "$(stub_calls herdr-app | rg -w 'tb1|space.close|quit' || true)" ]
	[ -n "$(stub_calls herdr-app | rg 'tab.close --id tb21 --confirmed true')" ]
	[ -n "$(stub_calls herdr-app | rg 'tab.close --id tb22 --confirmed true')" ]
	[ "$(jq -r '.tasks["101"].closed' "$RUN/run.json")" = true ]
}

@test "close_all_closes_only_worker_tabs" {
	run cls --all
	[ "$status" -eq 0 ]
	[ "$(stub_calls herdr-app | rg 'tab\.close' | rg -o 'tb[0-9]+' | sort | tr '\n' '|')" = "tb21|tb22|" ]
	[ -z "$(stub_calls herdr-app | rg -w 'space.close|sp1|tb1' || true)" ]
	[ -z "$(stub_calls hc | rg -w 't7|t8' || true)" ]
}

@test "keeps_worktree_and_run_json" {
	run cls --all
	[ -f "$RUN/run.json" ]
	[ "$(jq -r '.tasks["101"].worktree' "$RUN/run.json")" = /wt/101 ]
	[ "$(jq -r '.tasks["102"].closed' "$RUN/run.json")" = true ]
	[ -z "$(stub_calls hc | rg -e 'server|worktree' || true)" ]
	[ -z "$(stub_calls herdr-app | rg -e 'quit' || true)" ]
}

@test "already_gone_is_fine" {
	stub_reply hc kill.t21 '{"error":"not_found"}' 3
	stub_reply hc rm.t21 '{"error":"not_found"}' 3
	stub_reply herdr-app ls '{"spaces":[{"id":"sp1","name":"mine","tabs":[]}]}'
	run cls 101
	[ "$status" -eq 0 ]
	[ -z "$(stub_calls herdr-app | rg 'close' || true)" ]
	[ "$(jq -r '.tasks["101"].closed' "$RUN/run.json")" = true ]
}

@test "other_failure_warns_and_continues" {
	stub_reply hc kill.t21 '{"error":"boom"}' 1
	run --separate-stderr cls 101 102
	[ "$status" -eq 1 ]
	[[ $stderr == *"101"* ]]
	[ -n "$(stub_calls hc | rg '^kill t22 ')" ]
	[ "$(jq -r '.tasks["101"].closed // false' "$RUN/run.json")" = false ]
	[ "$(jq -r '.tasks["102"].closed' "$RUN/run.json")" = true ]
}

@test "unknown_id_touches_nothing" {
	run --separate-stderr cls 999
	[ "$status" -eq 2 ]
	[[ $stderr == *"999"* ]]
	[ -z "$(stub_calls hc || true)" ]
	[ -z "$(stub_calls herdr-app | rg 'close' || true)" ]
}

@test "all_ignores_ids_not_in_run_json" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","hc":"t21","tab":"tb21"}}}'
	run cls --all
	[ "$status" -eq 0 ]
	[ -z "$(stub_calls herdr-app | rg -w 'space.close|tb22' || true)" ]
}

@test "runs_on_bash_3_2" {
	run /bin/bash "$S/close.sh" --all
	[ "$status" -eq 0 ]
	[ "$(stub_calls hc | rg -c '^kill ')" -eq 2 ]
	[ -n "$(stub_calls herdr-app | rg 'tab.close --id tb22')" ]
}

@test "not_found_with_other_exit_code_is_a_failure" {
	stub_reply hc kill.t21 '{"error":"not_found"}' 1
	run --separate-stderr cls 101
	[ "$status" -eq 1 ]
	[[ $stderr == *"kill t21"* ]]
	[ "$(jq -r '.tasks["101"].closed // false' "$RUN/run.json")" = false ]
}

@test "ls_failure_is_reported" {
	stub_reply herdr-app ls 'not json' 1
	run --separate-stderr cls 101
	[ "$status" -eq 1 ]
	[[ $stderr == *"herdr-app ls"* ]]
	[ "$(jq -r '.tasks["101"].closed // false' "$RUN/run.json")" = false ]
}

@test "ls_non_json_is_reported" {
	stub_reply herdr-app ls 'oops'
	run cls --all
	[ "$status" -eq 1 ]
	[ -z "$(stub_calls herdr-app | rg 'close' || true)" ]
}

@test "close_clears_needs_you" {
	write_run '{"backend":"herdr-app","tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21","tab":"tb21","needs_you":true}}}'
	run cls 101
	[ "$status" -eq 0 ]
	[ "$(jq -r '.tasks["101"].closed' "$RUN/run.json")" = true ]
	[ "$(jq -r '.tasks["101"].needs_you' "$RUN/run.json")" = false ]
}
