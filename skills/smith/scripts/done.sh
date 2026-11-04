#!/usr/bin/env bash
# Is the run finished? It is when every task that isn't closed has reached its last gate
# (pr for code tasks, posted for review tasks) or its worker is gone. Works on both backends.
# Usage: RUN=<run dir> done.sh [--ask]
#   --ask  for the "offer cleanup once" check: on success, record that cleanup was offered,
#          so the next call exits 3 instead of 0. spawn.sh and send.sh reset it when work restarts.
# Prints one line. Exit 0 all done (offer cleanup), 1 workers still busy (listed),
# 3 nothing to offer (cleanup already offered, or no open tasks).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ask=0
[ "${1:-}" = --ask ] && ask=1

open=0; busy=""
# The gate is the last column, so an empty one can't shift the others.
while IFS=$'\t' read -r id type gate; do
	[ -n "$id" ] || continue
	open=$((open + 1))
	[ "$gate" = "$(final_gate "$type")" ] && continue
	[ "$(task_state "$id")" = gone ] && continue
	busy="${busy:+$busy, }$(worker_label "$id") (${gate:-no gate})"
done < <(jq -r '.tasks[] | select(.closed != true) | [.id, (.type // "code"), (.gate // "")] | @tsv' "$RUN/run.json")

[ "$open" -gt 0 ] || { echo "no open workers"; exit 3; }
[ -z "$busy" ] || { echo "still working: $busy"; exit 1; }
if [ "$ask" -eq 1 ]; then
	if [ "$(jq -r '.cleanup_offered // false' "$RUN/run.json")" = true ]; then
		echo "all $open workers done; cleanup was already offered"
		exit 3
	fi
	run_update '.cleanup_offered = true'
fi
echo "all $open workers done"
exit 0
