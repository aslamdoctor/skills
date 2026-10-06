# Agent Smith

An agent skill for working on several coding tasks in parallel from one [Herdr](https://herdr.dev) pane.

You tell your agent which issues to work on. It becomes the orchestrator: each task gets its own git worktree, a background Herdr tab and a worker agent. Workers stop at gates (spec, implemented, PR) and report back. The orchestrator brings you their questions with a recommendation and relays your answers, so nothing is shipped or posted without your OK.

```
/agent-smith 101 102 103
```

## What you get

- Each task runs on its own branch in `~/<repo>-wt/<branch>`, so workers never touch each other's files or your main checkout.
- Workers write a spec and stop. After you approve it, they implement, commit and stop again. They ship only when you say so.
- A watcher per worker wakes the orchestrator when a gate is reached, a dialog is waiting, or a worker stops. A Herdr toast and sound tell you when you're needed.
- Each worker pane shows its task and gate (`#102 · spec`) in the Herdr sidebar.
- Workers can be Claude Code, Codex, Antigravity, Grok, OpenCode, Pi, Copilot, Cursor or any other agent Herdr supports. Other CLI agents work through a custom-command mode, and one run can mix agent kinds.
- A run is saved to `~/.agent-smith/runs/`. Workers can be restarted later in their original conversation, for example to handle review comments the next day.
- A task that depends on another task's unmerged branch is cut from that branch and shipped as a stacked PR.
- Base branch, branch naming, commit format, ship flow and test commands come from the repo's instruction files (AGENTS.md, CLAUDE.md and similar). You confirm them once per run.

## Requirements

- [Herdr](https://herdr.dev) 0.9 or newer, with the orchestrator running inside a Herdr pane
- `git`, `jq` and `bash`
- `gh` if you want the orchestrator to pick issues or open PRs
- At least one coding agent CLI. Install its Herdr integration (`herdr integration install <name>`) to get session resume

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill agent-smith
```

Or clone the [skills repo](https://github.com/aslamdoctor/skills) and symlink this folder into each agent's skills directory:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
ln -s ~/skills/skills/agent-smith ~/.claude/skills/agent-smith   # Claude Code
ln -s ~/skills/skills/agent-smith ~/.agents/skills/agent-smith   # shared location (Codex, OpenCode, Pi and others)
ln -s ~/skills/skills/agent-smith ~/.codex/skills/agent-smith    # Codex
```

For an agent without skill support, tell it: "Read ~/skills/skills/agent-smith/SKILL.md and follow it."

## Usage

Start your agent in a Herdr pane inside the repo, then ask for parallel work:

- `/agent-smith 101 102 103`
- "Work on 101 and 102 in parallel"
- "Pick 3 open issues that don't depend on each other and run them in parallel"
- "Use codex workers for these issues"
- "Resume yesterday's agent-smith run"

A typical run:

1. The orchestrator detects the project setup and shows it as a table to confirm.
2. It spawns one worker per task, then sends each a kickoff prompt.
3. Each worker writes a spec and stops. You get the approach and its open questions, with a recommendation for each.
4. After you approve, the worker implements, runs lint and tests, commits and stops.
5. When you say ship, the worker pushes and opens the PR using your project's ship flow. Review-bot replies and comments come to you for approval before they're posted.

## Agent support

| Tier | Agents | What works |
|---|---|---|
| A | claude, codex, agy, grok, pi, opencode, copilot, cursor, devin, droid, kimi, qodercli, qwen, letta, hermes, mastracode, kilo, omp, with the Herdr integration installed | Everything, including resume with full context |
| B | The same agents without the integration, plus amp, kiro, maki, muse | Start, prompt, live state and watchers. Resume falls back to a catch-up prompt |
| C | gemini, cline | Like B, but Herdr's state detection is less tested |
| D | Any CLI agent Herdr doesn't recognize (`--cmd`) | Prompts are pasted into the pane. Progress is tracked through gate lines only |

The orchestrator can be any of these too. An agent that can run a background command and gets woken when it exits (Claude Code, for example) uses that. Other agents are woken by a Herdr prompt from a detached watcher.

## How it works

```
SKILL.md                 orchestrator instructions
references/prompts.md    kickoff, approval, ship and relay templates for workers
references/gotchas.md    known problems from real runs and their fixes
scripts/spawn.sh         worktree + background tab + worker, recorded in run.json
scripts/send.sh          prompt a worker and confirm it was delivered
scripts/mark.sh          workers call this at each gate (gate log, run.json, sidebar label)
scripts/watch.sh         wait until a worker needs the orchestrator, then report or wake it
scripts/board.sh         status table for the whole run
scripts/agents.tsv       per-agent integration, resume arguments and transcript paths
```

Each run keeps its state in `~/.agent-smith/runs/<repo>-<date>/`: `run.json` holds one record per task (branch, worktree, tab, pane, agent kind, session ID, gate, PR), and `gates/<id>.md` is the gate log.

## Notes

- Worktrees share whatever the main checkout shares. Tests that use one database can collide when workers run them at the same time, and a local dev site usually points at the main checkout, not at a worktree. See `references/gotchas.md`.
- New worktree paths can trigger first-run dialogs in some agents (folder trust, login, model selection). The orchestrator brings these to you instead of answering them.

## License

MIT
