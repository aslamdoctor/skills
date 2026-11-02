#!/usr/bin/env bash
# herdr-app worker spawn. Creates (or reuses) a worktree, starts the worker with `hc run`, renames its tab.
# Usage: RUN=<run dir> spawn.sh <id> <branch> <base-ref> [--kind <kind>] [--resume <session>] < prompt.txt
#   The prompt comes from stdin (may be empty with --resume) and becomes one argv word.
#   kind default: $AGENT_KIND or claude. Launch templates live in launch.tsv.
# Env: WT_ROOT (default $HOME/<repo>-wt), SPAWN_WAIT (default 60 s), SPAWN_INTERVAL (default 2 s), LAUNCH_TSV (test override).
# Records the task in run.json and prints it, plus status, as one JSON line.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$here/../lib.sh"

app_do() { herdr-app "do" "$@"; }
# Non-fatal problems: printed to stderr and repeated in the "warnings" array of the output line.
warnings=()
warn() {
	warnings+=("$1")
	jq -nc --arg w "$1" '{warning:$w}' >&2
}

id=$1; branch=$2; base=$3; shift 3
kind=${AGENT_KIND:-claude}; resume=""
while [ $# -gt 0 ]; do
	case $1 in
		--kind) kind=$2; shift 2 ;;
		--resume) resume=$2; shift 2 ;;
		*) echo "{\"error\":\"unknown option $1\"}"; exit 2 ;;
	esac
done

prompt=$(cat)
agent=$(new_agent_name "$id")

# 1. Refuse to respawn a live worker.
recorded=$(worker_hc "$id")
for target in "$recorded" "$agent"; do
	if [ "$(hc_state "$target")" != gone ]; then
		jq -nc --arg a "$agent" --arg t "$target" '{error:"worker \($a) is still live (\($t)); adopt it, don'"'"'t respawn"}'
		exit 3
	fi
done

# 2. Worktree (same rules as scripts/spawn.sh).
repo_root=$(git rev-parse --show-toplevel)
root=${WT_ROOT:-"$HOME/$(basename "$repo_root")-wt"}
wt="$root/$branch"
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

# 3-4. Launch template and session.
row=$(awk -F'\t' -v k="$kind" '$1 == k { print; exit }' "${LAUNCH_TSV:-$here/launch.tsv}")
if [ -z "$row" ]; then
	warn "kind $kind is untested on herdr-app"
	fresh_t="$kind {prompt}"; resume_t="$kind {prompt}"
else
	IFS=$'\t' read -r _ fresh_t resume_t <<<"$row"
fi

session=""
if [ -n "$resume" ]; then
	if [ "$resume_t" = - ]; then
		warn "kind $kind has no resume support; starting fresh, send a catch-up prompt"
		tmpl=$fresh_t
	else
		tmpl=$resume_t; session=$resume
	fi
else
	tmpl=$fresh_t
fi
if [ -z "$session" ] && [[ $tmpl == *"{session}"* ]]; then
	session=$(uuidgen | tr 'A-Z' 'a-z')
fi

argv=()
read -ra words <<<"$tmpl"
for w in "${words[@]}"; do
	case $w in
		'{prompt}') [ -n "$prompt" ] && argv+=("$prompt") ;;
		*) argv+=("${w//\{session\}/$session}") ;;
	esac
done

space=$(jq -r '.space // empty' "$RUN/run.json")
orch_space=$(jq -r '.orchestrator.space // empty' "$RUN/run.json")

# 5. Start the worker.
out=$(hc run --bg --json --outlive-parent --name "$agent" --cwd "$wt" \
	--label "herdr.space=$space" --label "herdr.tab=$agent" \
	--label "smith.run=$(basename "$RUN")" --label "smith.task=$id" \
	-- "${argv[@]}") || { jq -nc --arg o "$out" '{error:"hc run failed: \($o)"}'; exit 1; }
addr=$(jq -r '.address // empty' <<<"$out")
[ -n "$addr" ] || { jq -nc --arg o "$out" '{error:"hc run returned no address: \($o)"}'; exit 1; }

# 6. Rename its tab, then hand focus back.
# The terminal can take a moment to show up in `ls`, so retry.
tab=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	tab=$(herdr-app ls 2>/dev/null | jq -r --arg a "$addr" '[.spaces[]?.tabs[]? | select(any(.terminals[]?; .terminal == $a)) | .id][0] // empty' 2>/dev/null) || true
	[ -n "$tab" ] && break
	sleep "${SPAWN_INTERVAL:-2}"
done
if [ -z "$tab" ]; then
	warn "tab for $addr not found in herdr-app ls; it was not renamed"
elif ! rn=$(app_do tab.rename --id "$tab" --name "$(worker_label "$id")" 2>&1); then
	warn "tab.rename failed for $tab: $rn"
fi
if [ -z "$orch_space" ]; then
	warn "no orchestrator space recorded; focus was not handed back"
elif ! sel=$(app_do space.select --id "$orch_space" 2>&1); then
	warn "space.select $orch_space failed, focus may still be on the worker: $sel"
fi

# 7. Confirm the kickoff arrived (it is the agent's own argv, so look at its state).
status=not_started
waited=0
while :; do
	st=$(hc_state "$addr")
	case $st in
		working|blocked) status=$st; break ;;
		# done/error before any turn: the worker is not coming up, report it as gone.
		gone|done|error) status=gone; break ;;
	esac
	if [ "$(hc_turn "$addr")" -gt 0 ] 2>/dev/null; then status=working; break; fi
	[ "$waited" -ge "${SPAWN_WAIT:-60}" ] && break
	sleep "${SPAWN_INTERVAL:-2}"; waited=$((waited + ${SPAWN_INTERVAL:-2}))
done

# agy keeps a map of working directory to its last conversation id. The worktree is unique to this
# task, so the entry is ours. It only appears once the conversation starts (after the trust dialog).
if [ "$kind" = agy ] && [ -z "$session" ]; then
	last="$HOME/.gemini/antigravity-cli/cache/last_conversations.json"
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		session=$(jq -r --arg d "$wt" '.[$d] // empty' "$last" 2>/dev/null) || session=""
		[ -n "$session" ] && break
		sleep "${SPAWN_INTERVAL:-2}"
	done
	[ -n "$session" ] || warn "no agy conversation id; resume will need a catch-up prompt"
fi

# 8. Record.
run_update '.tasks[$id] = ((.tasks[$id] // {}) + {id:$id, agent:$agent, hc:$hc, kind:$kind, branch:$branch, base:$base, worktree:$wt, space:$space, tab:$tab, session:$session, needs_you:false, gate_sent:true, reported:{}, updated:$now}) | .tasks[$id].gate //= "started"' \
	--arg id "$id" --arg agent "$agent" --arg hc "$addr" --arg kind "$kind" --arg branch "$branch" --arg base "$base" \
	--arg wt "$wt" --arg space "$space" --arg tab "$tab" --arg session "$session" --arg now "$(now)"

jq -c --arg id "$id" --arg status "$status" '.tasks[$id] + {status:$status, warnings:$ARGS.positional}' "$RUN/run.json" --args ${warnings[@]+"${warnings[@]}"}
