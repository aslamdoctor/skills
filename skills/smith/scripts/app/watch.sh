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
#   --notify  `hc send` the report to the orchestrator and keep running. A refused send is queued and
#             retried on later passes (never forced), so it cannot type into a dialog, and the other
#             tasks keep being checked. Run detached.
# Env: SMITH_TICK (seconds between checks without events, default 60), SMITH_GRACE_SEC (overrides
#      --grace, for tests), SMITH_NOTIFY_RETRY (default 15 s), SMITH_NOTIFY_CAP (default 3600 s),
#      SMITH_SEND_TIMEOUT (bound on one `hc send`, default 60 s).
# Exits 0 with "no live workers" when every task is closed, or gone and already reported.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "${RUN:-/nonexistent}/run.json" ] || ! jq -e '.tasks | type == "object"' "$RUN/run.json" >/dev/null 2>&1; then
	echo "watch.sh: missing or unreadable run.json in '${RUN:-}'" >&2
	exit 1
fi
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

# Milliseconds since the epoch. macOS date has no %N, so use perl (always on macOS), else python3,
# else whole seconds. Anything that is not a number falls through to the next one.
now_ms() {
	local v=""
	if command -v perl >/dev/null 2>&1; then v=$(perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000' 2>/dev/null)
	fi
	if ! [[ $v =~ ^[0-9]+$ ]] && command -v python3 >/dev/null 2>&1; then v=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null)
	fi
	[[ $v =~ ^[0-9]+$ ]] || v="$(date +%s)000"
	echo "$v"
}

# Background work is tracked so the trap can stop it: a foreground sleep would delay the trap.
ev_pid=""; nap_pid=""
tmp=$(mktemp -d)
mkdir -p "$tmp/q" "$tmp/parent"
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

log_lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# One `hc get` per task per pass. Sets state sms turn parent. Returns 1 when the answer is unknown
# (hc failed for some other reason): the caller skips the task, it never means "gone".
fetch_task() {
	local id=$1 out rc f
	out=$(hc get "$2" --json 2>&1); rc=$?
	if [ "$rc" -eq 0 ] && f=$(jq -r '[(if .state != "live" then "gone" else (.status.state // "idle") end),
			(.status_ms // 0), (.turn // 0), (.parent // "-")] | map(tostring) | join(" ")' <<<"$out" 2>/dev/null) && [ -n "$f" ]; then
		read -r state sms turn parent <<<"$f"
		[ "$parent" = "-" ] && parent=""
		printf '%s' "$parent" >"$tmp/parent/$id"
		return 0
	fi
	# hc prints {"error":{"kind":"not_found"}} (exit 3) for a terminal that was removed.
	if [ "$(jq -r '.error.kind // empty' <<<"$out" 2>/dev/null)" = not_found ]; then
		state=gone; sms=0; turn=0; parent=$(cat "$tmp/parent/$id" 2>/dev/null || true)
		return 0
	fi
	return 1
}

# A child of the orchestrator: hc already sends it the exit note and the blocked ping.
is_child() { [ -n "$orch_addr" ] && [ "$parent" = "$orch_addr" ]; }

# Write the dedupe field once a report is delivered (or dropped).
finish() {
	case $1 in
		GATE) run_update '.tasks[$id].gate_sent = true' --arg id "$2" ;;
		GONE) run_update '.tasks[$id].reported.gone = true' --arg id "$2" ;;
		BLOCKED) run_update '.tasks[$id].reported.blocked = ($ms | tonumber)' --arg id "$2" --arg ms "$3" ;;
		STOPPED) run_update '.tasks[$id].reported.stopped = ($ms | tonumber)' --arg id "$2" --arg ms "$3" ;;
	esac
}

printed=0
# report <what> <id> <state> <status_ms>. Default mode prints. --notify queues the report; flush_queue
# sends it, so a refused send never stops the other tasks from being checked.
report() {
	local what=$1 id=$2 state=$3 ms=$4 line text q="$tmp/q/$2.$1" first=0 last=0
	line=$(tail -1 "$RUN/gates/$id.md" 2>/dev/null) || true
	text="[smith] $what $(worker_label "$id") ($state): ${line:-no gate line yet}. RUN=$RUN"
	if [ "$notify" = 1 ]; then
		# Already pending: refresh the text, keep its timing so the cap still counts from the first try.
		if [ -f "$q" ]; then { read -r first; read -r last; } <"$q"; else first=$(date +%s); fi
		printf '%s\n%s\n%s\n%s\n' "$first" "$last" "$ms" "$text" >"$q"
	else
		echo "$text"; printed=1
		finish "$what" "$id" "$ms"
	fi
}

# Try each queued report at most once per $retry s; drop it after $cap s.
flush_queue() {
	local q name id what first last ms text now orch
	orch=$(jq -r '.orchestrator.address // empty' "$RUN/run.json" 2>/dev/null)
	for q in "$tmp"/q/*; do
		[ -f "$q" ] || continue
		name=${q##*/}; id=${name%%.*}; what=${name#*.}
		{ read -r first; read -r last; read -r ms; IFS= read -r text; } <"$q"
		now=$(date +%s)
		[ $((now - last)) -ge "$retry" ] || continue
		if [ -n "$orch" ] && send_bounded "${SMITH_SEND_TIMEOUT:-60}" "$orch" "$text"; then
			finish "$what" "$id" "$ms"; rm -f "$q"
		elif [ $((now - first)) -ge "$cap" ]; then
			echo "watch.sh: dropped report for $(worker_label "$id"): $what" >&2
			finish "$what" "$id" "$ms"; rm -f "$q"
		else
			printf '%s\n%s\n%s\n%s\n' "$first" "$now" "$ms" "$text" >"$q"
		fi
	done
}

live=0
check_tasks() {
	local id ids f closed dropped glines r_gone r_blocked r_stopped hc state sms turn parent now log
	ids=$(jq -r '.tasks | keys[]' "$RUN/run.json" 2>/dev/null) || return 1
	live=0
	for id in $ids; do
		f=$(jq -r --arg id "$id" '.tasks[$id] | [(.closed == true), (.gate_sent == false), (.gate_lines // 0),
			(.reported.gone // false), (.reported.blocked // 0), (.reported.stopped // 0)] | map(tostring) | join(" ")' "$RUN/run.json") || return 1
		read -r closed dropped glines r_gone r_blocked r_stopped <<<"$f"
		[ "$closed" = true ] && continue
		hc=$(worker_hc "$id"); log="$RUN/gates/$id.md"
		# Unknown answer: keep the task live, decide nothing this pass.
		if ! fetch_task "$id" "$hc"; then live=$((live + 1)); continue; fi

		# 1. GATE: mark.sh could not reach the orchestrator.
		[ "$dropped" = true ] && report GATE "$id" "$state" 0

		if [ "$state" = gone ]; then
			# 2. GONE: a child's exit already reaches the orchestrator through hc.
			if is_child || [ "$r_gone" = true ]; then continue; fi
			report GONE "$id" gone 0
			live=$((live + 1))
			continue
		fi
		live=$((live + 1))

		now=$(now_ms)
		if [ "$state" = blocked ]; then
			# 3. BLOCKED: only a dialog that stays, and only for adopted workers.
			if [ $((now - sms)) -ge 5000 ] && [ "$r_blocked" != "$sms" ] && ! is_child; then
				report BLOCKED "$id" "$state" "$sms"
			fi
		elif [ "$state" = idle ] || [ "$state" = "done" ]; then
			# 4. STOPPED: a boot-time idle (turn 0) is not a stop, and a new gate line means mark.sh spoke.
			if [ "$turn" -gt 0 ] 2>/dev/null && [ $((now - sms)) -ge "$grace_ms" ] \
				&& [ "$(log_lines "$log")" -le "$glines" ] && [ "$r_stopped" != "$sms" ]; then
				report STOPPED "$id" "$state" "$sms"
			fi
		fi
	done
}

# One pass. Default mode ends with the first report; any mode ends when nothing is left to watch.
pass() {
	orch_addr=$(jq -r '.orchestrator.address // empty' "$RUN/run.json" 2>/dev/null)
	[ "$notify" = 1 ] && flush_queue
	if ! check_tasks; then return; fi   # run.json unreadable for a moment: try again next pass
	[ "$notify" = 1 ] && flush_queue
	if [ "$printed" = 1 ]; then exit 0; fi
	if [ "$live" -eq 0 ] && [ -z "$(ls "$tmp/q" 2>/dev/null)" ]; then echo "no live workers"; exit 0; fi
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
