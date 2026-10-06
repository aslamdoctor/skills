#!/usr/bin/env bash
# Create (or reuse) a worktree for one task, open a background Herdr tab in it and start a worker agent.
# Usage: RUN=<run dir> spawn.sh <id> <branch> <base-ref> [--kind <kind>] [--resume <session-id>] [--cmd "<launch command>"]
#   id         issue number or short slug; the worker is named i<id>
#   branch     branch to create (reused if it already exists locally)
#   base-ref   ref to cut a new branch from: origin/<base> or origin/<parent-branch> for stacked work
#   --kind     any Herdr agent kind (see agents.tsv); default $AGENT_KIND or claude
#   --resume   start the agent in its previous conversation (resume args come from agents.tsv)
#   --cmd      tier D: an agent Herdr doesn't recognize. Launched with `pane run`; kind is recorded as custom
# Env: WT_ROOT (default $HOME/<repo>-wt). Run inside the repo, in a Herdr pane.
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
repo_root=$(git rev-parse --show-toplevel)
root=${WT_ROOT:-"$HOME/$(basename "$repo_root")-wt"}
wt="$root/$branch"
agent="i$id"

mkdir -p "$root"
if [ ! -d "$wt" ]; then
	git -C "$repo_root" fetch -q origin
	if git -C "$repo_root" show-ref -q --verify "refs/heads/$branch"; then
		git -C "$repo_root" worktree add -q "$wt" "$branch"
	else
		git -C "$repo_root" worktree add -q -b "$branch" "$wt" "$base"
		# Don't track the base ref, so a bare `git push` can't hit it.
		git -C "$wt" branch --unset-upstream 2>/dev/null || true
	fi
fi

tab_json=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$wt" --label "#$id" --no-focus)
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

herdr pane report-metadata "$pane" --source smith --title "#$id" \
	--state-label "working=#$id working" --token "gate=started" >/dev/null 2>&1 || true

run_update '.tasks[$id] = ((.tasks[$id] // {}) + {id:$id, agent:$agent, kind:$kind, cmd:$cmd, branch:$branch, base:$base, worktree:$wt, tab:$tab, pane:$pane, session:$session, updated:$now}) | .tasks[$id].gate //= "started"' \
	--arg id "$id" --arg agent "$agent" --arg kind "$kind" --arg cmd "$cmd" --arg branch "$branch" --arg base "$base" \
	--arg wt "$wt" --arg tab "$tab" --arg pane "$pane" --arg session "$session" --arg now "$(now)"

jq -c --arg id "$id" --arg status "$status" '.tasks[$id] + {status:$status}' "$RUN/run.json"
