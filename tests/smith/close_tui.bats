load helper
bats_require_minimum_version 1.5.0

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN/gates" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts"
	write_run '{"tasks":{"101":{"id":"101","agent":"code-101","tab":"w1:t2","pane":"p2","worktree":"/wt/101"},"102":{"id":"102","agent":"code-102","tab":"w1:t3","pane":"p3","worktree":"/wt/102"},"103":{"id":"103","agent":"code-103","tab":"w1:t4","closed":true}}}'
}

cls() { "$S/close.sh" "$@"; }

@test "all_closes_open_worker_tabs_only" {
	run cls --all
	[ "$status" -eq 0 ]
	[ "$output" = "closed 2 of 2 workers" ]
	[ "$(stub_calls herdr | rg '^tab close' | sort | tr '\n' '|')" = "tab close w1:t2 |tab close w1:t3 |" ]
	[ -z "$(stub_calls herdr | rg -e 'server|w1:t4|workspace' || true)" ]
	[ "$(jq -r '.tasks["101"].closed' "$RUN/run.json")" = true ]
	[ "$(jq -r '.tasks["102"].worktree' "$RUN/run.json")" = /wt/102 ]
}

@test "missing_tab_still_marks_closed" {
	stub_reply herdr tab.get '{"error":"not found"}' 1
	run cls 101
	[ "$status" -eq 0 ]
	[ -z "$(stub_calls herdr | rg '^tab close' || true)" ]
	[ "$(jq -r '.tasks["101"].closed' "$RUN/run.json")" = true ]
}

@test "close_failure_warns_and_continues" {
	stub_reply herdr tab.close '{"error":"boom"}' 1
	run --separate-stderr cls 101 102
	[ "$status" -eq 1 ]
	[[ $stderr == *"herdr tab close w1:t2 (task 101) failed"* ]]
	[ "$(jq -r '.tasks["102"].closed // false' "$RUN/run.json")" = false ]
	[ "$(stub_calls herdr | rg -c '^tab close')" -eq 2 ]
}

@test "unknown_id_touches_nothing" {
	run cls 101 999
	[ "$status" -eq 2 ]
	[ -z "$(stub_calls herdr)" ]
}

@test "usage_without_ids" {
	run cls
	[ "$status" -eq 2 ]
}

@test "stops_recorded_watcher_only" {
	# A stand-in watcher whose command line contains watch.sh, plus an unrelated process.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' >"$BATS_TEST_TMPDIR/bin/watch.sh"
	chmod +x "$BATS_TEST_TMPDIR/bin/watch.sh"
	bash "$BATS_TEST_TMPDIR/bin/watch.sh" 101 </dev/null >/dev/null 2>&1 3>&- &
	w=$!
	sleep 30 </dev/null >/dev/null 2>&1 3>&- &
	other=$!
	sleep 0.3
	echo "$w" >"$RUN/watch-101.pid"
	echo "$other" >"$RUN/watch-102.pid"
	run cls --all
	[ "$status" -eq 0 ]
	sleep 0.3
	alive_w=0; kill -0 "$w" 2>/dev/null && alive_w=1
	alive_o=0; kill -0 "$other" 2>/dev/null && alive_o=1
	kill "$w" "$other" 2>/dev/null || true
	[ "$alive_w" -eq 0 ]
	[ "$alive_o" -eq 1 ]
	[ ! -f "$RUN/watch-101.pid" ] && [ ! -f "$RUN/watch-102.pid" ]
}
