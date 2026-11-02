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

## Herdr app

| Symptom | Cause | Fix |
|---|---|---|
| agy starts but ignores the kickoff | agy only takes an initial prompt with `-i` | Use the `launch.tsv` row as is (`agy -i {prompt}`); don't pass the prompt as a bare argument |
| agy resume starts a fresh conversation | The resume form is `agy --conversation {session} -i {prompt}`. The conversation id is in `~/.gemini/antigravity-cli/cache/last_conversations.json`, keyed by the worker's cwd (verified live) | Take the session from that file for the worktree path. agy also needs `-i` to take the prompt |
| Claude shows `idle` right after launch | Its boot idle at turn 0 comes before the kickoff starts | spawn.sh waits for `working`, `blocked` or `turn > 0` (60 s). Don't read `idle` at turn 0 as finished |
| Worker is `blocked` right after spawn | Claude and agy ask for folder trust on first run in a new folder or worktree path | Read it with `hc read` and `herdr-app shot`, bring the dialog to the user, then answer with send.sh |
| `send.sh` exits 1 with "blocked on a dialog" | `hc send` is refused while the worker is blocked | send.sh presses Esc first. If the dialog stays, read it and bring it to the user. Never `hc send --force` |
| `hc send` hangs | It waits for the person to pause typing and has no timeout of its own | Scripts bound it (send.sh `SEND_TIMEOUT` 30 s, mark.sh 60 s). A bounded failure means not delivered |
| No STOPPED report arrives, no note from the worker | A turn end gives no note to the parent terminal | STOPPED comes only from `S/app/watch.sh`. Keep one watcher armed per run and re-arm it after each report |
| `--notify` report never shows up | The orchestrator was typing or in a dialog, so `hc send` refused it | watch.sh queues the report and retries every pass without blocking other tasks. Wait or read the screen |
| `hc run --name smith-<id>` succeeds but no worker starts | A finished terminal with that name still exists. Finished terminals stay in `hc ls` until removed | `S/app/close.sh <id>` removes it (after the user agrees), then spawn again |
| Terminal missing from `herdr-app ls` right after `hc run` | The app hasn't placed it yet | spawn.sh retries the lookup. Don't spawn a second copy |
| Tab id doesn't look like the label | The `herdr.tab` label value is the tab id (`tb…`), not `smith-<id>` | Use the recorded `.tab` from `run.json` |
| Board tab doesn't show a `main.js` change | An open Board tab doesn't reload the mod | Close the Board tab and create it again (`S/app/preflight.sh`). Confirm with `herdr-app shot` |
| Board shows no state for a worker | `agents()` doesn't list pane-less hc workers | The mod reads state from `terminals()`. Keep it that way |
| Unsure which hc version works | hc 0.1.16 (herdr-app 0.1.16) is the verified version | Check `hc --version` and test a spawn and a send before a large run on another version |
