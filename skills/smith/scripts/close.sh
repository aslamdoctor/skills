#!/usr/bin/env bash
# Herdr TUI wrap-up. Usage: RUN=<run dir> close.sh <id>...   or   RUN=<run dir> close.sh --all
# Per task: stop its detached watcher (by recorded pid), close its tab if it still exists, set .closed = true.
# With --all every open task in run.json is closed. Worktrees, branches and run.json are kept.
# Never closes a tab that isn't recorded in run.json, and never stops the Herdr server.
# Exit 0 when all went well, 1 when anything failed (a warning goes to stderr and the remaining
# tasks are still processed), 2 on a usage error or unknown task id (nothing touched).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

rc=0
self=0
ids=()
if [ "${1:-}" = "--all" ]; then
	[ "${2:-}" = "--self" ] && self=1
	while IFS= read -r id; do ids+=("$id"); done < <(jq -r '.tasks[] | select(.closed != true) | .id' "$RUN/run.json")
else
	ids=("$@")
	if [ "${#ids[@]}" -eq 0 ]; then
		echo "usage: close.sh <id>... | --all" >&2
		exit 2
	fi
fi

# Refuse unknown ids before touching anything.
for id in ${ids[@]+"${ids[@]}"}; do
	if [ "$(jq -r --arg id "$id" '.tasks | has($id)' "$RUN/run.json")" != true ]; then
		echo "close.sh: unknown task id '$id', nothing was closed" >&2
		exit 2
	fi
done

n=0
for id in ${ids[@]+"${ids[@]}"}; do
	# Watcher first, so closing the tab doesn't make it report GONE.
	stop_watcher "$(watch_pid_file "$id")"
	tab=$(task_field "$id" tab)
	if [ -n "$tab" ] && herdr tab get "$tab" >/dev/null 2>&1; then
		if ! out=$(herdr tab close "$tab" 2>&1); then
			echo "close.sh: herdr tab close $tab (task $id) failed: $out" >&2
			rc=1
			continue
		fi
	fi
	run_update '.tasks[$id].closed = true | .tasks[$id].needs_you = false' --arg id "$id"
	n=$((n + 1))
done
echo "closed $n of ${#ids[@]} workers"
# The orchestrator's own tab goes last, and only when every worker closed cleanly.
if [ "$self" -eq 1 ]; then
	if [ "$rc" -ne 0 ]; then
		echo "close.sh: a worker didn't close cleanly, so the orchestrator tab stays open" >&2
	elif [ -z "${HERDR_PANE_ID:-}" ] || [ -z "${HERDR_TAB_ID:-}" ]; then
		echo "close.sh: HERDR_PANE_ID or HERDR_TAB_ID isn't set, so the orchestrator tab stays open" >&2
		rc=1
	else
		nohup env RUN="$RUN" "$(dirname "$0")/close-self.sh" "$HERDR_PANE_ID" "$HERDR_TAB_ID" >/dev/null 2>&1 &
		echo "the orchestrator tab closes when this turn ends"
	fi
fi
exit "$rc"
