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
	NOW=$(( $(date +%s) * 1000 ))
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
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9","kind":"claude-code","space":"sp1"},"tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21",'"$1"'}}}'
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
	[ "$(cat "$OUT")" = "[smith] GATE Smith-101 (working): GATE spec | Spec ready | docs/spec.md. RUN=$RUN" ]
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
	hc_get blocked "$NOW" 1 t5
	start_watch
	# 5 s threshold: the status is fresh when checked, and the test ends before it ages
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
	[ "$(cat "$OUT")" = "[smith] BLOCKED Smith-101 (blocked): no gate line yet. RUN=$RUN" ]
	[ "$(jq -r '.tasks["101"].reported.blocked' "$RUN/run.json")" = "$OLD" ]
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "gone_adopted_reported_child_not" {
	stub_reply hc get.t21 '{"state":"finished","parent":"t5","status_ms":0,"turn":2}'
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] GONE Smith-101 (gone): no gate line yet. RUN=$RUN" ]
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
	[ "$(cat "$OUT")" = "[smith] STOPPED Smith-101 (idle): GATE spec | Spec ready | s.md. RUN=$RUN" ]
	[ "$(jq -r '.tasks["101"].reported.stopped' "$RUN/run.json")" = "$OLD" ]
	start_watch
	stop_watch
	[ ! -s "$OUT" ]
}

@test "stopped_without_any_gate_line" {
	hc_get done "$OLD" 3
	start_watch
	stop_watch
	[ "$(cat "$OUT")" = "[smith] STOPPED Smith-101 (done): no gate line yet. RUN=$RUN" ]
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
	hc_get idle "$NOW" 3
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
	[ "$3" = "[smith] STOPPED Smith-101 (idle): no gate line yet. RUN=$RUN" ]
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
	[ "$(stub_calls hc | rg -c '^send t9 .*GATE.*Smith-101')" -ge 1 ]
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
	hc_get idle "$OLD" 3
	echo '{"method":"event","params":{"terminal":"t21","type":"status","data":{}}}' >"$STUB_DIR/hc.events.jsonl"
	start_watch
	stop_watch 3
	[[ $(cat "$OUT") == "[smith] STOPPED Smith-101"* ]]
}

@test "stream_label_and_json_flags" {
	hc_get working "$NOW" 1
	start_watch
	stop_watch 2
	stub_calls hc | rg -q "^events --label smith.run=run --json"
}

@test "dead_event_stream_keeps_ticking" {
	# the stub's events stream exits at once; the watcher still reports on its ticks
	export STUB_EVENTS_SLEEP=0
	hc_get idle "$OLD" 3
	start_watch
	stop_watch 6
	[[ $(cat "$OUT") == "[smith] STOPPED Smith-101"* ]]
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
