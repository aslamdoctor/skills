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
	stub_reply hc get.t9 '{"status":{"app":"claude-code","state":"working"},"labels":{"herdr.space":"sp1","herdr.tab":"tb1"}}'
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
	[ "$(jq -r .orchestrator.tab "$RUN/run.json")" = tb1 ]
	echo "$output" | jq -e '.backend == "herdr-app" and (has("tasks") | not)' >/dev/null
}

@test "creates_no_space_tab_or_mod" {
	run pre
	[ "$status" -eq 0 ]
	[ -z "$(stub_calls herdr-app || true)" ]
	[ ! -e "$HOME/.config/herdr-app/mods" ]
}

@test "fails_without_space_label" {
	stub_reply hc get.t9 '{"status":{"app":"claude-code"},"labels":{}}'
	run pre
	[ "$status" -eq 1 ]
	echo "$output" | jq -e '.error | test("herdr.space")' >/dev/null
}

@test "same_terminal_refreshes_old_record" {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9","kind":"claude-code","space":"sp0"},"tasks":{}}'
	run pre
	[ "$status" -eq 0 ]
	[ "$(jq -r .orchestrator.space "$RUN/run.json")" = sp1 ]
	[ "$(jq -r .orchestrator.tab "$RUN/run.json")" = tb1 ]
}

@test "other_terminal_kept_without_resume" {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t5","kind":"codex","space":"sp0"},"tasks":{}}'
	run pre
	[ "$status" -eq 0 ]
	[ "$(jq -r .orchestrator.address "$RUN/run.json")" = t5 ]
}

@test "resume_updates_orchestrator" {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t5","kind":"codex","space":"sp0"},"tasks":{}}'
	run pre --resume
	[ "$status" -eq 0 ]
	[ "$(jq -r .orchestrator.address "$RUN/run.json")" = t9 ]
	[ "$(jq -r .orchestrator.kind "$RUN/run.json")" = claude-code ]
	[ "$(jq -r .orchestrator.tab "$RUN/run.json")" = tb1 ]
}
