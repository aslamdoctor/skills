# Gotchas from real runs

## Common

| Symptom | Cause | Fix |
|---|---|---|
| Random test failures ("Could not insert post", deadlocks) | Worktrees share one test database | Give each worktree its own DB name if the test config allows it; otherwise rerun before debugging |
| Local site or app shows old code | The dev site (symlinks, docker mounts) points at the main checkout, not the worktree | Answer No to automated local QA from workers, or swap the mount for one worktree at a time |
| Untracked `vendor`, `node_modules` or env files in the worktree | Borrowed from the main checkout as symlinks; `/vendor/` ignore rules don't match symlinks | Tell workers to keep them out of `git add`, and check the PR's file list before reporting it shipped |
| Merge conflicts between parallel PRs | Several workers add to the same docs section, registry or numbered list | Assign ownership of shared entries in the kickoff; renumber or rebase before shipping the second PR |
| Closing keyword (`Fixes #N`) doesn't link the issue | The PR base isn't the default branch (stacked PR) | Link the issue to the PR directly |
| Automation (QA bots) skips a PR | Its preflight excludes PRs that depend on unmerged PRs | Expected for stacked PRs; mention it in the report |

## Herdr

| Symptom | Cause | Fix |
|---|---|---|
| Prompt never reaches the worker | `herdr agent prompt ... --timeout N` without `--wait` is rejected ("--timeout requires --wait") and sends nothing | Use `scripts/send.sh`, which checks for `agent_prompted` and for the worker to start working |
| Watcher fires but the worker hasn't reached a gate | The worker is idle while its own background shell waits (review bot, CI) | watch.sh now ignores idle stops with no new gate line and waits for the worker to resume (STOPPED after 15 min) |
| (Claude Code) Text appears in the worker's input box | Dim (ANSI faint) text is the agent's suggested prompt, not something the user typed. Check with `herdr agent read <agent> --source visible --format ansi` and look for `[2m` | Ignore it. Sending a prompt replaces it |
| Worker is `blocked` | It opened a question dialog or a permission prompt | Read the screen, bring the question to the user, then `send.sh` (it presses Esc first) with the answer as text |
| A worker shows the wrong state (idle while working, never blocked) | Herdr reads the screen with a detection manifest, and new prompt shapes can be misread | `herdr agent explain smith-<id>` shows the matched rule and why. Check `herdr integration status` for the agent kind |
| The worker's reply isn't in `agent read` | The agent draws on the alternate screen, so old rows aren't in the scrollback | Read the transcript using the path for that kind in `scripts/agents.tsv`; otherwise ask the worker to write its answer to a file |
| `spawn.sh` exits early under `set -e` | A helper returned non-zero before the agent was named | Fixed in `lib.sh` (helpers never fail). If it happens again, run with `bash -x` and close the stray tab it opened |
| `spawn.sh` status is `agent_not_ready`, or the first prompt lands in the wrong place | A first-run dialog on a new path: folder trust (agy, Claude Code), login, or a model picker (Pi opens one when no provider is set up) | Read the screen and bring the dialog to the user. For a model picker or login, the user sets up that agent once outside the run |
| BLOCKED reported, but the worker carried on | Some agents (agy) flash an approval prompt that clears by itself | watch.sh re-checks after 5 seconds and only reports a dialog that stays |
| A gate is marked but the watcher never reports it | The worker marked it before the watcher started | send.sh records the gate-log baseline when it sends, so this is handled. Always send through send.sh |
| Opencode/Pi session ID is empty right after spawn | Some integrations report the session only after the first turn | mark.sh refreshes the session ID at every gate |
| Tier D (custom) worker: no state, BLOCKED never reported | Herdr can't see the agent's state | The watcher uses gate lines plus an unchanged screen for STOPPED. Check the screen yourself after sending |

## Orca

| Symptom | Cause | Fix |
|---|---|---|
| Old gates or an old `worker_done` come back on the next check | The inbox replays a delivery until it is acked | Process the whole batch, then `check --ack <deliveryId>` (it can go on the next `--wait`) |
| Worker branch is `<git-user>/<name>`, or `<branch>-2` | `worker-start` has no branch flag and Orca prefixes its default branch; `worktree create --branch` adds a numeric suffix when the name is taken | Create the worktree with `orca worktree create --branch <branch>` first, check `git branch --show-current`, and stop if it differs |
| A gate question shows up twice, or the worker goes idle at a gate | `orchestration ask` blocks for 10 minutes, then times out | The worker runs the `--resume <messageId>` command it prints and waits on the same message. The orca gate instruction says never to ask twice |
| Worker won't push or open the PR at the pr gate | Orca's worker preamble has a no-posting line for the whole run | The orca Ship message approves pushing and opening the PR explicitly. Thread replies and comments still go through `ask` |
| Branch is gone after cleanup, or still there | `orca worktree rm` deletes the branch only when it can prove it's merged; it keeps one that predated the worktree or that it can't prove is merged | Remove a worktree only after confirming its PR merged, then check `git branch --list <branch>` |
| An `orca` command starts a screen reader or hits the wrong build | On Linux outside Orca, bare `orca` is the GNOME screen reader; dev checkouts use `orca-dev` | Resolve the executable once (`ORCA_CLI_COMMAND`, `orca-dev`, `orca-ide` on Linux) and use it everywhere |
| `worker-list` shows dispatches from other runs | `worker-list` without --run lists every dispatch the calling terminal can see, or every Run when unbound | Always pass `--run <orca_run_id>` |
| A non-Claude worker acts without approval or stops waiting | Only Claude was seen holding a blocking `ask` through timeouts; a kind that kills long commands drops the wait (gates may not hold) | Use claude workers. Label other kinds "best-effort: gates may not hold" in the setup table |
| `worktree create --branch <branch>` gives `<branch>-2` for a branch that already exists | Orca only attaches an existing branch that still points at the base; one with its own commits, or one checked out elsewhere, gets a suffixed new branch cut from the base | Continue an existing task in its existing worktree. The branch check after create stops a suffixed spawn |
| `worker-release` reports `retained` and nothing closes | Reason `ownership_transferred`: a follow-up Dispatch took over the terminal. Reason `external_terminal`: smith opened the terminal with `terminal create` (resume route) | Release the latest dispatch. Close a terminal you created with `orca terminal close --terminal <handle>` |
