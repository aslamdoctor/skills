#!/usr/bin/env bash
# Send a prompt to a worker and verify it was delivered.
# Usage: RUN=<run dir> send.sh <id> < message.txt     (message on stdin avoids shell-quoting problems)
#        RUN=<run dir> send.sh <id> "short message"
# Exits 0 when delivered (and, for detected agents, the worker started working within ~8s).
# Detected agents: herdr agent prompt (blocked dialogs are dismissed with Esc first).
# Custom (tier D) workers: pasted with pane send-text plus Enter; delivery can't be confirmed by state.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

id=$1
if [ $# -ge 2 ]; then msg=$2; else msg=$(cat); fi
agent="i$id"; kind=$(task_field "$id" kind); pane=$(task_field "$id" pane)

# Baseline for watch.sh: a gate the worker marks before its watcher starts still counts as new.
log="$RUN/gates/$id.md"
lines=$(if [ -f "$log" ]; then wc -l <"$log" | tr -d ' '; else echo 0; fi)
run_update '.tasks[$id].gate_lines = ($n | tonumber)' --arg id "$id" --arg n "$lines"

if [ "$kind" = custom ]; then
	herdr pane send-text "$pane" "$msg" >/dev/null && sleep 0.5 && herdr pane send-keys "$pane" enter >/dev/null \
		&& { echo "sent to $agent (custom pane $pane; check the screen to confirm)"; exit 0; }
	echo "NOT DELIVERED to custom pane $pane"; exit 1
fi

[ "$(agent_state "$agent")" = blocked ] && { herdr agent send-keys "$agent" esc >/dev/null; sleep 2; }

# Never pass --timeout here: without --wait the CLI rejects it and sends nothing.
out=$(herdr agent prompt "$agent" "$msg" 2>&1)
if [ "$(jq -r '.result.type // empty' <<<"$out" 2>/dev/null)" != agent_prompted ]; then
	echo "NOT DELIVERED to $agent: $out"
	exit 1
fi

for _ in 1 2 3 4; do
	sleep 2
	state=$(agent_state "$agent")
	[ "$state" = working ] && { echo "delivered to $agent (working)"; exit 0; }
done
echo "prompted $agent but it is still '$state'; check with: herdr agent read $agent --source recent-unwrapped --lines 30"
exit 2
