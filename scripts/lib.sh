#!/usr/bin/env bash
# Shared helpers. Source it: . "$(dirname "$0")/lib.sh"
# Every script needs RUN=<run dir> (holds run.json and gates/<id>.md).

: "${RUN:?set RUN to the run directory, e.g. ~/.agent-smith/runs/<repo>-<date>}"
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$RUN/gates"
[ -f "$RUN/run.json" ] || echo '{"tasks":{}}' >"$RUN/run.json"

# Run a jq filter against run.json under a lock (workers write concurrently).
# Usage: run_update '<jq filter>' [jq args...]
run_update() {
	local filter=$1; shift
	local lock="$RUN/.lock" tries=0
	until mkdir "$lock" 2>/dev/null; do
		tries=$((tries + 1)); [ $tries -gt 50 ] && { echo "run.json lock stuck: $lock" >&2; return 1; }
		sleep 0.1
	done
	jq "$@" "$filter" "$RUN/run.json" >"$RUN/run.json.tmp" && mv "$RUN/run.json.tmp" "$RUN/run.json"
	rmdir "$lock"
}

task_field() { jq -r --arg id "$1" ".tasks[\$id].$2 // empty" "$RUN/run.json"; }

# Column of agents.tsv for a kind: agent_info <kind> <integration|resume|transcript>. Prints "-" if unknown.
agent_info() {
	local col
	case $2 in integration) col=2 ;; resume) col=3 ;; transcript) col=4 ;; esac
	awk -F'\t' -v k="$1" -v c="$col" '$1 == k { print $c; found = 1 } END { if (!found) print "-" }' "$LIB_DIR/agents.tsv"
}

# Both never fail (scripts run with set -e) and print "gone" / "" when the agent isn't found.
agent_state() {
	local s
	s=$(herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null) || true
	echo "${s:-gone}"
}

agent_session() {
	herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true
}

# For custom (tier D) workers Herdr reports no agent; "alive" means the pane still exists.
pane_alive() { herdr pane get "$1" >/dev/null 2>&1; }

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }
