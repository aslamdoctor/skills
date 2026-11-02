#!/usr/bin/env bash
# herdr-app: send a prompt to a worker and verify it was delivered.
# Usage: RUN=<run dir> send.sh <id> < message.txt     (message on stdin avoids shell-quoting problems)
#        RUN=<run dir> send.sh <id> "short message"
# Exit 0 delivered (worker is working or its turn counter moved), 1 not delivered, 2 sent but not confirmed.
# A blocked dialog is dismissed with Esc first. Never uses `hc send --force`.
# Env: SEND_TIMEOUT (default 30 s, bound on `hc send`), SEND_ESC_WAIT (default 4 s), SEND_WAIT (default 8 s),
#      SEND_INTERVAL (default 1 s), all seconds.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

id=$1
if [ $# -ge 2 ]; then msg=$2; else msg=$(cat); fi
agent=$(worker_agent "$id"); target=$(worker_hc "$id")
interval=${SEND_INTERVAL:-1}
# Number of polls that fit in a wait.
polls() { awk -v w="$1" -v i="$interval" 'BEGIN { n = int(w / i + 0.5); print (n < 1 ? 1 : n) }'; }

# Baseline for watch.sh: a gate the worker marks before its watcher starts still counts as new.
log="$RUN/gates/$id.md"
lines=$(if [ -f "$log" ]; then wc -l <"$log" | tr -d ' '; else echo 0; fi)
run_update '.tasks[$id].gate_lines = ($n | tonumber)' --arg id "$id" --arg n "$lines"
# needs_you is cleared only once the message went out (exit 0 or 2), so a failed send leaves it set.
clear_needs_you() { run_update '.tasks[$id].needs_you = false' --arg id "$id"; }

if [ "$(hc_state "$target")" = blocked ]; then
	hc keys "$target" esc >/dev/null 2>&1
	state=blocked
	for _ in $(seq "$(polls "${SEND_ESC_WAIT:-4}")"); do
		sleep "$interval"
		state=$(hc_state "$target")
		[ "$state" = blocked ] || break
	done
	if [ "$state" = blocked ]; then
		echo "NOT DELIVERED: $(worker_label "$id") is blocked on a dialog; read it first"
		exit 1
	fi
fi

turn0=$(hc_turn "$target")
if ! send_bounded "${SEND_TIMEOUT:-30}" "$target" "$msg"; then
	echo "NOT DELIVERED to $agent: hc send failed or timed out"
	exit 1
fi

state=gone
for _ in $(seq "$(polls "${SEND_WAIT:-8}")"); do
	sleep "$interval"
	state=$(hc_state "$target")
	if [ "$state" = working ] || [ "$(hc_turn "$target")" -gt "$turn0" ] 2>/dev/null; then
		echo "delivered to $agent (working)"
		clear_needs_you
		exit 0
	fi
done
clear_needs_you
echo "sent to $agent but it is still '$state'; check with: hc read $target --lines 30"
exit 2
