# Herdr backend

Use this file when smith runs inside a Herdr pane (`HERDR_ENV=1`). SKILL.md points at its sections as "§ <name>". `S` means this skill's `scripts/` directory. Every script needs the `RUN` env var. Herdr agent names are lowercase, so the worker for task 101 is `smith-101` (its label is `🤓 smith-101`, and messages show the address as `🤓 smith-101`). Scripts read the name from `run.json`, so older runs with `i<id>` workers keep working.

## Agent support

Worker kinds come from Herdr, and `S/agents.tsv` maps each kind to its integration and resume arguments. Tasks in one run can use different kinds.

| Tier | Kinds | What works |
|---|---|---|
| A | claude, codex, agy, grok, pi, opencode, copilot, cursor, devin, droid, kimi, qodercli, qwen, letta, hermes, mastracode, kilo, omp, with the Herdr integration installed | Everything, including resume with full context |
| B | The same kinds without the integration, plus amp, kiro, maki, muse | Start, prompt, state and watchers. No session ID, so resume falls back to a catch-up prompt |
| C | gemini, cline | Like B, but state detection is less tested. Gate lines still drive the run |
| D | Any CLI agent Herdr doesn't recognize | `spawn.sh --cmd "<launch>"`. Prompts are pasted into the pane, and the watcher uses gate lines plus an unchanged screen for STOPPED. The worker must be able to run a shell command |

The orchestrator works the same way. Its wake-up mode depends on its own kind (see § Watch).

## Preflight

1. Check `test "${HERDR_ENV:-}" = 1`. If it fails, say Smith needs to run inside a Herdr pane and stop. Load the `herdr` skill if one is available.
2. Find your own kind: `herdr agent get "$HERDR_PANE_ID" | jq -r .result.agent.agent`. This picks the watch mode in § Watch.
3. Pick the worker kind (or kinds) with the user. The default is your own kind. For each kind, check `herdr integration status`, and offer `herdr integration install <integration>` (the integration name is in `agents.tsv`) if it isn't `current`.
4. Rename your own tab so it stands out from the workers: `herdr tab rename "$HERDR_TAB_ID" "😎 SMITH"`. If it fails, carry on.
5. Choose the run directory: `RUN=~/.smith/runs/<repo>-<YYYY-MM-DD>`. Reuse it if it exists for today. It holds `run.json` (one record per task) and `gates/<id>.md` (the gate log).

## Spawn

```bash
RUN=<run> S/spawn.sh <id> <branch> <base-ref> [--kind <kind>]
RUN=<run> S/spawn.sh <id> <branch> <base-ref> --cmd "<launch command>"   # tier D
```

spawn.sh:
- creates or reuses the worktree
- opens a background tab and starts the worker `smith-<id>`
- records the task in `run.json` (kind, pane, tab, session ID if one is reported)
- labels the tab and pane `🤓 smith-<id>` in the sidebar
- prints the task record

If the status isn't `idle`, read the screen. New worktree paths often bring up a first-run dialog (folder trust, login, model picker). Bring it to the user before answering it.

Send each worker the **Kickoff** prompt from `references/prompts.md` (with the herdr gate instruction) through stdin. It tells the worker to mark each gate with `mark.sh`.

```bash
RUN=<run> S/send.sh <id> <<'EOF'
...kickoff text...
EOF
```

Treat a non-zero exit as "not delivered": read the screen and resend. Never assume a prompt landed.

## Watch

After every prompt that starts work, arm one watcher per worker. Choose the mode from your own kind:

- **Your agent can run a command in the background and gets re-invoked when it exits** (Claude Code's `run_in_background`, for example): run `RUN=<run> S/watch.sh <id>` that way.
- **Any other orchestrator:** run the watcher detached with notify mode, so it wakes you with a Herdr prompt:
  ```bash
  nohup env RUN=<run> S/watch.sh <id> --notify "$HERDR_PANE_ID" >/dev/null 2>&1 &
  ```
  The report arrives as a new message starting `[smith]`. If you're showing the user a dialog at the time, the watcher waits for it to close rather than typing into it.

The watcher reports one of four things:
- **GATE:** a new gate line.
- **BLOCKED:** a dialog that stays up.
- **STOPPED:** no gate, and idle (or an unchanged screen for tier D) for 15 minutes. Change this with `--grace <min>`.
- **GONE:** the agent exited.

It also shows a Herdr toast with a sound. A worker that goes idle while its own background shell runs (bot review, CI) doesn't trigger the watcher.

## Read a worker

Read the worker's screen: `herdr agent read <agent> --source recent-unwrapped --lines 50`, or `herdr pane read <pane> ...` for tier D. If the reply isn't there (it was drawn on the alternate screen), use the transcript path for that kind in `agents.tsv`. Otherwise, ask the worker to write its answer to a file and read the file.

## Relay answers

Relay the user's decisions with send.sh, quoting the user's words (see "Relaying answers" in `references/prompts.md`), and re-arm the watcher.

Workers stop at each gate and ask in plain text. The kickoff tells them this. If one opens an interactive dialog anyway, `send.sh` presses Esc before sending the answer.

## Board

`RUN=<run> S/board.sh` prints a status table from `run.json` and the live states.

## Wrap up

- Close only the tabs this run created (from `run.json`), and only when the user agrees: `herdr tab close <tab>`. Keep the worktrees and `run.json` until the PRs merge, since review fixes resume from them.
- Stop any detached watchers you started for closed tasks (`pkill -f "watch.sh <id>"`).
- When everything has merged, offer to remove the worktrees (`git worktree remove <path>`), delete the local branches and archive the run directory.
- Never focus or close tabs you didn't create. Never stop the Herdr server.

## Resume

1. Show `RUN=<run> S/board.sh`.
2. For each task to resume, start the worker in its old conversation, with the kind recorded for it:
   ```bash
   RUN=<run> S/spawn.sh <id> <branch> <base> --kind <kind> --resume <session>
   ```
   All values come from `run.json`, and the resume arguments for that kind come from `agents.tsv`. The worker keeps its spec, the user's decisions and its commits in context. If the task has no session ID, or the kind has no resume support (or is tier D), spawn it fresh and send a short catch-up prompt (issue, PR, current gate, decisions so far).
3. Send the follow-up prompt with send.sh and watch as usual (§ Watch).
