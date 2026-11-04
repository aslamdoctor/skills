#!/usr/bin/env bash
# herdr-app preflight. Usage: RUN=<run dir> preflight.sh [--resume]
# Records the backend and the orchestrator (address, kind, space, tab). Workers open as tabs in the
# orchestrator's space and show nested under it in the sidebar. Renames the orchestrator's tab to "SMITH-ORC<n>" (t7 -> SMITH-ORC7).
# Prints run.json minus tasks as one JSON line.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

fail() { jq -nc --arg e "$1" '{error:$e}'; exit 1; }

resume=0
[ "${1:-}" = "--resume" ] && resume=1

[ -n "${HC_TERMINAL_ID:-}" ] || fail "HC_TERMINAL_ID is not set, run smith inside the Herdr app"
hc server status >/dev/null 2>&1 || fail "hc server status failed, is the Herdr app running?"
git rev-parse --show-toplevel >/dev/null 2>&1 || fail "not inside a git repository"

# Orchestrator, from its own hc record.
rec=$(hc get "$HC_TERMINAL_ID" --json 2>/dev/null) || fail "hc get $HC_TERMINAL_ID failed"
orch_kind=$(jq -r '.status.app // empty' <<<"$rec")
orch_space=$(jq -r '.labels["herdr.space"] // empty' <<<"$rec")
orch_tab=$(jq -r '.labels["herdr.tab"] // empty' <<<"$rec")
# A terminal without a space label is hidden in the app, and so would be every worker placed next to it.
[ -n "$orch_space" ] || fail "orchestrator terminal $HC_TERMINAL_ID has no herdr.space label, start smith from a tab in the Herdr app"

run_update '.backend = "herdr-app"'
recorded=$(jq -r '.orchestrator.address // empty' "$RUN/run.json")
# Same terminal as before: refresh its record (older runs have no tab). Another terminal: only with --resume.
if [ "$resume" = 1 ] || [ -z "$recorded" ] || [ "$recorded" = "$HC_TERMINAL_ID" ]; then
	run_update '.orchestrator = {address: $a, kind: $k, space: $s, tab: $t}' \
		--arg a "$HC_TERMINAL_ID" --arg k "$orch_kind" --arg s "$orch_space" --arg t "$orch_tab"
fi

# Best effort: a failed rename only leaves the tab's old name.
if [ -n "$orch_tab" ] && ! rn=$(herdr-app do tab.rename --id "$orch_tab" --name "$(orch_label "$HC_TERMINAL_ID")" 2>&1); then
	echo "preflight.sh: tab.rename failed for $orch_tab: $rn" >&2
fi

jq -c 'del(.tasks)' "$RUN/run.json"
