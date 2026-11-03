---
name: smith
description: Orchestrate several coding tasks or PR reviews in parallel from one Herdr pane or the Herdr app, with any coding agent (Claude Code, Codex, OpenCode, Pi, Cursor or any other CLI agent Herdr supports). Each issue gets its own git worktree, a background Herdr tab and a worker agent; each open PR gets a review worker in a tab of its own. Workers can be different kinds in one run. They stop at gates (spec, implemented, pr), show their gate in the Herdr sidebar and report back to this orchestrator session, which relays the user's decisions. A run is saved to disk, so workers can be resumed with their full conversation later. Use when the user wants to work on multiple issues or tasks at once, e.g. "work on 101 and 102 in parallel", "spin up workers for these issues", "smith 101 102 103", "/smith", "smith 5737 5760" with PR numbers to review them, "use codex workers", "pick N issues and run them in parallel", or "resume yesterday's smith run". Requires Herdr (HERDR_ENV=1) or the Herdr app (hc).
---

# Smith

This session is the orchestrator. It never writes task code itself. It creates workers, sends them prompts, watches them, and brings their questions to the user. Workers do the work in their own worktree and tab.

Workers are Smith's copies, named after their task: the worker for task 101 is `🤓 smith-101` in the sidebar, toasts and reports. This orchestrator's own tab is `😎 SMITH`.

Prompt templates are in `references/prompts.md`. Backend-specific steps are in `references/<backend>.md`; this file points at their sections as "`references/<backend>.md` § <name>".

## 0. Pick the backend

| Condition | Backend |
|---|---|
| `HERDR_ENV=1` | herdr |
| `HC_TERMINAL_ID` set and `hc server status` succeeds | herdr-app |
| Both | Ask the user once which one to use |
| Neither | Say "smith needs a Herdr TUI pane or the Herdr app", and stop |

Read `references/<backend>.md` now and use its sections wherever this file says § <name>. Read `references/gotchas.md` (the Common section plus your backend's section) before the first run in a session.

## Agent support

See `references/<backend>.md` § Agent support. Worker kinds come from Herdr, and tasks in one run can use different kinds.

## 1. Preflight

1. Run `references/<backend>.md` § Preflight. It checks the environment, finds your own kind, settles worker kinds and creates or reuses the run directory `~/.smith/runs/<repo>-<YYYY-MM-DD>` (`-app` is added on herdr-app).
2. If a project or global rule forbids worktrees, tell the user this skill needs them and ask once. Record a scoped exception in your memory or notes if they agree.

## 2. Pick the tasks and the setup

**Tasks.** Use the IDs the user gave. Classify each ID before anything else, since a PR number and an issue number look the same:

| Check | Task type | Gates | Spawn |
|---|---|---|---|
| `gh pr view <id> --json state,author,url` succeeds and `state` is `OPEN` | review | `findings / posted` | `spawn.sh <id> - -` (no worktree, runs in the repo root), **Review kickoff** |
| Anything else (an issue, a slug, a merged or closed PR) | code | `spec / implemented / pr` | as below, **Kickoff** |

A full PR URL is a review task for that PR, even in another repo. Keep the URL as the task ID everywhere (`gh pr view <url>`, `spawn.sh <url> - -`, the kickoff, `send.sh`, `close.sh`): a bare number would point at this repo. Worker names shorten it to `<repo>-<number>`.

Show the type per ID in the setup table. A run can mix both types. If a code-task issue already has an open PR (`gh pr list --search "<id> in:title,body" --state open`), ask whether to review that PR, resume its worker for review fixes (§ 8), or start a fresh code task. If they asked you to choose ("pick 3"), list open candidates (e.g. with `gh issue list`), read each one's blockers and dependencies, and choose tasks that can run in parallel without depending on each other's unmerged code. Show a table of the choices and why.

**Setup.** Detect each value from the repo's instruction files (AGENTS.md, CLAUDE.md, GEMINI.md, .cursor/rules and similar), your memory or notes, and recent branches and PRs (`gh pr list --state all --limit 10 --json headRefName,baseRefName`). Ask only for what you can't find:

| Setting | Where to look |
|---|---|
| Base ref for new branches (code tasks) | Project rules, epic or feature-branch notes, recent PR bases |
| PR base | Same as above (often the base ref's branch) |
| Branch name format | Branch-creation rules, recent branch names |
| Commit format | Commit workflow rules |
| Ship flow | A ship skill, or the project's PR rules |
| Pre-ship review | A self-review or preflight skill, if the project has one (else none) |
| Review skill (review tasks) | A PR review skill for the project (e.g. thrive-review-pr), else a plain `gh pr diff` review with findings only |
| Test and lint commands | Instruction files, package.json / composer.json / Makefile |
| Worker kind per task | Your own kind |
| Worktree root | `~/<repo>-wt/<branch>` (override with `WT_ROOT`) |
| Gates | Default `spec / implemented / pr` |

Show the detected setup as one table and confirm it with the user before spawning anything. Use your structured question tool if you have one, otherwise ask in plain text.

**Skills and slash commands differ between agents.** When a step uses a skill (a ship or fix-PR flow), give workers the skill's file path ("follow `<path>/SKILL.md`") rather than a slash command, unless the worker kind is known to load that skill itself.

**Dependencies within the run.** If task B needs task A's unmerged code, cut B from A's branch (a stacked branch). Otherwise cut every task from the base ref. When two tasks will touch the same shared entry (a docs section, error-code list or registry), decide now which one owns it.

## 3. Spawn workers

Spawn each worker and deliver the **Kickoff** prompt (code tasks) or the **Review kickoff** (review tasks) from `references/prompts.md`, with your backend's gate instruction: `references/<backend>.md` § Spawn.

## 4. Watch

After every prompt that starts work, arm the watcher: `references/<backend>.md` § Watch. It reports one of:
- **GATE:** the worker reached a gate (spec, implemented, pr, or a question).
- **BLOCKED:** a dialog or escalation is waiting.
- **STOPPED:** no gate, and the worker has gone quiet.
- **GONE:** the agent exited.

## 5. When a watcher reports

1. Read the worker: `references/<backend>.md` § Read a worker.
2. Report to the user based on what fired:
   - **GATE spec:** the approach in a few lines, deviations from the task, and the worker's open questions as a table with *your* recommendation for each. Point out conflicts with sibling workers (same method, same docs section).
   - **GATE implemented:** the commit hash, message and changed files (in the user's commit-report format if they have one), test and lint results, anything the worker changed from the approved spec, and new shared-environment problems.
   - **GATE findings:** the worker's picker output verbatim (findings table with default picks, questions, coverage gaps), then ask for the picks and the post decision with the same options the review skill gives. Relay them with the **Review picks** template.
   - **GATE posted:** the review URL, or that it wasn't posted.
   - **GATE question / pr:** the exact question or draft text (thread replies, issue comments), verbatim.
   - **BLOCKED:** what the dialog asks.
   - **STOPPED / GONE:** what the screen shows, and whether to nudge, resume or drop the task.
3. Ask for decisions, batching pending decisions across workers. Then relay them: `references/<backend>.md` § Relay answers.
4. Before you say "shipped", check the PR yourself: base, reviewers, labels, resolved threads and file list.

Keep a status table in every report: `references/<backend>.md` § Board.

## 6. Ship

Code tasks only. Only on the user's go-ahead per task, using the **Ship** template. Pre-answer the ship flow's routine questions with the user's standing answers (for example: local automated QA No because the dev site points at the main checkout, staging skipped from a worktree, default reviewer). Ask once whether those answers apply to all workers in the run.

Ship stacked tasks as stacked PRs (see **Stacked ship** in the templates). After a parent PR merges, the child needs a rebase and its PR switched to the real base.

## 7. Wrap up

`references/<backend>.md` § Wrap up. Keep the worktrees and `run.json` until the PRs merge, since review fixes resume from them. Clean up only what this run created, and only when the user agrees. When everything has merged, offer to remove the worktrees, delete the local branches and archive the run directory.

## 8. Resume a run

For review feedback, a follow-up or a session that lost track of a run ("resume yesterday's smith run"). A resume skips § 1 to 3: no new run directory.

1. Find the run with `ls -t ~/.smith/runs/` and read its `run.json`. Resume a run only with its own backend (`run.json` `backend`, none = herdr). If it differs from the current one, say so and stop.
2. Restart or reuse each worker in its old conversation: `references/<backend>.md` § Resume. If that isn't possible, start a fresh worker and send a short catch-up prompt (issue, PR, current gate, decisions so far).
3. Send the follow-up prompt, e.g. "<reviewer> reviewed PR <n>. Follow <fix-PR skill path>, stop with the fixes and draft replies for approval." Then watch as usual.
4. Stacked children: once the parent's fixes are pushed, tell the child to rebase onto the parent branch. After the parent merges, rebase it onto the real base and switch the PR's base.

## Rules

- The user approves every spec, every ship and every text posted to GitHub or anywhere else. Workers never decide for the user, and neither do you. Relay, recommend, wait.
- Workers stop at each gate and ask in plain text, never through an interactive dialog. The kickoff tells them this.
- Never focus or close tabs, terminals or worktrees you didn't create. Never stop the Herdr server.
- Your own replies to the user follow the user's normal reporting rules.

## Install for other agents

The skill is a plain folder in the Agent Skills format. Symlink it into each agent's skills directory so it updates in one place:

```bash
ln -s ~/.claude/skills/smith ~/.agents/skills/smith   # shared dir (Codex, OpenCode, Pi and others read it)
ln -s ~/.claude/skills/smith ~/.codex/skills/smith    # Codex
```

For an agent without skill support, point it at this file: "Read ~/.claude/skills/smith/SKILL.md and follow it."
