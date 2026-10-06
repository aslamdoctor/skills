# Gotchas from real runs

| Symptom | Cause | Fix |
|---|---|---|
| Prompt never reaches the worker | `herdr agent prompt ... --timeout N` without `--wait` is rejected ("--timeout requires --wait") and sends nothing | Use `scripts/send.sh`, which checks for `agent_prompted` and for the worker to start working |
| Watcher fires but the worker hasn't reached a gate | The worker is idle while its own background shell waits (review bot, CI) | watch.sh now ignores idle stops with no new gate line and waits for the worker to resume (STOPPED after 15 min) |
| (Claude Code) Text appears in the worker's input box | Dim (ANSI faint) text is the agent's suggested prompt, not something the user typed. Check with `herdr agent read <agent> --source visible --format ansi` and look for `[2m` | Ignore it. Sending a prompt replaces it |
| Worker is `blocked` | It opened a question dialog or a permission prompt | Read the screen, bring the question to the user, then `send.sh` (it presses Esc first) with the answer as text |
| Random test failures ("Could not insert post", deadlocks) | Worktrees share one test database | Give each worktree its own DB name if the test config allows it; otherwise rerun before debugging |
| Local site or app shows old code | The dev site (symlinks, docker mounts) points at the main checkout, not the worktree | Answer No to automated local QA from workers, or swap the mount for one worktree at a time |
| Untracked `vendor`, `node_modules` or env files in the worktree | Borrowed from the main checkout as symlinks; `/vendor/` ignore rules don't match symlinks | Tell workers to keep them out of `git add`, and check the PR's file list before reporting it shipped |
| Merge conflicts between parallel PRs | Several workers add to the same docs section, registry or numbered list | Assign ownership of shared entries in the kickoff; renumber or rebase before shipping the second PR |
| Closing keyword (`Fixes #N`) doesn't link the issue | The PR base isn't the default branch (stacked PR) | Link the issue to the PR directly |
| Automation (QA bots) skips a PR | Its preflight excludes PRs that depend on unmerged PRs | Expected for stacked PRs; mention it in the report |
| A worker shows the wrong state (idle while working, never blocked) | Herdr reads the screen with a detection manifest, and new prompt shapes can be misread | `herdr agent explain i<id>` shows the matched rule and why. Check `herdr integration status` for the agent kind |
| The worker's reply isn't in `agent read` | The agent draws on the alternate screen, so old rows aren't in the scrollback | Read the transcript using the path for that kind in `scripts/agents.tsv`; otherwise ask the worker to write its answer to a file |
| `spawn.sh` exits early under `set -e` | A helper returned non-zero before the agent was named | Fixed in `lib.sh` (helpers never fail). If it happens again, run with `bash -x` and close the stray tab it opened |
| `spawn.sh` status is `agent_not_ready`, or the first prompt lands in the wrong place | A first-run dialog on a new path: folder trust (agy, Claude Code), login, or a model picker (Pi opens one when no provider is set up) | Read the screen and bring the dialog to the user. For a model picker or login, the user sets up that agent once outside the run |
| BLOCKED reported, but the worker carried on | Some agents (agy) flash an approval prompt that clears by itself | watch.sh re-checks after 5 seconds and only reports a dialog that stays |
| A gate is marked but the watcher never reports it | The worker marked it before the watcher started | send.sh records the gate-log baseline when it sends, so this is handled. Always send through send.sh |
| Opencode/Pi session ID is empty right after spawn | Some integrations report the session only after the first turn | mark.sh refreshes the session ID at every gate |
| Tier D (custom) worker: no state, BLOCKED never reported | Herdr can't see the agent's state | The watcher uses gate lines plus an unchanged screen for STOPPED. Check the screen yourself after sending |
