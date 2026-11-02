load helper
bats_require_minimum_version 1.5.0

setup() {
	RUN=$BATS_TEST_TMPDIR/run
	STUB_DIR=$BATS_TEST_TMPDIR/stub
	mkdir -p "$RUN/gates" "$STUB_DIR"
	export RUN STUB_DIR
	export PATH="$REPO_ROOT/tests/smith/stubs:$PATH"
	export S="$REPO_ROOT/skills/smith/scripts/app"
	export SEND_ESC_WAIT=0.3 SEND_WAIT=0.3 SEND_INTERVAL=0.1 SEND_TIMEOUT=1
	write_run '{"backend":"herdr-app","orchestrator":{"address":"t9"},"tasks":{"101":{"id":"101","agent":"smith-101","hc":"t21","needs_you":true,"gate_lines":0}}}'
}

snd() { "$S/send.sh" "$@"; }
st() { printf '{"state":"live","turn":%s,"status":{"app":"claude-code","state":"%s"}}\n' "${2:-0}" "$1"; }

@test "delivered_on_working" {
	stub_reply hc get.t21 "$(st working)"
	run snd 101 "do the thing"
	[ "$status" -eq 0 ]
	[ "$output" = "delivered to smith-101 (working)" ]
	[ -n "$(stub_calls hc | rg '^send t21 ')" ]
}

@test "delivered_on_turn_change" {
	printf '%s\n' "$(st idle 1)" >"$STUB_DIR/hc.get.t21.1.json"
	printf '%s\n' "$(st idle 1)" >"$STUB_DIR/hc.get.t21.2.json"
	printf '%s\n' "$(st idle 2)" >"$STUB_DIR/hc.get.t21.3.json"
	run snd 101 "go"
	[ "$status" -eq 0 ]
	[ "$output" = "delivered to smith-101 (working)" ]
}

@test "blocked_presses_esc_first" {
	printf '%s\n' "$(st blocked)" >"$STUB_DIR/hc.get.t21.1.json"
	printf '%s\n' "$(st idle)" >"$STUB_DIR/hc.get.t21.2.json"
	printf '%s\n' "$(st idle)" >"$STUB_DIR/hc.get.t21.3.json"
	printf '%s\n' "$(st working)" >"$STUB_DIR/hc.get.t21.4.json"
	run snd 101 "go"
	[ "$status" -eq 0 ]
	mapfile -t calls < <(stub_calls hc | rg '^(keys|send) ')
	[ "${#calls[@]}" -eq 2 ]
	[ "${calls[0]}" = "keys t21 esc " ]
	[[ ${calls[1]} == "send t21 "* ]]
}

@test "still_blocked_not_delivered" {
	stub_reply hc get.t21 "$(st blocked)"
	run snd 101 "go"
	[ "$status" -eq 1 ]
	[ "$output" = "NOT DELIVERED: Smith-101 is blocked on a dialog; read it first" ]
	[ -z "$(stub_calls hc | rg '^send ' || true)" ]
}

@test "never_force" {
	stub_reply hc get.t21 "$(st blocked)"
	run snd 101 "go"
	[ -z "$(stub_calls hc | rg -e '--force' || true)" ]
	stub_reply hc get.t21 "$(st working)"
	run snd 101 "go"
	[ -z "$(stub_calls hc | rg -e '--force' || true)" ]
}

@test "clears_needs_you_and_records_baseline" {
	printf 'GATE spec | a | b\nGATE x | c | d\n' >"$RUN/gates/101.md"
	stub_reply hc get.t21 "$(st working)"
	run snd 101 "go"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.tasks["101"].gate_lines' "$RUN/run.json")" = 2 ]
}

@test "needs_you_false_after_send" {
	stub_reply hc get.t21 "$(st working)"
	run snd 101 "go"
	[ "$(jq -r '.tasks["101"].needs_you' "$RUN/run.json")" = false ]
}

@test "message_with_quotes_exact" {
	stub_reply hc get.t21 "$(st working)"
	msg=$'say "hi" and \'bye\' $HOME `x`\nline two'
	run snd 101 "$msg"
	[ "$status" -eq 0 ]
	line=$(stub_calls hc | rg '^send ' | head -1)
	eval "set -- $line"
	[ "$#" -eq 3 ]
	[ "$3" = "$msg" ]
}

@test "message_from_stdin" {
	stub_reply hc get.t21 "$(st working)"
	run snd 101 <<<"from stdin"
	[ "$status" -eq 0 ]
	line=$(stub_calls hc | rg '^send ')
	eval "set -- $line"
	[ "$3" = "from stdin" ]
}

@test "send_failure_not_delivered" {
	stub_reply hc get.t21 "$(st idle)"
	stub_reply hc send '{}' 1
	run snd 101 "go"
	[ "$status" -eq 1 ]
	[[ $output == "NOT DELIVERED to smith-101"* ]]
}

@test "send_timeout_not_delivered" {
	stub_reply hc get.t21 "$(st idle)"
	stub_reply hc send '{}'
	echo 30 >"$STUB_DIR/hc.send.sleep"
	SEND_TIMEOUT=1 run snd 101 "go"
	[ "$status" -eq 1 ]
	[[ $output == "NOT DELIVERED to smith-101"* ]]
}

@test "still_idle_exit_2_with_read_hint" {
	stub_reply hc get.t21 "$(st idle)"
	run snd 101 "go"
	[ "$status" -eq 2 ]
	[[ $output == *"still 'idle'"* ]]
	[[ $output == *"hc read t21 --lines 30"* ]]
}
