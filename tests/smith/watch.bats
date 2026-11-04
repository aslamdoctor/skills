load helper
bats_require_minimum_version 1.5.0

# Each test starts the watcher in the background (macOS has no `timeout`) and stops it itself.
setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN/gates" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts"
	export SMITH_TICK=1 SMITH_GRACE_SEC=2 STUB_EVENTS_SLEEP=3731
	OUT=$BATS_TEST_TMPDIR/out
	NOW=$(perl -MTime::HiRes=time -e 'printf "%d", time() * 1000')
	FUTURE=$((NOW + 600000))
	OLD=1000
	base_run '"gate_sent":true'
}

teardown() {
	[ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
	wait 2>/dev/null
	return 0
}

# base_run <extra task fields as json members>
base_run() {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9","kind":"claude-code","space":"sp1"},"tasks":{"101":{"id":"101","agent":"code-101","hc":"t21",'"$1"'}}}'
}

# hc_get <state> <status_ms> <turn> [parent]
hc_get() {
	stub_reply hc get.t21 "{\"state\":\"live\",\"status\":{\"app\":\"claude-code\",\"state\":\"$1\"},\"status_ms\":$2,\"turn\":$3,\"parent\":\"${4:-t9}\"}"
}

# start_watch <args...>: background, output in $OUT
start_watch() {
	"$S/app/watch.sh" "$@" >"$OUT" 2>&1 &
	WPID=$!
}

# stop_watch: let it run <secs> (default 4) unless it exits on its own, then stop it
stop_watch() {
	local i
	for i in $(seq $(( ${1:-4} * 5 ))); do
		kill -0 "$WPID" 2>/dev/null || break
		sleep 0.2
	done
	kill "$WPID" 2>/dev/null || true
	wait "$WPID" 2>/dev/null || true
	WPID=
	return 0
}

@test "reports_dropped_gate_once" {
	base_run '"gate_sent":false,"gate_lines":0'
	echo "GATE spec | Spec ready | docs/spec.md" >"$RUN/gates/101.md"
	hc_get working "$NOW" 1
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] GATE code-101 (working): GATE spec | Spec ready | docs/spec.md. RUN=$RUN" ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = true ]
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "fresh_spawn_gate_sent_true_is_quiet" {
	hc_get working "$NOW" 0
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "ignores_boot_idle" {
	hc_get idle "$OLD" 0
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "blocked_flash_not_reported" {
	# future-dated status_ms: never 5 s old while the test runs
	hc_get blocked "$FUTURE" 1 t5
	start_watch
	stop_watch 3
	[ ! -s "$OUT" ]
}

@test "blocked_child_left_to_hc" {
	hc_get blocked "$OLD" 1 t9
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "blocked_adopted_reported" {
	hc_get blocked "$OLD" 1 t5
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] BLOCKED code-101 (blocked): no gate line yet. RUN=$RUN" ]
	[ "$(jq -r '.tasks["101"].reported.blocked' "$RUN/run.json")" = "$OLD" ]
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "gone_adopted_reported_child_not" {
	stub_reply hc get.t21 '{"state":"finished","parent":"t5","status_ms":0,"turn":2}'
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] GONE code-101 (gone): no gate line yet. RUN=$RUN" ]
	[ "$(jq -r '.tasks["101"].reported.gone' "$RUN/run.json")" = true ]
	# a child worker's exit is hc's to report, and nothing else is live
	stub_reply hc get.t21 '{"state":"finished","parent":"t9","status_ms":0,"turn":2}'
	base_run '"gate_sent":true'
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "no live workers" ]
}

@test "stopped_after_grace" {
	echo "GATE spec | Spec ready | s.md" >"$RUN/gates/101.md"
	base_run '"gate_sent":true,"gate_lines":1'
	hc_get idle "$OLD" 3
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] STOPPED code-101 (idle): GATE spec | Spec ready | s.md. RUN=$RUN" ]
	[ "$(jq -r '.tasks["101"].reported.stopped' "$RUN/run.json")" = "$OLD" ]
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "stopped_without_any_gate_line" {
	hc_get done "$OLD" 3
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] STOPPED code-101 (done): no gate line yet. RUN=$RUN" ]
}

@test "no_stopped_after_new_gate" {
	printf 'GATE spec | a | b\nGATE implemented | c | d\n' >"$RUN/gates/101.md"
	base_run '"gate_sent":true,"gate_lines":1'
	hc_get idle "$OLD" 3
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "stopped_waits_for_grace" {
	hc_get idle "$FUTURE" 3
	start_watch
	stop_watch 1
	[ ! -s "$OUT" ]
}

@test "notify_uses_hc_send" {
	hc_get idle "$OLD" 3
	start_watch --notify
	for _ in $(seq 25); do
		[ -n "$(stub_calls hc | rg '^send ' || true)" ] && break
		sleep 0.2
	done
	# --notify keeps running after a report
	kill -0 "$WPID"
	stop_watch 1
	[ "$(stub_calls hc | rg -c '^send ')" -eq 1 ]
	line=$(stub_calls hc | rg '^send ')
	eval "set -- $line"
	[ "$1" = send ]
	[ "$2" = t9 ]
	[ "$3" = "[smith] STOPPED code-101 (idle): no gate line yet. RUN=$RUN" ]
	[ "$#" -eq 3 ]
	[ "$(jq -r '.tasks["101"].reported.stopped' "$RUN/run.json")" = "$OLD" ]
	[ ! -s "$OUT" ]
}

@test "notify_refused_send_retries_then_drops" {
	export SMITH_NOTIFY_RETRY=1 SMITH_NOTIFY_CAP=3
	stub_reply hc send '{}' 1
	hc_get idle "$OLD" 3
	start_watch --notify
	stop_watch 6
	[ "$(stub_calls hc | rg -c '^send ')" -ge 2 ]
	[ "$(stub_calls hc | rg -c '^send ')" -le 5 ]
	# dropped after the cap, so it is not retried forever
	[ "$(jq -r '.tasks["101"].reported.stopped' "$RUN/run.json")" = "$OLD" ]
	[ -z "$(pgrep -f 'sleep 3731' || true)" ]
}

@test "notify_sends_dropped_gate" {
	export SMITH_NOTIFY_RETRY=1 SMITH_NOTIFY_CAP=3
	base_run '"gate_sent":false,"gate_lines":0'
	hc_get working "$NOW" 1
	start_watch --notify
	stop_watch 2
	[ "$(stub_calls hc | rg -c '^send t9 .*GATE.*code-101')" -ge 1 ]
	[ "$(jq -r '.tasks["101"].gate_sent' "$RUN/run.json")" = true ]
}

@test "skips_closed_tasks" {
	base_run '"gate_sent":false,"closed":true'
	hc_get idle "$OLD" 3
	start_watch
	stop_watch 3
	[ "$(cat "$OUT")" = "no live workers" ]
	[ -z "$(stub_calls hc | rg '^get ' || true)" ]
}

@test "events_line_triggers_check_without_waiting_for_tick" {
	export SMITH_TICK=30
	hc_get working "$NOW" 1
	# the stub prints the event line 2 s after the stream opens
	echo 2 >"$STUB_DIR/hc.events.delay"
	echo '{"method":"event","params":{"terminal":"t21","type":"status","data":{}}}' >"$STUB_DIR/hc.events.jsonl"
	start_watch
	sleep 1
	hc_get idle "$OLD" 3
	# only the event can wake it before the 30 s tick
	stop_watch 5
	[[ $(cat "$OUT") == "[smith] STOPPED code-101"* ]]
}

@test "stream_label_and_json_flags" {
	hc_get working "$NOW" 1
	start_watch
	stop_watch 2
	stub_calls hc | rg -q "^events --label smith.run=run --json"
}

@test "dead_event_stream_keeps_ticking" {
	# the stub's events stream exits at once; the watcher keeps ticking and reopens it
	export STUB_EVENTS_SLEEP=0
	hc_get working "$NOW" 1
	start_watch
	sleep 2
	hc_get idle "$OLD" 3
	stop_watch 6
	[[ $(cat "$OUT") == "[smith] STOPPED code-101"* ]]
	[ "$(stub_calls hc | rg -c '^events ')" -ge 2 ]
}

@test "stream_that_prints_then_exits_reopens_once_per_tick" {
	# a stream that writes one line and exits must not be reopened in a hot loop
	export STUB_EVENTS_SLEEP=0 SMITH_TICK=2
	hc_get working "$NOW" 1
	echo '{"error":"core down"}' >"$STUB_DIR/hc.events.jsonl"
	start_watch
	stop_watch 5
	n=$(stub_calls hc | rg -c '^events ')
	[ "$n" -le 5 ]
}

@test "capture_returns_when_watcher_exits" {
	# the ticker's sleep must not hold the caller's stdout or stderr open after exit
	export SMITH_TICK=20
	hc_get working "$NOW" 1
	# the task is closed after 1 s and an event line at 2 s triggers the pass that exits
	echo 2 >"$STUB_DIR/hc.events.delay"
	echo '{"method":"event","params":{"terminal":"t21","type":"status","data":{}}}' >"$STUB_DIR/hc.events.jsonl"
	( sleep 1; jq '.tasks["101"].closed = true' "$RUN/run.json" >"$RUN/r.tmp" && mv "$RUN/r.tmp" "$RUN/run.json" ) &
	start=$(date +%s)
	out=$("$S/app/watch.sh" 2>&1)
	[ $(( $(date +%s) - start )) -lt 10 ]
	[ "$out" = "no live workers" ]
}

@test "sigkill_leaves_no_ticker" {
	# the ticker notices its parent is gone within a tick; hc events dies on its next write (SIGPIPE)
	hc_get working "$NOW" 1
	start_watch
	sleep 1.5
	kill -9 "$WPID"
	wait "$WPID" 2>/dev/null || true
	sleep 2.5
	left=$(pgrep -f "$S/app/watch.sh" || true)
	pkill -f 'sleep 3731' || true
	[ -z "$left" ]
}

@test "failed_hc_get_is_unknown_not_gone" {
	stub_reply hc get.t21 'boom' 1
	start_watch
	stop_watch 3
	[ ! -s "$OUT" ]
}

@test "removed_terminal_is_gone" {
	stub_reply hc get.t21 '{"error":{"kind":"not_found","message":"no terminal"}}' 3
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] GONE code-101 (gone): no gate line yet. RUN=$RUN" ]
}

@test "missing_run_json_exits_1" {
	rm "$RUN/run.json"
	run --separate-stderr "$S/app/watch.sh"
	[ "$status" -eq 1 ]
	[[ $stderr == *"run.json"* ]]
}

@test "two_pending_tasks_both_reported_once" {
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9"},"tasks":{"101":{"id":"101","hc":"t21","gate_sent":false},"102":{"id":"102","hc":"t22","gate_sent":false}}}'
	hc_get working "$NOW" 1
	stub_reply hc get.t22 "{\"state\":\"live\",\"status\":{\"state\":\"working\"},\"status_ms\":$NOW,\"turn\":1,\"parent\":\"t9\"}"
	start_watch
	stop_watch
	[ "$(rg -c '^\[smith\] GATE code-10[12] ' "$OUT")" -eq 2 ]
	jq -e '.tasks["101"].gate_sent and .tasks["102"].gate_sent' "$RUN/run.json" >/dev/null
	start_watch
	stop_watch 3
	[ ! -s "$OUT" ]
}

@test "notify_refused_send_does_not_block_other_tasks" {
	export SMITH_NOTIFY_RETRY=1
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9"},"tasks":{"101":{"id":"101","hc":"t21","gate_sent":true},"102":{"id":"102","hc":"t22","gate_sent":true}}}'
	hc_get idle "$OLD" 3
	stub_reply hc get.t22 '{"state":"live","status":{"state":"idle"},"status_ms":1000,"turn":3,"parent":"t9"}'
	# send 1 (task 101) is refused, then everything is accepted
	echo '{}' >"$STUB_DIR/hc.send.t9.1.json"; echo 1 >"$STUB_DIR/hc.send.t9.1.exit"
	echo '{}' >"$STUB_DIR/hc.send.t9.2.json"
	echo '{}' >"$STUB_DIR/hc.send.t9.3.json"
	start_watch --notify
	for _ in $(seq 40); do
		[ "$(jq -r '.tasks["102"].reported.stopped // empty' "$RUN/run.json")" = "$OLD" ] && break
		sleep 0.1
	done
	# task 102 went out right after the refusal, before 101's retry could have succeeded
	[ "$(jq -r '.tasks["102"].reported.stopped' "$RUN/run.json")" = "$OLD" ]
	for _ in $(seq 40); do
		[ "$(jq -r '.tasks["101"].reported.stopped // empty' "$RUN/run.json")" = "$OLD" ] && break
		sleep 0.1
	done
	stop_watch 1
	[ "$(jq -r '.tasks["101"].reported.stopped' "$RUN/run.json")" = "$OLD" ]
	sends=$(stub_calls hc | rg '^send ')
	[ "$(wc -l <<<"$sends" | tr -d ' ')" -eq 3 ]
	[[ $(awk "NR==1" <<<"$sends") == *code-101* ]]
	[[ $(awk "NR==2" <<<"$sends") == *code-102* ]]
	[[ $(awk "NR==3" <<<"$sends") == *code-101* ]]
}

@test "stop_leaves_no_processes" {
	hc_get working "$NOW" 1
	start_watch
	sleep 2
	[ -n "$(pgrep -f 'sleep 3731' || true)" ]
	stop_watch 0
	sleep 0.5
	[ -z "$(pgrep -f 'sleep 3731' || true)" ]
	[ -z "$(pgrep -f "$S/app/watch.sh" || true)" ]
}

@test "runs_on_bash_3_2_without_reopening_stream" {
	hc_get working "$NOW" 1
	/bin/bash "$S/app/watch.sh" >"$OUT" 2>&1 &
	WPID=$!
	sleep 4
	[ "$(stub_calls hc | rg -c '^events ')" -eq 1 ]
	stop_watch 0
	[ -z "$(pgrep -f 'sleep 3731' || true)" ]
}
