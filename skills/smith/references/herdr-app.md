# Herdr app backend

Use this file when smith runs inside the Herdr app (`HC_TERMINAL_ID` is set and `hc server status` succeeds). SKILL.md points at its sections as "§ <name>". `S` means this skill's `scripts/` directory. Every script needs the `RUN` env var. Workers are `hc` terminals: the worker for issue 101 is `code-101` and the worker reviewing PR 5737 is `review-5737`. The same name is the hc name, the tab name and what messages show. Verified with hc 0.1.16 (herdr-app 0.1.16).

Smith posts no toasts on this backend. Herdr's own toasts are the only ones.

## Agent support

Launch commands for each kind are in `S/app/launch.tsv`. Tasks in one run can use different kinds.

| Tier | Kinds | What works |
|---|---|---|
| A | claude, agy | Everything, including resume with full context. agy resumes with `agy --conversation {session} -i {prompt}`; the conversation id comes from `~/.gemini/antigravity-cli/cache/last_conversations.json`, keyed by the worktree path |
| B | pi | Best effort. No session id at spawn, so resume falls back to a catch-up prompt |
| C | Everything else | Untested. Add a row to `launch.tsv` and check it live before relying on it |

Workers launch with `--outlive-parent`, the default model and the default permission mode. No bypass or auto-accept flags. The orchestrator can be any agent kind. How it gets woken up depends on its own kind (see § Watch).

## Preflight

1. Detect the backend (SKILL.md § 0). If both Herdr TUI and the Herdr app are present, ask the user once which to use.
2. Choose the run directory: `RUN=~/.smith/runs/<repo>-<YYYY-MM-DD>-app`. Reuse it if it exists for today. It holds `run.json` (one record per task, with `"backend": "herdr-app"`) and `gates/<id>.md` (the gate log).
3. Run `RUN=<run> S/app/preflight.sh`. It records the orchestrator (address, kind, space and tab) and renames the orchestrator's tab to `SMITH-ORC<n>` (its hc address from the first digit on, uppercased, e.g. `SMITH-ORC7` for `t7`). Workers open as tabs in that space and show once in the sidebar, nested under the orchestrator. It prints `run.json` minus the tasks as one JSON line, or `{"error": ...}` and exit 1.
4. Pick the worker kind (or kinds) with the user. The default is `claude`. See § Agent support.

## Spawn

```bash
RUN=<run> S/app/spawn.sh <id> <branch> <base-ref> [--kind <kind>] <<'EOF'
...kickoff text...
EOF
```

The kickoff is the **Kickoff** prompt from `references/prompts.md` (with the gate instruction). It becomes the agent's own first prompt, so nothing is sent afterwards. spawn.sh:
- creates or reuses the worktree
- starts the worker with `hc run`, the name `code-<id>` (`review-<id>` when branch and base are `-`), `--outlive-parent` and the label `smith.run=<basename of RUN>`
- names the tab the same and records its id as `.tab` (the `herdr.tab` label value becomes the tab id, and scripts use the recorded one)
- retries the terminal lookup, because a terminal can be missing from `herdr-app ls` right after `hc run`
- selects the orchestrator's tab again, so focus doesn't move
- confirms delivery from state (`working`, `blocked`, or `turn > 0` within 60 s) and prints the task record plus its status
- refuses to respawn a live worker (exit 3): adopt it and use send.sh

If the status is `blocked`, read the screen with `hc read <hc address>` and `herdr-app shot <file>.png`, and bring the dialog to the user before answering it. New worktree paths often bring up a first-run dialog (folder trust for Claude and agy, login). If the status is `not_started`, read the screen before doing anything else. Never resend the kickoff blindly.

## Watch

Arm one watcher per run, after every prompt that starts work. Choose the mode from your own kind:

- **Your agent can run a command in the background and gets re-invoked when it exits** (Claude Code's `run_in_background`, for example): run `RUN=<run> S/app/watch.sh` that way. It prints the report and exits.
- **Any other orchestrator:** run it detached with notify mode:
  ```bash
  nohup env RUN=<run> S/app/watch.sh --notify >/dev/null 2>&1 & echo $! > <run>/watch.pid
  ```
  Reports arrive as typed messages. `--notify` keeps running after a report, queues each report and retries it on every pass, so a refused send never blocks the watcher. Start it once per run. If it has exited (check `kill -0 "$(cat <run>/watch.pid)"`), start a new one, which overwrites `watch.pid`.

In background-task mode the watcher exits after printing a report, so re-arm it after each report. In both modes it exits with "no live workers" once every task is closed, or gone and already reported.

Gate messages and hc notes arrive as typed messages: `[smith] GATE <gate> <worker>: <status> | <ref>` (sent by mark.sh) and `<hc>` notes (hc's own reports for child workers). The watcher reports the rest:
- **GATE:** mark.sh could not reach the orchestrator, so the gate line is only in the log.
- **GONE:** the worker disappeared.
- **BLOCKED:** a dialog that stays up for 5 seconds or more.
- **STOPPED:** no gate, and idle or done after at least one turn for 15 minutes. Change this with `--grace <min>`. A turn end gives no note to the parent, so this report comes only from the watcher.

## Read a worker

Read the screen: `hc read <hc address> --lines 50` (the `.hc` value in `run.json`). For a dialog, take a screenshot too: `herdr-app shot <file>.png`. If the reply isn't there, ask the worker to write its answer to a file and read the file.

## Relay answers

Relay the user's decisions with send.sh, quoting the user's words (see "Relaying answers" in `references/prompts.md`), and make sure a watcher is armed (§ Watch).

```bash
RUN=<run> S/app/send.sh <id> <<'EOF'
...message...
EOF
```

send.sh presses Esc if the worker is blocked, then sends with `hc send`, bounded by `SEND_TIMEOUT` (30 s). `hc send` waits for the person to pause and has no timeout of its own. Exit 0 means delivered, 1 means not delivered (read the screen first, don't resend blindly), 2 means sent but not confirmed. Never use `--force`.

Workers stop at each gate and ask in plain text. The kickoff tells them this.

## Board

`RUN=<run> S/board.sh` prints a status table from `run.json` and the live states. The Herdr sidebar lists each worker under the orchestrator with its current state.

## Wrap up

- Ask the user first. Then run `RUN=<run> S/app/close.sh <id>...`, or `--all` for every task in the run.
- close.sh kills and removes each task's terminal, closes its tab and marks the task closed. It only touches ids recorded in `run.json`, and it keeps worktrees, branches and `run.json`.
- Exit codes: 0 all went well, 1 something other than "already gone" failed (a warning is on stderr and the other tasks still run), 2 usage error or unknown task id (nothing touched).
- Stop the detached watcher this run started, by its recorded pid only: `kill "$(cat <run>/watch.pid)"`, then `rm <run>/watch.pid`. Skip it if the file is missing or the process has already exited. A background-task watcher needs no kill.
- When everything has merged, offer to remove the worktrees (`git worktree remove <path>`), delete the local branches and archive the run directory.
- Never touch spaces, tabs or terminals the run didn't create. Never stop the app or the core.

## Resume

1. Run `RUN=<run> S/app/preflight.sh --resume`, then show `RUN=<run> S/board.sh`. Resume a run only with its own backend (`run.json` `backend`; none means herdr).
2. For each task to resume:
   - **Worker still live:** adopt it and send the follow-up with send.sh. Don't respawn.
   - **Worker gone, session recorded:** `RUN=<run> S/app/spawn.sh <id> <branch> <base> --kind <kind> --resume <session>`, with the follow-up on stdin. All values come from `run.json`. The worker keeps its spec, the user's decisions and its commits in context.
   - **No session id, or the kind has no resume support:** spawn it fresh and send a short catch-up prompt (issue, PR, current gate, decisions so far).
3. Watch as usual (§ Watch).
