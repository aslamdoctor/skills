#!/usr/bin/env bash
# Create (or reuse) a worktree for one task, open a background Herdr tab in it and start a worker agent.
# Usage: RUN=<run dir> spawn.sh <id> <branch> <base-ref> [--kind <kind>] [--resume <session-id>] [--cmd "<launch command>"]
#   id         issue number, short slug, or PR (number or URL) for a review; the worker is code-<id> or review-<id>
#   branch     branch to create (reused if it already exists locally)
#   base-ref   ref to cut a new branch from: origin/<base> or origin/<parent-branch> for stacked work
#              branch and base-ref '-': a review task. No worktree; the worker runs in the repo root.
#   --kind     any Herdr agent kind (see agents.tsv); default $AGENT_KIND or claude
#   --resume   start the agent in its previous conversation (resume args come from agents.tsv)
#   --cmd      tier D: an agent Herdr doesn't recognize. Launched with `pane run`; kind is recorded as custom
# Env: WT_ROOT (default: run.json wt_root, else $HOME/<repo>-wt). Run in a Herdr pane, inside the repo
# for a new run; later spawns use run.json repo_root.
# Records the task in run.json and prints it as one JSON line.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

id=$1; branch=$2; base=$3; shift 3
kind=${AGENT_KIND:-claude}; resume=""; cmd=""
while [ $# -gt 0 ]; do
	case $1 in
		--kind) kind=$2; shift 2 ;;
		--resume) resume=$2; shift 2 ;;
		--cmd) cmd=$2; kind=custom; shift 2 ;;
		*) echo "{\"error\":\"unknown option $1\"}"; exit 2 ;;
	esac
done

[ "${HERDR_ENV:-}" = 1 ] || { echo '{"error":"not inside a Herdr pane"}'; exit 1; }
type=code
[ "$branch" = - ] && { type=review; branch=""; base=""; }
agent=$(new_agent_name "$id" "$type"); label=$agent

# A resume reuses the recorded worktree from any directory (lib.sh resolve_worktree).
resolve_worktree "$id" "$type" "$branch" || exit 1
if [ "$type" = code ]; then ensure_worktree "$branch" "$base"; fi

tab_json=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$wt" --label "$label" --no-focus)
tab=$(jq -r '.result.tab.tab_id' <<<"$tab_json")
pane=$(jq -r '.result.root_pane.pane_id' <<<"$tab_json")
session=""

if [ "$kind" = custom ]; then
	herdr pane run "$pane" "$cmd" >/dev/null
	sleep 3
	status=$(pane_alive "$pane" && echo started || echo start_failed)
else
	args=()
	if [ -n "$resume" ]; then
		tmpl=$(agent_info "$kind" resume)
		if [ "$tmpl" = - ]; then
			echo "{\"warning\":\"kind $kind has no resume support; starting fresh, send a catch-up prompt\"}" >&2
		else
			read -ra parts <<<"${tmpl//\{id\}/$resume}"
			args=(-- "${parts[@]}")
		fi
	fi
	start_json=$(herdr agent start "$agent" --kind "$kind" --pane "$pane" --timeout 90000 "${args[@]}" 2>&1 || true)
	status=$(jq -r '.result.agent.agent_status // .error.code // "unknown"' <<<"$start_json" 2>/dev/null || echo start_failed)

	# Integrations report the session id shortly after start. Kinds without one never do.
	if [ "$(agent_info "$kind" integration)" != - ]; then
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			session=$(agent_session "$agent"); [ -n "$session" ] && break; sleep 1
		done
	fi
	[ -z "$session" ] && session=$resume
fi

herdr pane report-metadata "$pane" --source smith --title "$label" \
	--state-label "working=$label working" --token "gate=started" >/dev/null 2>&1 || true

run_update '.tasks[$id] = ((.tasks[$id] // {}) + {id:$id, type:$type, agent:$agent, kind:$kind, cmd:$cmd, branch:$branch, base:$base, worktree:$wt, tab:$tab, pane:$pane, session:$session, updated:$now}) | del(.tasks[$id].closed) | del(.cleanup_offered) | .tasks[$id].gate //= "started"' \
	--arg id "$id" --arg type "$type" --arg agent "$agent" --arg kind "$kind" --arg cmd "$cmd" --arg branch "$branch" --arg base "$base" \
	--arg wt "$wt" --arg tab "$tab" --arg pane "$pane" --arg session "$session" --arg now "$(now)"

jq -c --arg id "$id" --arg status "$status" '.tasks[$id] + {status:$status}' "$RUN/run.json"
