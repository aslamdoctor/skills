#!/usr/bin/env bash
# Block until a worker needs the orchestrator, then notify and report what happened.
# Usage: RUN=<run dir> watch.sh <id> [--grace <minutes>] [--notify <orchestrator pane or agent>]
# Returns when the worker:
#   GATE     writes a new gate line (mark.sh)
#   BLOCKED  shows a question or permission dialog
#   STOPPED  stops without a gate and stays stopped for the grace period (default 15 min)
#   GONE     disappears (tab closed, agent exited)
# An idle stop without a gate (e.g. waiting on its own background shell for a review bot) isn't reported.
#
# Delivery:
#   default   print the report and exit; run with the orchestrator's background-task feature
#   --notify  deliver the report as a prompt to the orchestrator agent via Herdr (works for any agent
#             Herdr detects). Run it detached: nohup env RUN=... watch.sh <id> --notify "$HERDR_PANE_ID" &
set -uo pipefail
. "$(dirname "$0")/lib.sh"

id=$1; shift
grace_min=15; notify=""
while [ $# -gt 0 ]; do
	case $1 in
		--grace) grace_min=$2; shift 2 ;;
		--notify) notify=$2; shift 2 ;;
		*) echo "unknown option $1"; exit 2 ;;
	esac
done
grace_ms=$((grace_min * 60000))
agent="i$id"; log="$RUN/gates/$id.md"
kind=$(task_field "$id" kind); pane=$(task_field "$id" pane)

count_lines() { if [ -f "$log" ]; then wc -l <"$log" | tr -d ' '; else echo 0; fi; }
# Lines already in the log when the last prompt was sent (send.sh records it), else now.
start_lines=$(task_field "$id" gate_lines); start_lines=${start_lines:-$(count_lines)}
new_gate() { [ "$(count_lines)" -gt "$start_lines" ]; }

deliver() {
	local text=$1 out tries=0
	while :; do
		out=$(herdr agent prompt "$notify" "$text" 2>&1)
		[ "$(jq -r '.result.type // empty' <<<"$out" 2>/dev/null)" = agent_prompted ] && return 0
		# agent_blocked: the orchestrator is showing the user a dialog. Wait instead of typing into it.
		tries=$((tries + 1)); [ $tries -gt 240 ] && return 1
		sleep 15
	done
}

report() {
	local what=$1 line state
	line=$(tail -1 "$log" 2>/dev/null || echo 'no gate line yet')
	if [ "$kind" = custom ]; then state=$(pane_alive "$pane" && echo alive || echo gone); else state=$(agent_state "$agent"); fi
	local sound=request; [ "$what" = GATE ] && [[ $line == "GATE pr |"* ]] && sound=done
	herdr notification show "Agent Smith: #$id $what" --body "${line:0:180}" --sound "$sound" >/dev/null 2>&1 || true
	local msg="$what i$id ($state)"$'\n'"STATUS: $line"
	if [ -n "$notify" ]; then
		deliver "[agent-smith] $what for task #$id ($state). $line. RUN=$RUN. Handle it as in agent-smith section 4, then re-arm this task's watcher."
	else
		echo "$msg"
	fi
	exit 0
}

sleep 5

# Tier D: Herdr reports no state. Poll the gate log, and treat an unchanged screen as stopped.
if [ "$kind" = custom ]; then
	last=""; still=0
	while :; do
		new_gate && report GATE
		pane_alive "$pane" || report GONE
		snap=$(herdr pane read "$pane" --source recent --lines 40 2>/dev/null | cksum)
		if [ "$snap" = "$last" ]; then still=$((still + 30)); else still=0; last=$snap; fi
		[ $((still * 1000)) -ge "$grace_ms" ] && report STOPPED
		sleep 30
	done
fi

while :; do
	# unknown is included so a Codex-style 'unknown' can't hang the wait; it only counts with a new gate line.
	herdr agent wait "$agent" --until idle --until done --until blocked --until unknown >/dev/null 2>&1
	state=$(agent_state "$agent")
	[ "$state" = gone ] && report GONE
	# Some agents flash an approval prompt that clears by itself; only report one that stays.
	if [ "$state" = blocked ]; then sleep 5; [ "$(agent_state "$agent")" = blocked ] && report BLOCKED; continue; fi
	new_gate && report GATE
	sleep 5; new_gate && report GATE   # mark.sh can land just after the agent goes idle
	if ! herdr agent wait "$agent" --until working --timeout "$grace_ms" >/dev/null 2>&1; then
		new_gate && report GATE
		report STOPPED
	fi
done
