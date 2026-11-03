#!/usr/bin/env bash
# Record that a worker reached a gate: gate log, run.json, and the Herdr sidebar label.
# Workers call this at every gate (the kickoff prompt gives them the exact command).
# Usage: RUN=<run dir> mark.sh <id> <gate> "<one-sentence status>" [path|commit|url]
#   gate: spec | implemented | pr | question | <any short word>
set -uo pipefail
. "$(dirname "$0")/lib.sh"

id=$1; gate=$2; text=$3; ref=${4:-}
echo "GATE $gate | $text | $ref" >>"$(gate_log "$id")"

pr=""
[[ $ref == *"/pull/"* ]] && pr=$ref
backend=$(run_backend)
session=""
[ "$backend" = herdr-app ] || session=$(agent_session "$(worker_agent "$id")")

run_update '.tasks[$id] = ((.tasks[$id] // {id:$id}) + {gate:$gate, gate_text:$text, ref:$ref, updated:$now})
	| if $pr != "" then .tasks[$id].pr = $pr else . end
	| if $session != "" then .tasks[$id].session = $session else . end' \
	--arg id "$id" --arg gate "$gate" --arg text "$text" --arg ref "$ref" --arg pr "$pr" \
	--arg session "$session" --arg now "$(now)"

suffix=""
case $backend in
herdr-app)
	hc label "$(worker_hc "$id")" "smith.gate=$gate" >/dev/null 2>&1 \
		|| echo "mark.sh: hc label failed for $(worker_label "$id"); gate still recorded" >&2
	orch=$(jq -r '.orchestrator.address // empty' "$RUN/run.json" 2>/dev/null)
	sent=false
	if [ -n "$orch" ] && send_bounded "${MARK_SEND_TIMEOUT:-60}" "$orch" "[smith] GATE $gate $(worker_label "$id"): $text | $ref"; then
		sent=true
	fi
	run_update '.tasks[$id].gate_sent = ($sent == "true") | .tasks[$id].needs_you = true' \
		--arg id "$id" --arg sent "$sent"
	[ "$sent" = true ] || suffix=" (orchestrator not reached; the watcher will report it)"
	;;
*)
	pane=$(task_field "$id" pane)
	if [ -n "$pane" ]; then
		name=$(worker_label "$id")
		label="$name $gate"
		[ "$gate" = question ] && label="$name needs answer"
		herdr pane report-metadata "$pane" --source smith --title "$name · $gate" \
			--state-label "idle=$label" --state-label "done=$label" --state-label "blocked=$name blocked" \
			--state-label "working=$name working" --token "gate=$gate" >/dev/null 2>&1 || true
	fi
	;;
esac
echo "marked $(worker_label "$id"): $gate$suffix"
