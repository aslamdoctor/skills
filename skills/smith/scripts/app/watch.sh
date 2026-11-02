#!/usr/bin/env bash
# herdr-app: one watcher for the whole run. Wakes the orchestrator when a worker needs it.
# Usage: RUN=<run dir> watch.sh [--grace <minutes>] [--notify]
# Reports, per task, in this order:
#   GATE     mark.sh could not reach the orchestrator (gate_sent is false)
#   GONE     the worker disappeared (workers that are children of the orchestrator are hc's to report)
#   BLOCKED  a question or permission dialog stayed for 5 s or more (same child rule)
#   STOPPED  idle or done after at least one turn, no new gate line, for the grace period (default 15 min)
# Delivery:
#   default   print the report(s) and exit 0; run it as a background task of the orchestrator
#   --notify  `hc send` the report to the orchestrator and keep running. A refused send is retried
#             (never forced), so it cannot type into a dialog. Run detached.
# Env: SMITH_TICK (seconds between checks without events, default 60), SMITH_GRACE_SEC (overrides
#      --grace, for tests), SMITH_NOTIFY_RETRY (default 15 s), SMITH_NOTIFY_CAP (default 3600 s),
#      SMITH_SEND_TIMEOUT (bound on one `hc send`, default 60 s).
# Exits 0 with "no live workers" when every task is closed, or gone and already reported.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

grace_min=15; notify=0
while [ $# -gt 0 ]; do
	case $1 in
		--grace) grace_min=$2; shift 2 ;;
		--notify) notify=1; shift ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done
tick=${SMITH_TICK:-60}
grace_ms=$(( ${SMITH_GRACE_SEC:-$((grace_min * 60))} * 1000 ))
retry=${SMITH_NOTIFY_RETRY:-15}
cap=${SMITH_NOTIFY_CAP:-3600}
label="smith.run=$(basename "$RUN")"

# Milliseconds since the epoch. macOS date has no %N, so use perl (always on macOS), else python3.
now_ms() {
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import time; print(int(time.time() * 1000))'
	else
		echo "$(date +%s)000"
	fi
}

# Background work is tracked so the trap can stop it: a foreground sleep would delay the trap.
ev_pid=""; nap_pid=""
tmp=$(mktemp -d)
cleanup() {
	[ -n "$ev_pid" ] && kill "$ev_pid" 2>/dev/null
	[ -n "$nap_pid" ] && kill "$nap_pid" 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

nap() { sleep "$1" & nap_pid=$!; wait "$nap_pid" 2>/dev/null; nap_pid=""; }

start_stream() {
	rm -f "$tmp/ev"; mkfifo "$tmp/ev"
	hc events --label "$label" --json >"$tmp/ev" 2>/dev/null &
	ev_pid=$!
	exec 3<"$tmp/ev"
}
stop_stream() {
	exec 3<&-
	[ -n "$ev_pid" ] && kill "$ev_pid" 2>/dev/null
	[ -n "$ev_pid" ] && wait "$ev_pid" 2>/dev/null
	ev_pid=""
}

# A child of the orchestrator: hc already sends it the exit note and the blocked ping.
is_child() { [ -n "$orch_addr" ] && [ "$(hc_parent "$1")" = "$orch_addr" ]; }
hc_parent() { hc get "$1" --json 2>/dev/null | jq -r '.parent // empty' 2>/dev/null || true; }
log_lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

printed=0
# send_report <text>: --notify retries a refused send every $retry s for up to $cap s, then drops it.
send_report() {
	local waited=0 orch
	orch=$(jq -r '.orchestrator.address // empty' "$RUN/run.json")
	[ -n "$orch" ] || { echo "watch.sh: no orchestrator.address in run.json" >&2; return 1; }
	while :; do
		send_bounded "${SMITH_SEND_TIMEOUT:-60}" "$orch" "$1" && return 0
		waited=$((waited + retry))
		[ "$waited" -ge "$cap" ] && return 1
		nap "$retry"
	done
}

# report <what> <id> <state>: deliver. Returns non-zero when a --notify send was dropped.
report() {
	local what=$1 id=$2 state=$3 line text
	line=$(tail -1 "$RUN/gates/$id.md" 2>/dev/null) || true
	text="[smith] $what $(worker_label "$id") ($state): ${line:-no gate line yet}. RUN=$RUN"
	if [ "$notify" = 1 ]; then
		send_report "$text" || echo "watch.sh: dropped report for $(worker_label "$id"): $what" >&2
	else
		echo "$text"; printed=1
	fi
}

live=0
check_tasks() {
	local id f closed dropped glines r_gone r_blocked r_stopped hc state now sms turn log
	live=0
	for id in $(jq -r '.tasks | keys[]' "$RUN/run.json" 2>/dev/null); do
		f=$(jq -r --arg id "$id" '.tasks[$id] | [(.closed == true), (.gate_sent == false), (.gate_lines // 0),
			(.reported.gone // false), (.reported.blocked // 0), (.reported.stopped // 0)] | map(tostring) | join(" ")' "$RUN/run.json")
		read -r closed dropped glines r_gone r_blocked r_stopped <<<"$f"
		[ "$closed" = true ] && continue
		hc=$(worker_hc "$id"); log="$RUN/gates/$id.md"
		state=$(hc_state "$hc")

		# 1. GATE: mark.sh could not reach the orchestrator.
		if [ "$dropped" = true ]; then
			report GATE "$id" "$state"
			run_update '.tasks[$id].gate_sent = true' --arg id "$id"
		fi

		if [ "$state" = gone ]; then
			# 2. GONE: a child's exit already reaches the orchestrator through hc.
			if is_child "$hc" || [ "$r_gone" = true ]; then continue; fi
			report GONE "$id" gone
			run_update '.tasks[$id].reported.gone = true' --arg id "$id"
			live=$((live + 1))
			continue
		fi
		live=$((live + 1))

		now=$(now_ms); sms=$(hc_status_ms "$hc")
		if [ "$state" = blocked ]; then
			# 3. BLOCKED: only a dialog that stays, and only for adopted workers.
			if [ $((now - sms)) -ge 5000 ] && [ "$r_blocked" != "$sms" ] && ! is_child "$hc"; then
				report BLOCKED "$id" "$state"
				run_update '.tasks[$id].reported.blocked = ($ms | tonumber)' --arg id "$id" --arg ms "$sms"
			fi
		elif [ "$state" = idle ] || [ "$state" = "done" ]; then
			# 4. STOPPED: a boot-time idle (turn 0) is not a stop, and a new gate line means mark.sh spoke.
			turn=$(hc_turn "$hc")
			if [ "$turn" -gt 0 ] 2>/dev/null && [ $((now - sms)) -ge "$grace_ms" ] \
				&& [ "$(log_lines "$log")" -le "$glines" ] && [ "$r_stopped" != "$sms" ]; then
				report STOPPED "$id" "$state"
				run_update '.tasks[$id].reported.stopped = ($ms | tonumber)' --arg id "$id" --arg ms "$sms"
			fi
		fi
	done
}

# One pass. Default mode ends with the first report; any mode ends when nothing is left to watch.
pass() {
	orch_addr=$(jq -r '.orchestrator.address // empty' "$RUN/run.json")
	check_tasks
	if [ "$printed" = 1 ]; then exit 0; fi
	if [ "$live" -eq 0 ]; then echo "no live workers"; exit 0; fi
}

pass
start_stream
while :; do
	if IFS= read -r -t "$tick" -u 3 _line; then
		pass
	else
		rc=$?
		if [ "$rc" -gt 128 ]; then
			pass   # tick
		else
			# The event stream ended. Keep watching on ticks and reopen it.
			stop_stream
			nap "$tick"
			pass
			start_stream
		fi
	fi
done
