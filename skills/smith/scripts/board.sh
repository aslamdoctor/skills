#!/usr/bin/env bash
# Print a markdown table of every task in the run: kind, live state, latest gate, PR.
# Usage: RUN=<run dir> board.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

echo "| Task | Worker | Kind | Gate | Status | PR |"
echo "|---|---|---|---|---|---|"
if [ "$(run_backend)" = herdr-app ]; then
	# Unit separator, not tab: tab is IFS whitespace, so an empty gate would shift the columns.
	jq -r '.tasks[] | [.id, (.kind // "claude"), (.gate // ""), ((.gate_text // "") | gsub("\\|"; "/")), (.pr // "")] | join("\u001f")' "$RUN/run.json" |
		while IFS=$'\x1f' read -r id kind gate text pr; do
			echo "| #$id | $(worker_label "$id") ($(hc_state "$(worker_hc "$id")")) | $kind | $gate | $text | $pr |"
		done
	exit 0
fi
jq -r '.tasks[] | [.id, .agent, (.kind // "claude"), (.pane // ""), (.gate // ""), ((.gate_text // "") | gsub("\\|"; "/")), (.pr // "")] | @tsv' "$RUN/run.json" |
	while IFS=$'\t' read -r id agent kind pane gate text pr; do
		if [ "$kind" = custom ]; then state=$(pane_alive "$pane" && echo alive || echo closed); else state=$(agent_state "$agent"); fi
		echo "| #$id | $(worker_label "$id") ($state) | $kind | $gate | $text | $pr |"
	done
