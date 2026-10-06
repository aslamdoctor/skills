#!/usr/bin/env bash
# Print a markdown table of every task in the run: kind, live state, latest gate, PR.
# Usage: RUN=<run dir> board.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

echo "| Task | Worker | Kind | Gate | Status | PR |"
echo "|---|---|---|---|---|---|"
jq -r '.tasks[] | [.id, .agent, (.kind // "claude"), (.pane // ""), (.gate // ""), ((.gate_text // "") | gsub("\\|"; "/")), (.pr // "")] | @tsv' "$RUN/run.json" |
	while IFS=$'\t' read -r id agent kind pane gate text pr; do
		if [ "$kind" = custom ]; then state=$(pane_alive "$pane" && echo alive || echo closed); else state=$(agent_state "$agent"); fi
		echo "| #$id | $agent ($state) | $kind | $gate | $text | $pr |"
	done
