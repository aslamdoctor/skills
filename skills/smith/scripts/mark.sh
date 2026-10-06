#!/usr/bin/env bash
# Record that a worker reached a gate: gate log, run.json, and the Herdr sidebar label.
# Workers call this at every gate (the kickoff prompt gives them the exact command).
# Usage: RUN=<run dir> mark.sh <id> <gate> "<one-sentence status>" [path|commit|url]
#   gate: spec | implemented | pr | question | <any short word>
set -uo pipefail
. "$(dirname "$0")/lib.sh"

id=$1; gate=$2; text=$3; ref=${4:-}
echo "GATE $gate | $text | $ref" >>"$RUN/gates/$id.md"

pr=""
[[ $ref == *"/pull/"* ]] && pr=$ref
session=$(agent_session "i$id")

run_update '.tasks[$id] = ((.tasks[$id] // {id:$id}) + {gate:$gate, gate_text:$text, ref:$ref, updated:$now})
	| if $pr != "" then .tasks[$id].pr = $pr else . end
	| if $session != "" then .tasks[$id].session = $session else . end' \
	--arg id "$id" --arg gate "$gate" --arg text "$text" --arg ref "$ref" --arg pr "$pr" \
	--arg session "$session" --arg now "$(now)"

pane=$(task_field "$id" pane)
if [ -n "$pane" ]; then
	label="#$id $gate"
	[ "$gate" = question ] && label="#$id needs answer"
	herdr pane report-metadata "$pane" --source smith --title "#$id · $gate" \
		--state-label "idle=$label" --state-label "done=$label" --state-label "blocked=#$id blocked" \
		--state-label "working=#$id working" --token "gate=$gate" >/dev/null 2>&1 || true
fi
echo "marked #$id: $gate"
