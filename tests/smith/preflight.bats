load helper

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts"
	export HOME=$BATS_TEST_TMPDIR/home
	mkdir -p "$HOME"
	export HC_TERMINAL_ID=t9
	REPO=$BATS_TEST_TMPDIR/repo
	git init -q "$REPO"
	cd "$REPO"
	REPO=$(pwd -P)
	stub_reply hc get.t9 '{"status":{"app":"claude-code","state":"working"},"labels":{"herdr.space":"sp1"}}'
	stub_reply herdr-app ls '{"spaces":[{"id":"sp1","name":"main","tabs":[]}]}'
	stub_reply herdr-app do.space.new '{"space":"sp2","tab":"tb2","terminal":"t30"}'
	stub_reply herdr-app do.tab.new '{"space":"sp2","tab":"tb3","terminal":"t31"}'
}

pre() { "$S/app/preflight.sh" "$@"; }

@test "fails_without_hc_terminal" {
	unset HC_TERMINAL_ID
	run pre
	[ "$status" -eq 1 ]
	echo "$output" | jq -e '.error' >/dev/null
}

@test "fails_when_server_down" {
	stub_reply hc server.status '{}' 1
	run pre
	[ "$status" -eq 1 ]
	echo "$output" | jq -e '.error' >/dev/null
}

@test "records_backend_and_orchestrator" {
	run pre
	[ "$status" -eq 0 ]
	[ "$(jq -r .backend "$RUN/run.json")" = herdr-app ]
	[ "$(jq -r .orchestrator.address "$RUN/run.json")" = t9 ]
	[ "$(jq -r .orchestrator.kind "$RUN/run.json")" = claude-code ]
	[ "$(jq -r .orchestrator.space "$RUN/run.json")" = sp1 ]
	[ "$(jq -r .space "$RUN/run.json")" = sp2 ]
	[ "$(jq -r .board_tab "$RUN/run.json")" = tb3 ]
	echo "$output" | jq -e '.backend == "herdr-app" and (has("tasks") | not)' >/dev/null
	[ "$(readlink "$HOME/.config/herdr-app/mods/smith-board")" = "$REPO_ROOT/skills/smith/app/smith-board" ]
}

@test "creates_space_board_and_selects_back" {
	run pre
	[ "$status" -eq 0 ]
	calls=$(stub_calls herdr-app)
	n_new=$(echo "$calls" | rg -n 'do space.new' | head -1 | cut -d: -f1)
	n_tab=$(echo "$calls" | rg -n 'do tab.new.*--mod smith-board' | head -1 | cut -d: -f1)
	n_close=$(echo "$calls" | rg -n 'do tab.close' | head -1 | cut -d: -f1)
	n_sel=$(echo "$calls" | rg -n 'do space.select --id sp1' | head -1 | cut -d: -f1)
	[ -n "$n_new" ] && [ "$n_new" -lt "$n_tab" ] && [ "$n_tab" -lt "$n_close" ] && [ "$n_close" -lt "$n_sel" ]
	echo "$calls" | rg -q 'tab.close --id tb2 --confirmed true'
	echo "$calls" | rg -q "$RUN"
	echo "$calls" | rg -q -- "--folder $REPO"
}

@test "reuses_existing_space" {
	write_run '{"space":"sp5","board_tab":"tb5","tasks":{}}'
	stub_reply herdr-app ls '{"spaces":[{"id":"sp5","name":"x","tabs":[{"id":"tb5","name":"Board"}]}]}'
	run pre
	[ "$status" -eq 0 ]
	! stub_calls herdr-app | rg -q 'space.new|tab.new'
	[ "$(jq -r .space "$RUN/run.json")" = sp5 ]
}

@test "recreates_missing_board_tab_only" {
	write_run '{"space":"sp5","board_tab":"tb5","tasks":{}}'
	stub_reply herdr-app ls '{"spaces":[{"id":"sp5","name":"x","tabs":[{"id":"tb9","name":"Smith-1"}]}]}'
	run pre
	[ "$status" -eq 0 ]
	calls=$(stub_calls herdr-app)
	! echo "$calls" | rg -q 'space.new|tab.close'
	echo "$calls" | rg -q 'do tab.new --space sp5'
	[ "$(jq -r .board_tab "$RUN/run.json")" = tb3 ]
}

@test "resume_updates_orchestrator" {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t5","kind":"codex","space":"sp0"},"space":"sp5","board_tab":"tb5","tasks":{}}'
	stub_reply herdr-app ls '{"spaces":[{"id":"sp5","name":"x","tabs":[{"id":"tb5","name":"Board"}]}]}'
	run pre --resume
	[ "$status" -eq 0 ]
	[ "$(jq -r .orchestrator.address "$RUN/run.json")" = t9 ]
	[ "$(jq -r .orchestrator.kind "$RUN/run.json")" = claude-code ]
}

@test "refuses_foreign_mod_dir" {
	mkdir -p "$HOME/.config/herdr-app/mods/smith-board"
	touch "$HOME/.config/herdr-app/mods/smith-board/keep"
	run pre
	[ "$status" -eq 1 ]
	echo "$output" | jq -e '.error' >/dev/null
	[ -f "$HOME/.config/herdr-app/mods/smith-board/keep" ]
}

@test "tab_new_failure_selects_back_and_errors" {
	stub_reply herdr-app do.tab.new '{"error":"no mod"}' 1
	run pre
	[ "$status" -eq 1 ]
	echo "$output" | jq -e '.error' >/dev/null
	stub_calls herdr-app | rg -q 'do space.select --id sp1'
	[ "$(jq -r .space "$RUN/run.json")" = sp2 ]
}
