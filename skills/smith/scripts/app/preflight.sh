#!/usr/bin/env bash
# herdr-app preflight. Usage: RUN=<run dir> preflight.sh [--resume]
# Records the backend and the orchestrator, links the smith-board mod, and makes sure the run's
# space and Board tab exist. Prints run.json minus tasks as one JSON line.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

app_do() { herdr-app "do" "$@"; }
fail() { jq -nc --arg e "$1" '{error:$e}'; exit 1; }

resume=0
[ "${1:-}" = "--resume" ] && resume=1

[ -n "${HC_TERMINAL_ID:-}" ] || fail "HC_TERMINAL_ID is not set, run smith inside the Herdr app"
hc server status >/dev/null 2>&1 || fail "hc server status failed, is the Herdr app running?"

root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not inside a git repository"
repo=$(basename "$root")

# Orchestrator, from its own hc record.
rec=$(hc get "$HC_TERMINAL_ID" --json 2>/dev/null) || fail "hc get $HC_TERMINAL_ID failed"
orch_kind=$(jq -r '.status.app // empty' <<<"$rec")
orch_space=$(jq -r '.labels["herdr.space"] // empty' <<<"$rec")

run_update '.backend = "herdr-app"'
if [ "$resume" = 1 ] || [ "$(jq -r '.orchestrator.address // empty' "$RUN/run.json")" = "" ]; then
	run_update '.orchestrator = {address: $a, kind: $k, space: $s}' \
		--arg a "$HC_TERMINAL_ID" --arg k "$orch_kind" --arg s "$orch_space"
fi
[ -n "$orch_space" ] || orch_space=$(jq -r '.orchestrator.space // empty' "$RUN/run.json")

# Mod link.
mods="$HOME/.config/herdr-app/mods"
link="$mods/smith-board"
target="$(cd "$here/../.." && pwd)/app/smith-board"
mkdir -p "$mods"
if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
	:
elif [ -e "$link" ] || [ -L "$link" ]; then
	fail "$link already exists and is not the smith-board link, move it away first"
else
	ln -s "$target" "$link"
fi

# Space and Board tab.
ls_json=$(herdr-app ls 2>/dev/null || echo '{"spaces":[]}')
space=$(jq -r '.space // empty' "$RUN/run.json")
board=$(jq -r '.board_tab // empty' "$RUN/run.json")
changed=0
default_tab=""

if [ -n "$space" ] && ! jq -e --arg s "$space" '.spaces[]? | select(.id == $s)' <<<"$ls_json" >/dev/null; then
	space=""
fi

if [ -z "$space" ]; then
	out=$(app_do space.new --name "smith $repo $(date +%F)" --folder "$root") || fail "space.new failed: $out"
	space=$(jq -r '.space // empty' <<<"$out")
	default_tab=$(jq -r '.tab // empty' <<<"$out")
	[ -n "$space" ] || fail "space.new returned no space: $out"
	run_update '.space = $s | del(.board_tab)' --arg s "$space"
	board=""
	changed=1
elif [ -n "$board" ] && ! jq -e --arg s "$space" --arg t "$board" '.spaces[]? | select(.id == $s) | .tabs[]? | select(.id == $t)' <<<"$ls_json" >/dev/null; then
	board=""
fi

if [ -z "$board" ]; then
	props=$(jq -nc --arg run "$RUN" '{run:$run}')
	if ! out=$(app_do tab.new --space "$space" --mod smith-board --name Board --props "$props"); then
		# Hand focus back before giving up; a rerun reuses the recorded space.
		[ -z "$orch_space" ] || app_do space.select --id "$orch_space" >/dev/null 2>&1 || true
		fail "tab.new failed: $out"
	fi
	board=$(jq -r '.tab // empty' <<<"$out")
	[ -n "$board" ] || fail "tab.new returned no tab: $out"
	run_update '.board_tab = $t' --arg t "$board"
	changed=1
fi

if [ -n "$default_tab" ] && [ "$default_tab" != "$board" ]; then
	app_do tab.close --id "$default_tab" --confirmed true >/dev/null 2>&1 || true
fi
if [ "$changed" = 1 ] && [ -n "$orch_space" ]; then
	app_do space.select --id "$orch_space" >/dev/null 2>&1 || true
fi

jq -c 'del(.tasks)' "$RUN/run.json"
