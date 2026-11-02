load helper
bats_require_minimum_version 1.5.0

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN/gates" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts/app"
	write_run '{"backend":"herdr-app","space":"sp5","board_tab":"tb5","tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21","tab":"tb21","worktree":"/wt/101"},"102":{"id":"102","agent":"smith-102","hc":"t22","tab":"tb22","worktree":"/wt/102"}}}'
	# User terminals t7/t8 live in sp1; the run's tabs live in sp5.
	stub_reply herdr-app ls '{"spaces":[{"id":"sp1","name":"mine","tabs":[{"id":"tb1","name":"x","terminals":[{"terminal":"t7"},{"terminal":"t8"}]}]},{"id":"sp5","name":"smith","tabs":[{"id":"tb5","name":"Board","terminals":[]},{"id":"tb21","name":"Smith-101","terminals":[{"terminal":"t21"}]},{"id":"tb22","name":"Smith-102","terminals":[{"terminal":"t22"}]}]}]}'
}

cls() { "$S/close.sh" "$@"; }

@test "close_touches_only_run_terminals" {
	run cls 101 102
	[ "$status" -eq 0 ]
	[ "$(stub_calls hc | rg '^kill ' | sort | tr '\n' '|')" = "kill t21 |kill t22 |" ]
	[ "$(stub_calls hc | rg '^rm ' | sort | tr '\n' '|')" = "rm t21 |rm t22 |" ]
	[ -z "$(stub_calls hc | rg -w 't7|t8' || true)" ]
	[ -z "$(stub_calls herdr-app | rg -w 'sp1|tb1|space.close|quit' || true)" ]
	[ -n "$(stub_calls herdr-app | rg 'tab.close --id tb21 --confirmed true')" ]
	[ -n "$(stub_calls herdr-app | rg 'tab.close --id tb22 --confirmed true')" ]
	[ "$(jq -r '.tasks["101"].closed' "$RUN/run.json")" = true ]
}

@test "close_all_closes_space_last" {
	run cls --all
	[ "$status" -eq 0 ]
	mapfile -t calls < <(stub_calls herdr-app | rg '(tab|space)\.close')
	[ "${#calls[@]}" -eq 4 ]
	[[ ${calls[2]} == *"tab.close --id tb5 "* ]]
	[[ ${calls[3]} == *"space.close --id sp5 "* ]]
	[ -z "$(stub_calls herdr-app | rg -w 'sp1|tb1' || true)" ]
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
	[ -z "$(stub_calls herdr-app | rg -w 'space.close|tb5|sp5' || true)" ]
}
