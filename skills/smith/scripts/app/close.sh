#!/usr/bin/env bash
# herdr-app wrap-up. Usage: RUN=<run dir> close.sh <id>...   or   RUN=<run dir> close.sh --all
# Per task: hc kill + hc rm its terminal, close its tab if it still exists, set .closed = true.
# With --all every task is closed, then the Board tab and the run's space (only the ids recorded
# in run.json, and only if still present). Worktrees, branches and run.json are kept.
# Never calls `hc server`, `herdr-app quit`, or closes any id that is not in run.json.
# An already-removed terminal ("not_found") is fine. Exit 0 when all went well, 1 when anything else
# failed (a warning goes to stderr and the remaining tasks are still processed), 2 on a usage error.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

app_do() { herdr-app "do" "$@"; }
warn() { echo "close.sh: $*" >&2; rc=1; }
rc=0

all=0
if [ "${1:-}" = "--all" ]; then
	all=1
	mapfile -t ids < <(jq -r '.tasks | keys[]' "$RUN/run.json")
else
	ids=("$@")
fi
if [ "$all" -eq 0 ] && [ "${#ids[@]}" -eq 0 ]; then
	echo "usage: close.sh <id>... | --all" >&2
	exit 2
fi

# Refuse unknown ids before touching anything.
for id in "${ids[@]}"; do
	if [ "$(jq -r --arg id "$id" '.tasks | has($id)' "$RUN/run.json")" != true ]; then
		echo "close.sh: unknown task id '$id', nothing was closed" >&2
		exit 2
	fi
done

# Ids of every tab and space that exists right now.
live_ids() { herdr-app ls 2>/dev/null | jq -r '.spaces[]? | .id, (.tabs[]? | .id)'; }
exists() { printf '%s\n' "$live" | rg -qx -- "$1"; }

# Run a terminal command; "not_found" means it is already gone, anything else is a failure.
term_do() {
	local what=$1 out; shift
	if ! out=$("$@" 2>&1); then
		case $out in *not_found*) ;; *) warn "$what failed: $out" ;; esac
	fi
}

for id in "${ids[@]}"; do
	term=$(task_field "$id" hc); tab=$(task_field "$id" tab)
	if [ -n "$term" ]; then
		term_do "hc kill $term (task $id)" hc kill "$term"
		term_do "hc rm $term (task $id)" hc rm "$term"
	fi
	live=$(live_ids)
	if [ -n "$tab" ] && exists "$tab"; then
		out=$(app_do tab.close --id "$tab" --confirmed true 2>&1) || warn "tab.close $tab (task $id) failed: $out"
	fi
	run_update '.tasks[$id].closed = true' --arg id "$id"
done

if [ "$all" -eq 1 ]; then
	board=$(jq -r '.board_tab // empty' "$RUN/run.json"); space=$(jq -r '.space // empty' "$RUN/run.json")
	live=$(live_ids)
	if [ -n "$board" ] && exists "$board"; then
		out=$(app_do tab.close --id "$board" --confirmed true 2>&1) || warn "tab.close $board (Board) failed: $out"
	fi
	live=$(live_ids)
	if [ -n "$space" ] && exists "$space"; then
		out=$(app_do space.close --id "$space" --confirmed true 2>&1) || warn "space.close $space failed: $out"
	fi
fi
exit "$rc"
