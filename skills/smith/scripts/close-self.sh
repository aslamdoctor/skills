#!/usr/bin/env bash
# Closes the orchestrator's own tab once its current turn ends. `close.sh --all --self` starts it
# detached, so the orchestrator can still report what was closed before its tab goes.
# Usage: RUN=<run dir> close-self.sh <who> <tab>
#   herdr-app: <who> is the orchestrator's hc address; its terminal is killed and removed, then the tab closed.
#   herdr:     <who> is the orchestrator's pane id; the tab is closed.
# Gives up waiting after 10 minutes of the orchestrator still working, and closes anyway.
# Writes what happened to <run>/close-self.log.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

who=${1:?usage: close-self.sh <who> <tab>}
tab=${2:?usage: close-self.sh <who> <tab>}
backend=$(run_backend)
log="$RUN/close-self.log"

state() { if [ "$backend" = herdr-app ]; then hc_state "$who"; else agent_state "$who"; fi; }

# The turn that ran close.sh is still going: let it finish its report.
sleep 2
for _ in $(seq 1 600); do
	[ "$(state)" = working ] || break
	sleep 1
done
sleep 1

{
	echo "$(date '+%F %T') closing orchestrator $who, tab $tab ($backend)"
	if [ "$backend" = herdr-app ]; then
		hc kill "$who" 2>&1
		hc rm "$who" 2>&1
		herdr-app "do" tab.close --id "$tab" --confirmed true 2>&1
	else
		herdr tab close "$tab" 2>&1
	fi
} >>"$log"
run_update '.orchestrator.closed = true'
