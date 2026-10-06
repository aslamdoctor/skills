---
name: agent-smith
description: Orchestrate several coding tasks in parallel from one Herdr pane, with any coding agent (Claude Code, Codex, Antigravity, Grok, OpenCode, Pi, Copilot, Cursor and the rest Herdr supports, or any other CLI agent). Each task gets its own git worktree, a background Herdr tab and a worker agent. Workers can be different kinds in one run. They stop at gates (spec, implemented, pr), show their gate in the Herdr sidebar and report back to this orchestrator session, which relays the user's decisions. A run is saved to disk, so workers can be resumed with their full conversation later. Works on any git project. Use when the user wants to work on multiple issues or tasks at once, e.g. "work on 101 and 102 in parallel", "spin up workers for these issues", "agent-smith 101 102 103", "/agent-smith", "use codex workers", "pick N issues and run them in parallel", or "resume yesterday's agent-smith run". Requires Herdr (HERDR_ENV=1).
---

# Agent Smith

This session is the orchestrator. It never writes task code itself. It creates workers, sends them prompts, watches them, and brings their questions to the user. Workers do the work in their own worktree and tab.

`S` below means this skill's `scripts/` directory. Every script needs the `RUN` env var. Prompt templates are in `references/prompts.md`. Read `references/gotchas.md` before the first run in a session.

## Agent support

Worker kinds come from Herdr, and `S/agents.tsv` maps each kind to its integration and resume arguments. Tasks in one run can use different kinds.

| Tier | Kinds | What works |
|---|---|---|
| A | claude, codex, agy, grok, pi, opencode, copilot, cursor, devin, droid, kimi, qodercli, qwen, letta, hermes, mastracode, kilo, omp, with the Herdr integration installed | Everything, including resume with full context |
| B | The same kinds without the integration, plus amp, kiro, maki, muse | Start, prompt, state and watchers. No session ID, so resume falls back to a catch-up prompt |
| C | gemini, cline | Like B, but state detection is less tested. Gate lines still drive the run |
| D | Any CLI agent Herdr doesn't recognize | `spawn.sh --cmd "<launch>"`. Prompts are pasted into the pane, and the watcher uses gate lines plus an unchanged screen for STOPPED. The worker must be able to run a shell command |

The orchestrator works the same way. Its wake-up mode depends on its own kind (see section 3).

## 0. Preflight

1. Check `test "${HERDR_ENV:-}" = 1`. If it fails, say Agent Smith needs to run inside a Herdr pane and stop. Load the `herdr` skill if one is available.
2. Find your own kind: `herdr agent get "$HERDR_PANE_ID" | jq -r .result.agent.agent`. This picks the watch mode in section 3.
3. Pick the worker kind (or kinds) with the user. The default is your own kind. For each kind, check `herdr integration status`, and offer `herdr integration install <integration>` (the integration name is in `agents.tsv`) if it isn't `current`.
4. Choose the run directory: `RUN=~/.agent-smith/runs/<repo>-<YYYY-MM-DD>`. Reuse it if it exists for today. It holds `run.json` (one record per task) and `gates/<id>.md` (the gate log).
5. If a project or global rule forbids worktrees, tell the user this skill needs them and ask once. Record a scoped exception in your memory or notes if they agree.

## 1. Pick the tasks and the setup

**Tasks.** Use the IDs the user gave. If they asked you to choose ("pick 3"), list open candidates (e.g. with `gh issue list`), read each one's blockers and dependencies, and choose tasks that can run in parallel without depending on each other's unmerged code. Show a table of the choices and why.

**Setup.** Detect each value from the repo's instruction files (AGENTS.md, CLAUDE.md, GEMINI.md, .cursor/rules and similar), your memory or notes, and recent branches and PRs (`gh pr list --state all --limit 10 --json headRefName,baseRefName`). Ask only for what you can't find:

| Setting | Where to look |
|---|---|
| Base ref for new branches | Project rules, epic or feature-branch notes, recent PR bases |
| PR base | Same as above (often the base ref's branch) |
| Branch name format | Branch-creation rules, recent branch names |
| Commit format | Commit workflow rules |
| Ship flow | A ship skill, or the project's PR rules |
| Test and lint commands | Instruction files, package.json / composer.json / Makefile |
| Worker kind per task | Default: your own kind |
| Worktree root | Default `~/<repo>-wt/<branch>` (override with `WT_ROOT`) |
| Gates | Default `spec / implemented / pr` |

Show the detected setup as one table and confirm it with the user before spawning anything. Use your structured question tool if you have one, otherwise ask in plain text.

**Skills and slash commands differ between agents.** When a step uses a skill (a ship or fix-PR flow), give workers the skill's file path ("follow `<path>/SKILL.md`") rather than a slash command, unless the worker kind is known to load that skill itself.

**Dependencies within the run.** If task B needs task A's unmerged code, cut B from A's branch (a stacked branch). Otherwise cut every task from the base ref. When two tasks will touch the same shared entry (a docs section, error-code list or registry), decide now which one owns it.

## 2. Spawn workers

```bash
RUN=<run> S/spawn.sh <id> <branch> <base-ref> [--kind <kind>]
RUN=<run> S/spawn.sh <id> <branch> <base-ref> --cmd "<launch command>"   # tier D
```

spawn.sh:
- creates or reuses the worktree
- opens a background tab and starts the worker `i<id>`
- records the task in `run.json` (kind, pane, tab, session ID if one is reported)
- labels the pane `#<id>` in the sidebar
- prints the task record

If the status isn't `idle`, read the screen. New worktree paths often bring up a first-run dialog (folder trust, login, model picker). Bring it to the user before answering it.

Send each worker the **Kickoff** prompt from `references/prompts.md` through stdin. It tells the worker to mark each gate with `mark.sh`.

```bash
RUN=<run> S/send.sh <id> <<'EOF'
...kickoff text...
EOF
```

Treat a non-zero exit as "not delivered": read the screen and resend. Never assume a prompt landed.

## 3. Watch

After every prompt that starts work, arm one watcher per worker. Choose the mode from your own kind:

- **Your agent can run a command in the background and gets re-invoked when it exits** (Claude Code's `run_in_background`, for example): run `RUN=<run> S/watch.sh <id>` that way.
- **Any other orchestrator:** run the watcher detached with notify mode, so it wakes you with a Herdr prompt:
  ```bash
  nohup env RUN=<run> S/watch.sh <id> --notify "$HERDR_PANE_ID" >/dev/null 2>&1 &
  ```
  The report arrives as a new message starting `[agent-smith]`. If you're showing the user a dialog at the time, the watcher waits for it to close rather than typing into it.

The watcher reports one of four things:
- **GATE:** a new gate line.
- **BLOCKED:** a dialog that stays up.
- **STOPPED:** no gate, and idle (or an unchanged screen for tier D) for 15 minutes. Change this with `--grace <min>`.
- **GONE:** the agent exited.

It also shows a Herdr toast with a sound. A worker that goes idle while its own background shell runs (bot review, CI) doesn't trigger the watcher.

## 4. When a watcher reports

1. Read the worker's screen: `herdr agent read i<id> --source recent-unwrapped --lines 50`, or `herdr pane read <pane> ...` for tier D. If the reply isn't there (it was drawn on the alternate screen), use the transcript path for that kind in `agents.tsv`. Otherwise, ask the worker to write its answer to a file and read the file.
2. Report to the user based on what fired:
   - **GATE spec:** the approach in a few lines, deviations from the task, and the worker's open questions as a table with *your* recommendation for each. Point out conflicts with sibling workers (same method, same docs section).
   - **GATE implemented:** the commit hash, message and changed files (in the user's commit-report format if they have one), test and lint results, anything the worker changed from the approved spec, and new shared-environment problems.
   - **GATE question / pr:** the exact question or draft text (thread replies, issue comments), verbatim.
   - **BLOCKED:** what the dialog asks.
   - **STOPPED / GONE:** what the screen shows, and whether to nudge, resume or drop the task.
3. Ask for decisions, batching pending decisions across workers. Then relay them with send.sh, quoting the user's words (see "Relaying answers" in `references/prompts.md`), and re-arm the watcher.
4. Before you say "shipped", check the PR yourself: base, reviewers, labels, resolved threads and file list.

Keep a status table in every report. `RUN=<run> S/board.sh` prints one from `run.json` and the live states.

## 5. Ship

Only on the user's go-ahead per task, using the **Ship** template. Pre-answer the ship flow's routine questions with the user's standing answers (for example: local automated QA No because the dev site points at the main checkout, staging skipped from a worktree, default reviewer). Ask once whether those answers apply to all workers in the run.

Ship stacked tasks as stacked PRs (see **Stacked ship** in the templates). After a parent PR merges, the child needs a rebase and its PR switched to the real base.

## 6. Wrap up

- Close only the tabs this run created (from `run.json`), and only when the user agrees: `herdr tab close <tab>`. Keep the worktrees and `run.json` until the PRs merge, since review fixes resume from them.
- Stop any detached watchers you started for closed tasks (`pkill -f "watch.sh <id>"`).
- When everything has merged, offer to remove the worktrees (`git worktree remove <path>`), delete the local branches and archive the run directory.

## 7. Resume a run

For review feedback, a follow-up or a session that lost track of a run ("resume yesterday's agent-smith run"):

1. Find the run with `ls -t ~/.agent-smith/runs/` and read its `run.json`. Show `RUN=<run> S/board.sh`.
2. For each task to resume, start the worker in its old conversation, with the kind recorded for it:
   ```bash
   RUN=<run> S/spawn.sh <id> <branch> <base> --kind <kind> --resume <session>
   ```
   All values come from `run.json`, and the resume arguments for that kind come from `agents.tsv`. The worker keeps its spec, the user's decisions and its commits in context. If the task has no session ID, or the kind has no resume support (or is tier D), spawn it fresh and send a short catch-up prompt (issue, PR, current gate, decisions so far).
3. Send the follow-up prompt, e.g. "<reviewer> reviewed PR <n>. Follow <fix-PR skill path>, stop with the fixes and draft replies for approval." Then watch as usual.
4. Stacked children: once the parent's fixes are pushed, tell the child to rebase onto the parent branch. After the parent merges, rebase it onto the real base and switch the PR's base.

## Rules

- The user approves every spec, every ship and every text posted to GitHub or anywhere else. Workers never decide for the user, and neither do you. Relay, recommend, wait.
- Workers stop at each gate and ask in plain text. The kickoff tells them this. If one opens an interactive dialog anyway, `send.sh` presses Esc before sending the answer.
- Never focus or close tabs you didn't create. Never stop the Herdr server.
- Your own replies to the user follow the user's normal reporting rules.

## Install for other agents

The skill is a plain folder in the Agent Skills format. Symlink it into each agent's skills directory so it updates in one place:

```bash
ln -s ~/.claude/skills/agent-smith ~/.agents/skills/agent-smith   # shared dir (Codex, OpenCode, Pi and others read it)
ln -s ~/.claude/skills/agent-smith ~/.codex/skills/agent-smith    # Codex
```

For an agent without skill support, point it at this file: "Read ~/.claude/skills/agent-smith/SKILL.md and follow it."
