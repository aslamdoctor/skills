#!/usr/bin/env bash
# Shared helpers. Source it: . "$(dirname "$0")/lib.sh"
# Every script needs RUN=<run dir> (holds run.json and gates/<id>.md).

: "${RUN:?set RUN to the run directory, e.g. ~/.smith/runs/<repo>-<date>}"
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

# Workers are named after their task type and task: code-<id> for an issue or slug, review-<id> for a PR.
# Herdr agent names must be lowercase (a-z, 0-9, '-', '_', max 32). The same name is the address and
# what the sidebar, tabs and messages show.
# The orchestrator's own tab is "SMITH-ORC<n>" (orch_label), where <n> is its terminal address from the
# first digit on, uppercased (t7 -> SMITH-ORC7), so it stands out from its workers.
# A PR URL (a PR in another repo) shortens to <repo>-<number>, so two URLs don't truncate to the same name.
short_id() { if [[ $1 =~ ^https?://[^/]+/[^/]+/([^/]+)/pull/([0-9]+) ]]; then echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"; else echo "$1"; fi; }
# new_agent_name <id> [code|review]
new_agent_name() { local n; n=$(printf '%s-%s' "${2:-code}" "$(short_id "$1")" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-'); echo "${n:0:32}"; }
worker_label() { worker_agent "$1"; }
# Task ids can be PR URLs, so any file named after a task uses file_key (no slashes).
file_key() { short_id "$1" | tr '/' '-'; }
gate_log() { echo "$RUN/gates/$(file_key "$1").md"; }
orch_label() { local n=${1#"${1%%[0-9]*}"}; echo "SMITH-ORC$(printf '%s' "${n:-$1}" | tr 'a-z' 'A-Z')"; }
# The address recorded in run.json, so runs from before the rename (smith-<id>, i<id>) keep working.
worker_agent() { local a; a=$(task_field "$1" agent); echo "${a:-$(new_agent_name "$1" "$(task_field "$1" type)")}"; }

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

# herdr-app backend. run.json has "backend": "herdr-app"; no field means the Herdr TUI.
run_backend() { jq -r '.backend // "herdr"' "$RUN/run.json" 2>/dev/null || echo herdr; }

# The hc address of a worker, else its agent name (hc accepts both).
worker_hc() { local a; a=$(task_field "$1" hc); echo "${a:-$(worker_agent "$1")}"; }

# working|idle|done|blocked|error|gone. Never fails: anything unexpected is "gone".
hc_state() {
	local s
	s=$(hc get "$1" --json 2>/dev/null | jq -r 'if .state != "live" then "gone" else (.status.state // "idle") end' 2>/dev/null) || true
	echo "${s:-gone}"
}

hc_status_ms() {
	local v
	v=$(hc get "$1" --json 2>/dev/null | jq -r '.status_ms // empty' 2>/dev/null) || true
	echo "${v:-0}"
}

hc_turn() {
	local v
	v=$(hc get "$1" --json 2>/dev/null | jq -r '.turn // empty' 2>/dev/null) || true
	echo "${v:-0}"
}

# Live state of a task's worker on either backend. Never fails; "gone" when it can't be found.
task_state() {
	if [ "$(run_backend)" = herdr-app ]; then hc_state "$(worker_hc "$1")"; return; fi
	if [ "$(task_field "$1" kind)" = custom ]; then
		if pane_alive "$(task_field "$1" pane)"; then echo alive; else echo gone; fi
	else
		agent_state "$(worker_agent "$1")"
	fi
}

# The last gate of a task type: code tasks end at pr, review tasks at posted.
final_gate() { if [ "${1:-code}" = review ]; then echo posted; else echo pr; fi; }

# Pid file of the detached watcher for one task (Herdr TUI).
watch_pid_file() { echo "$RUN/watch-$(file_key "$1").pid"; }

# Stop a watcher by its pid file, only if that pid is still a watch.sh process. Never fails.
stop_watcher() {
	local f=$1 pid
	[ -f "$f" ] || return 0
	pid=$(cat "$f" 2>/dev/null) || true
	if [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | rg -q 'watch\.sh'; then
		kill "$pid" 2>/dev/null || true
	fi
	rm -f "$f"
}

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Main checkout of the repo at <dir> (default: the current directory), also when <dir> is a worktree.
# Prints nothing outside a git repository. Never fails.
main_checkout() {
	local d
	d=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
	(cd "$(dirname "$d")" && pwd -P)
}

# Run dirs are named <repo>-<YYYY-MM-DD>[...]. Refuse a repo whose name doesn't match, so a script run
# from the wrong directory can't create worktrees in another repo. Other run dir names aren't checked.
check_run_repo() {
	local name
	name=$(basename "$RUN")
	if [[ $name =~ ^(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2} ]] && [ "${BASH_REMATCH[1]}" != "$(basename "$1")" ]; then
		jq -nc --arg r "$1" --arg n "$name" '{error:"run \($n) is not for repo \($r); cd into that run'"'"'s repo or set repo_root in run.json"}'
		return 1
	fi
}

# Where a task's worker runs. Sets the globals repo_root, wt_root and wt, and records repo_root and
# wt_root in run.json, so later spawns and resumes don't depend on the current directory.
# Usage: resolve_worktree <id> <code|review> <branch>
# repo_root: run.json, else the main checkout of the task's recorded worktree, else the current directory
# (checked against the run dir name). wt_root: $WT_ROOT, else run.json, else the recorded worktree's
# parent, else $HOME/<repo>-wt. wt: the recorded worktree when it still exists on <branch>.
resolve_worktree() {
	local id=$1 type=$2 branch=$3 recorded on
	recorded=$(task_field "$id" worktree)
	if [ "$type" = code ] && [ -n "$recorded" ] && [ -d "$recorded" ]; then
		on=$(git -C "$recorded" branch --show-current 2>/dev/null) || on=""
		[ "$on" = "$branch" ] || recorded=""
	else
		recorded=""
	fi

	repo_root=$(jq -r '.repo_root // empty' "$RUN/run.json")
	if [ -n "$repo_root" ] && [ ! -d "$repo_root" ]; then repo_root=""; fi
	if [ -z "$repo_root" ] && [ -n "$recorded" ]; then repo_root=$(main_checkout "$recorded"); fi
	if [ -z "$repo_root" ]; then
		repo_root=$(main_checkout)
		[ -n "$repo_root" ] || { echo '{"error":"not inside a git repository and run.json has no repo_root"}'; return 1; }
		check_run_repo "$repo_root" || return 1
	fi

	wt_root=${WT_ROOT:-$(jq -r '.wt_root // empty' "$RUN/run.json")}
	if [ -z "$wt_root" ] && [ -n "$recorded" ] && [[ $recorded == */"$branch" ]]; then wt_root=${recorded%/"$branch"}; fi
	[ -n "$wt_root" ] || wt_root="$HOME/$(basename "$repo_root")-wt"

	if [ "$type" = review ]; then wt=$repo_root
	elif [ -n "$recorded" ]; then wt=$recorded
	else wt="$wt_root/$branch"; fi

	run_update '.repo_root = $r | .wt_root = $w' --arg r "$repo_root" --arg w "$wt_root"
}

# Create the worktree for a code task unless it exists. Needs resolve_worktree first.
ensure_worktree() {
	local branch=$1 base=$2
	[ -d "$wt" ] && return 0
	mkdir -p "$wt_root"
	git -C "$repo_root" fetch -q origin
	if git -C "$repo_root" show-ref -q --verify "refs/heads/$branch"; then
		git -C "$repo_root" worktree add -q "$wt" "$branch"
	else
		git -C "$repo_root" worktree add -q -b "$branch" "$wt" "$base"
		# Don't track the base ref, so a bare `git push` can't hit it.
		git -C "$wt" branch --unset-upstream 2>/dev/null || true
	fi
}

# Plain `hc send` waits for a person to pause and has no timeout of its own, so bound it.
# Usage: send_bounded <seconds> <hc send args...>. Never add --force: it would type into a blocked dialog.
send_bounded() {
	local secs=$1 pid watcher rc
	shift
	hc send "$@" >/dev/null 2>&1 &
	pid=$!
	# The watcher traps TERM so that stopping it also stops its own sleep (no orphan on success).
	(
		trap '[ -n "${sp:-}" ] && kill "$sp" 2>/dev/null; exit 0' TERM
		sleep "$secs" & sp=$!
		wait "$sp"
		kill "$pid" 2>/dev/null
	) >/dev/null 2>&1 &
	watcher=$!
	wait "$pid" 2>/dev/null; rc=$?
	kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
	return $rc
}
