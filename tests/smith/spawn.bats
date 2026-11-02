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
	export WT_ROOT=$BATS_TEST_TMPDIR/wt
	export SPAWN_WAIT=2 SPAWN_INTERVAL=1
	unset AGENT_KIND
	git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
	REPO=$BATS_TEST_TMPDIR/repo
	git init -q -b main "$REPO"
	cd "$REPO"
	git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
	git remote add origin "$BATS_TEST_TMPDIR/origin.git"
	git push -q origin main
	write_run '{"backend":"herdr-app","space":"sp2","orchestrator":{"address":"t9","kind":"claude-code","space":"sp1"},"tasks":{}}'
	stub_reply hc run '{"address":"t21","name":"smith-101","parent":"t9","state":"live","turn":0}'
	stub_reply hc get.t21 '{"state":"live","status":{"app":"claude-code","state":"working"},"turn":1,"status_ms":5}'
	stub_reply herdr-app ls '{"spaces":[{"id":"sp2","name":"smith","tabs":[{"id":"tb7","name":"x","terminals":[{"terminal":"t21"}]},{"id":"tb8","name":"y","terminals":[{"terminal":"t30"}]}]}]}'
}

sp() { "$S/app/spawn.sh" "$@"; }
hc_run_line() { stub_calls hc | rg '^run ' | head -1; }

@test "kickoff_argv_is_exact" {
	printf 'It'"'"'s "x" $HOME `y`\nsecond line\n' >"$BATS_TEST_TMPDIR/p.txt"
	run sp 101 b101 origin/main <"$BATS_TEST_TMPDIR/p.txt"
	[ "$status" -eq 0 ]
	line=$(hc_run_line)
	eval "set -- $line"
	last="${*: -1}"
	[ "$last" = "$(cat "$BATS_TEST_TMPDIR/p.txt")" ]
	[ "$(printf '%s\n' "$last" | wc -l)" -eq 2 ]
}

@test "claude_gets_session_id" {
	run sp 101 b101 origin/main <<<"hello"
	[ "$status" -eq 0 ]
	uuid=$(jq -r .tasks.\"101\".session "$RUN/run.json")
	[[ "$uuid" =~ ^[0-9a-f-]{36}$ ]]
	hc_run_line | rg -q -- "--session-id $uuid"
}

@test "resume_uses_resume_argv" {
	run sp 101 b101 origin/main --resume abc-123 <<<"go on"
	[ "$status" -eq 0 ]
	line=$(hc_run_line)
	echo "$line" | rg -q -- 'claude --resume abc-123'
	[ -z "$(echo "$line" | rg -- '--session-id' || true)" ]
	[ "$(jq -r .tasks.\"101\".session "$RUN/run.json")" = abc-123 ]
}

@test "agy_resume_uses_conversation_flag" {
	run sp 101 b101 origin/main --kind agy --resume conv-1 <<<"go on"
	[ "$status" -eq 0 ]
	hc_run_line | rg -q -- '-- agy --conversation conv-1 -i '
	[ "$(jq -r .tasks.\"101\".session "$RUN/run.json")" = conv-1 ]
}

@test "resume_without_support_warns_and_starts_fresh" {
	printf 'nores\tnores -i {prompt}\t-\n' >"$BATS_TEST_TMPDIR/launch.tsv"
	LAUNCH_TSV=$BATS_TEST_TMPDIR/launch.tsv run sp 101 b101 origin/main --kind nores --resume zzz <<<"catch up"
	[ "$status" -eq 0 ]
	echo "$output" | rg -q 'catch-up prompt'
	line=$(hc_run_line)
	echo "$line" | rg -q -- '-- nores -i '
	[ -z "$(echo "$line" | rg -- 'zzz' || true)" ]
}

@test "agy_records_conversation_id_from_cache" {
	mkdir -p "$HOME/.gemini/antigravity-cli/cache"
	jq -nc --arg d "$WT_ROOT/b101" '{($d):"conv-9"}' >"$HOME/.gemini/antigravity-cli/cache/last_conversations.json"
	run sp 101 b101 origin/main --kind agy <<<"do it"
	[ "$status" -eq 0 ]
	[ "$(jq -r .tasks.\"101\".session "$RUN/run.json")" = conv-9 ]
}

@test "agy_uses_dash_i" {
	run sp 101 b101 origin/main --kind agy <<<"do it"
	[ "$status" -eq 0 ]
	hc_run_line | rg -q -- '-- agy -i '
}

@test "unknown_kind_warns_and_runs_prompt" {
	run sp 101 b101 origin/main --kind foo <<<"do it"
	[ "$status" -eq 0 ]
	echo "$output" | rg -q 'kind foo is untested on herdr-app'
	hc_run_line | rg -q -- '-- foo '
}

@test "refuses_live_worker" {
	stub_reply hc get.smith-101 '{"state":"live","status":{"state":"idle"}}'
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 3 ]
	echo "$output" | jq -e '.error | test("still live")' >/dev/null
	[ -z "$(stub_calls hc | rg '^run ' || true)" ]
}

@test "labels_and_outlive_parent" {
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 0 ]
	line=$(hc_run_line)
	echo "$line" | rg -q -- '--outlive-parent'
	echo "$line" | rg -q -- '--name smith-101'
	echo "$line" | rg -q -- '--label herdr.space=sp2'
	echo "$line" | rg -q -- '--label herdr.tab=smith-101'
	echo "$line" | rg -q -- '--label smith.run=run'
	echo "$line" | rg -q -- '--label smith.task=101'
	[ -z "$(echo "$line" | rg -- '--force|--dangerously' || true)" ]
}

@test "renames_tab_and_selects_orchestrator_space_back" {
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 0 ]
	calls=$(stub_calls herdr-app)
	echo "$calls" | rg -q 'do tab.rename --id tb7 --name Smith-101'
	n_ren=$(echo "$calls" | rg -n 'tab.rename' | head -1 | cut -d: -f1)
	n_sel=$(echo "$calls" | rg -n 'do space.select --id sp1' | head -1 | cut -d: -f1)
	[ "$n_ren" -lt "$n_sel" ]
}

@test "records_task" {
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 0 ]
	t=$(jq -c '.tasks["101"]' "$RUN/run.json")
	echo "$t" | jq -e '.id == "101" and .agent == "smith-101" and .hc == "t21" and .kind == "claude" and .branch == "b101" and .base == "origin/main" and .space == "sp2" and .tab == "tb7" and .needs_you == false and .gate == "started" and (.updated | length > 0) and (.worktree | endswith("/b101"))' >/dev/null
	[ -d "$WT_ROOT/b101" ]
	echo "$output" | jq -e '.status == "working" and .hc == "t21"' >/dev/null
}

@test "status_not_started_when_idle_turn_zero" {
	stub_reply hc get.t21 '{"state":"live","status":null,"turn":0}'
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.status == "not_started"' >/dev/null
}

@test "status_gone" {
	stub_reply hc get.t21 '{"state":"finished","turn":0}'
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.status == "gone"' >/dev/null
}

@test "status_blocked" {
	stub_reply hc get.t21 '{"state":"live","status":{"state":"blocked"},"turn":0}'
	run sp 101 b101 origin/main <<<"x"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.status == "blocked"' >/dev/null
}

@test "empty_stdin_drops_prompt_word" {
	run sp 101 b101 origin/main --resume s1 </dev/null
	[ "$status" -eq 0 ]
	hc_run_line | rg -q -- 'claude --resume s1 *$'
}
