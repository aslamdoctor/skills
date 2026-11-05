#!/usr/bin/env bash
# herdr-app wrap-up. Usage: RUN=<run dir> close.sh <id>...   or   RUN=<run dir> close.sh --all
# Per task: hc kill + hc rm its terminal, close its tab if it still exists, set .closed = true.
# With --all every task in run.json is closed. Worktrees, branches and run.json are kept.
# When no open task is left, the detached watcher recorded in <run>/watch.pid is stopped too.
# Never calls `hc server`, `herdr-app quit`, or closes any id that is not in run.json.
# An already-removed terminal (exit 3 with "not_found") is fine. A task is marked closed only when all its steps succeeded. Exit 0 when all went well, 1 when anything else
# failed (a warning goes to stderr and the remaining tasks are still processed), 2 on a usage error.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

app_do() { herdr-app "do" "$@"; }
warn() { echo "close.sh: $*" >&2; rc=1; tfail=1; }
rc=0; tfail=0

all=0
self=0
ids=()
if [ "${1:-}" = "--all" ]; then
	all=1
	[ "${2:-}" = "--self" ] && self=1
	while IFS= read -r id; do ids+=("$id"); done < <(jq -r '.tasks | keys[]' "$RUN/run.json")
else
	ids=("$@")
fi
if [ "$all" -eq 0 ] && [ "${#ids[@]}" -eq 0 ]; then
	echo "usage: close.sh <id>... | --all" >&2
	exit 2
fi

# Refuse unknown ids before touching anything.
for id in ${ids[@]+"${ids[@]}"}; do
	if [ "$(jq -r --arg id "$id" '.tasks | has($id)' "$RUN/run.json")" != true ]; then
		echo "close.sh: unknown task id '$id', nothing was closed" >&2
		exit 2
	fi
done

# Ids of every tab and space that exists right now. live_ok=0 when herdr-app ls fails or is not JSON.
refresh_live() {
	local out
	live_ok=1; live=
	if ! out=$(herdr-app ls 2>&1) || ! live=$(jq -r '.spaces[] | .id, (.tabs[]? | .id)' <<<"$out" 2>/dev/null); then
		live_ok=0; live=
		warn "herdr-app ls failed or returned bad JSON, cannot tell which tabs exist: $out"
	fi
}
exists() { printf '%s\n' "$live" | rg -qx -- "$1"; }

# Close a tab or space if it still exists.
close_if_present() {
	local verb=$1 target=$2 what=$3 out
	[ -n "$target" ] || return 0
	[ "$live_ok" -eq 1 ] || return 0
	exists "$target" || return 0
	out=$(app_do "$verb" --id "$target" --confirmed true 2>&1) || warn "$verb $target ($what) failed: $out"
}

# Run a terminal command. Already gone means exit 3 with "not_found"; anything else is a failure.
term_do() {
	local what=$1 out code; shift
	out=$("$@" 2>&1); code=$?
	[ "$code" -eq 0 ] && return 0
	if [ "$code" -eq 3 ] && [[ $out == *not_found* ]]; then return 0; fi
	warn "$what failed (exit $code): $out"
}

for id in ${ids[@]+"${ids[@]}"}; do
	tfail=0
	term=$(task_field "$id" hc); tab=$(task_field "$id" tab)
	if [ -n "$term" ]; then
		term_do "hc kill $term (task $id)" hc kill "$term"
		term_do "hc rm $term (task $id)" hc rm "$term"
	fi
	refresh_live
	close_if_present tab.close "$tab" "task $id"
	[ "$tfail" -eq 0 ] && run_update '.tasks[$id].closed = true | .tasks[$id].needs_you = false' --arg id "$id"
done
# Once no task is open, stop the run's detached --notify watcher (by its recorded pid only).
if [ "$(jq '[.tasks[] | select(.closed != true)] | length' "$RUN/run.json")" -eq 0 ]; then
	stop_watcher "$RUN/watch.pid"
fi
# The orchestrator's own tab goes last, and only when every worker closed cleanly and this is that orchestrator.
if [ "$self" -eq 1 ]; then
	orch=$(jq -r '.orchestrator.address // empty' "$RUN/run.json"); orch_tab=$(jq -r '.orchestrator.tab // empty' "$RUN/run.json")
	if [ "$rc" -ne 0 ]; then
		echo "close.sh: a worker didn't close cleanly, so the orchestrator tab stays open" >&2
	elif [ -z "$orch" ] || [ -z "$orch_tab" ]; then
		warn "no orchestrator address or tab in run.json, the orchestrator tab stays open"
	elif [ "${HC_TERMINAL_ID:-}" != "$orch" ]; then
		warn "this isn't the run's orchestrator ($orch), so its tab stays open"
	else
		nohup env RUN="$RUN" "$here/../close-self.sh" "$orch" "$orch_tab" >/dev/null 2>&1 &
		echo "the orchestrator tab ($(orch_label "$orch")) closes when this turn ends"
	fi
fi
exit "$rc"
