# Smith: Orca backend

Date: 2026-10-31
Status: draft, awaiting approval

## Intent

`smith` (in `skills/smith/`) runs several coding tasks in parallel from one orchestrator session. Each task gets a git worktree and a worker agent that stops at gates (spec, implemented, pr) so the user approves every decision. Today it only runs inside Herdr.

The user also works inside Orca, which has its own tabs, panes, worktrees and an orchestration layer. Running Herdr inside Orca is overkill. The goal is for the same `/smith` to work in Orca, using Orca's native pieces instead of smith's herdr scripts.

## Goals

- One skill, `/smith`, with the same trigger phrases. It picks the backend from where it runs.
- In Orca, build on Orca's orchestration layer (Runs, Tasks, Dispatches, `ask`/`reply`, `worker_done`, `check --wait`) rather than porting the herdr scripts.
- Keep the user-facing flow identical: setup table confirmed before spawning, gate reports with recommendations, the user approves every spec, ship and posted text, stacked branches, ship pre-answers, wrap-up and resume.
- Worker naming stays `Smith-<id>`.
- Orca workers are Claude Code in v1. That's the only kind whose gate wait was verified.

## Non-goals

- Changing how the herdr backend behaves.
- Supporting Herdr running inside Orca as a first-class case.
- Remote/SSH Orca servers (`--on`). Local Orca only for now.
- Porting smith's agent tier table to Orca.
- Full support for non-Claude workers on Orca. A gate relies on the worker keeping `orchestration ask` running for 10 minutes and resuming it, and only Claude was seen doing that. Other kinds Orca can launch (codex, cursor, opencode...) are allowed if the user asks, but the setup table marks them "best-effort: gates may not hold", and gotchas.md explains why. A second, non-blocking gate path for those kinds is future work.

## Anti-goals

- Any regression in the herdr path. A user running `/smith` in Herdr after this change must see no difference.
- Workers posting to GitHub or anywhere else without the user's approval.
- Duplicate questions, lost answers, or a worker silently going idle at a gate.

## Backend selection

At preflight, before anything else:

| Condition | Backend |
|---|---|
| `HERDR_ENV=1` | herdr |
| `ORCA_TERMINAL_HANDLE` set and `orca status --json` returns `ok: true` | orca |
| Both | ask the user once (my call) |
| Neither | say smith needs Herdr or Orca, stop |

## File layout

```
skills/smith/
├── SKILL.md              backend-neutral flow + backend selection; tells the orchestrator to read its backend file
├── README.md             updated: Herdr or Orca
├── references/
│   ├── herdr.md          current herdr-specific steps (spawn/send/watch/read/board/resume/wrap-up), moved out of SKILL.md unchanged
│   ├── orca.md           the same steps through orca
│   ├── prompts.md        shared templates; the gate instruction has a herdr variant and an orca variant
│   └── gotchas.md        split into Common / Herdr / Orca sections
└── scripts/              herdr-only, unchanged
```

SKILL.md keeps: preflight (shared parts), picking tasks, the setup table, the gate report rules (section 4.2), ship, rules, install notes. Herdr-specific text moves to `references/herdr.md` word for word, so the herdr path reads the same instructions it reads today, just in two files.

The frontmatter `description` changes "from one Herdr pane" to "from one Herdr pane or Orca terminal", and "Requires Herdr (HERDR_ENV=1)" to "Requires Herdr or Orca".

## Orca backend: how each step works

All of these were checked in a spike on 2026-10-31 (Orca 1.4.245) unless marked untested.

### Run record

- Create one Orca Run per smith run: `orca orchestration run-create --objective "smith <repo> <date>: <ids>" --json`.
- Keep smith's local record too: `~/.smith/runs/<repo>-<YYYY-MM-DD>/run.json` with `"backend": "orca"`, the Orca `run_id`, and per task: id, branch, base, kind, worktree id and path, task id, current dispatch id, terminal handle, gate, gate text, PR, agent session id. This is what "resume yesterday's smith run" reads, for either backend.
- After an orchestrator restart, rebind with `orca orchestration run-use --id <run_id>`.

### Spawn

Two steps, because `worker-start` can't set the branch name but `worktree create` can:

```
orca worktree create --name <slug> --branch <branch> --base-branch <base-ref> --no-parent \
  --comment "Smith-<id>: starting" --json
orca orchestration worker-start --worktree id:<worktree id> --agent <kind> \
  --task-title "Smith-<id>" --spec "<kickoff>" --json
```

- Orca defaults to a `<git-user>/<name>` branch (seen: `aslamdoctor/smith-spike`). `--branch` uses the exact name instead (Orca adds a numeric suffix if the name is taken, so check the created branch against the requested one and stop if they differ). If the branch already exists locally (resume, reused task), the builder checks whether `--branch` attaches it or suffixes it.
- Stacked task: `--base-branch <parent branch>`, optionally `--parent-worktree id:<parent wt>` for Orca's sidebar grouping.
- `--setup`: default `inherit`, so repo setup hooks run as Orca's settings say.
- Orca places the worktree at `~/orca/workspaces/<repo>/<name>`. `WT_ROOT` does not apply to the orca backend; the setup table shows Orca's path instead.
- Set the display name to `Smith-<id>` (`--display-name` on `worktree set` if `create` lacks it).
- Record `runId`, `taskId`, `dispatchId`, the worktree id from `effects`, and the agent terminal handle from `effects` into run.json.
- The kickoff is delivered with the spec, so there is no separate send step. `state: ready` and `turnStart: observed` mean it landed. A non-zero exit means failure: read `failedStage` and `residualResources` and follow Orca's recovery reference, never relaunch blindly.
- First-run dialogs (folder trust etc.): untested in Orca. If `worker-show` reports `attention.categories` containing `input` with no question in the inbox, read the screen and bring it to the user.

### Gates

- One Dispatch covers a task from spec through PR. The spec and implemented gates are blocking `ask`s. The pr gate is not: once the PR is open the worker sends `worker_done` with the PR URL and goes idle, so the terminal is free for a review-fix Dispatch and nothing polls while reviewers take days. Each resume of a pending `ask` costs one small agent turn every 10 minutes, which is acceptable for spec and implemented waits (hours, not days). At each blocking gate the worker runs the `ask` command from its Orca preamble with a question that starts `GATE <gate>: ` followed by the status, then the ref (doc path, commit hash, PR URL) and its open questions.
- The worker also sets the card comment at each gate: `orca worktree set --worktree active --comment "Smith-<id>: <gate>" --json`, and `--unread` so the sidebar dot asks for attention. (Comment update was observed working from the worker; `--unread` untested.)
- `ask` blocks for 10 minutes (seen with Claude: `--timeout-ms 600000`). On timeout Orca prints "question is still pending ... Resume waiting; do not ask again" with an `--resume <messageId>` command, and the worker re-waits on the same message. Seen working past one timeout; the worker never went idle. The kickoff should still tell the worker to keep resuming the same message and never ask twice.
- Plain-text questions outside a gate use `ask` too (gate word `question`).
- Orca's preamble tells workers not to post to GitHub or other channels "during the run". The kickoff and ship prompts must say explicitly that pushing and opening the PR at the pr gate is approved by the user when the ship message arrives, and that posting review replies needs the user's approval relayed through `reply`.

### Watching

- One watcher for the whole run instead of one per worker: `orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms <n> --json`.
  - Claude Code orchestrator: run it with `run_in_background` and get re-invoked when it exits.
  - Other orchestrators: builder decides (Orca may nudge the coordinator terminal; untested). Fallback is a detached loop that writes to a file plus a short poll.
- A delivery replays until acked. Process every message in the batch, then `check --ack <deliveryId>` (which can be combined with `--wait` for the next one). Forgetting the ack makes old messages come back, which happened in the spike.
- A timeout or empty result is a checkpoint. After three empty waits, run `worker-list --run <run_id> --json` and act on `projection.attention` and `projection.nextAction` per Orca's guide.
- Smith's STOPPED case maps to `worker-list` liveness plus `attention`; GONE maps to `liveness.verdict: exited`. BLOCKED maps to `attention` showing input with no pending question.

### Reading a worker

`orca orchestration worker-read --dispatch <id> --limit 60 --json` returns the transcript (`.result.transcript.messages`). Use it for the gate report when the question text isn't enough. `orca terminal read --terminal <handle> --screen --json` for dialogs.

### Relaying answers

`orca orchestration reply --id <messageId> --body "<user's words quoted, plus routing details>" --json`. Same quoting rule as smith's "Relaying answers" template. Seen working: the worker got the text exactly.

Guidance that isn't an answer to a pending ask (e.g. "also fix X"): `orca orchestration send --to dispatch:<id> --subject ... --body ... --json`. The kickoff tells the worker to run `orchestration check --terminal <own handle>` at checkpoints, as Orca's worker contract says.

### Board

`run.json` plus `orca orchestration worker-list --run <run_id> --json`, rendered as the same status table smith shows today (id, kind, branch, gate, liveness, PR). The builder decides whether this is a small script (`scripts/orca-board.sh`) or a jq one-liner in `orca.md`.

### Finishing a task

At the pr gate the worker sends `worker_done --outcome succeeded` with its summary, PR URL and `--files-modified`, after the ship flow's own approval steps (review-bot findings, thread replies) have gone through the user. If the ship flow needs a decision before the PR exists, that's a blocking `ask` like any other gate. The orchestrator then runs `worker-retain` by default, so review fixes reuse the same agent, and releases only when the PR merges or the user says so.

### Review fixes and resume

- Same terminal still alive: start a follow-up Dispatch on it, `worker-start --terminal <handle> --worktree id:<worktree id> --task-title "Smith-<id> fixes" --spec "<follow-up>"`. Seen working: the worker kept its memory of the earlier task.
- Terminal gone (Orca restarted, terminal closed): find the session with `orca search "<distinctive phrase>" --path <worktree path> --json`, which returns a `resumeCommand` such as `claude --resume <session id>`. Seen returning the right command; launching it as a supervised worker is untested. Likely route: `orca terminal create --worktree id:<wt> --command "<resume command>"`, then `worker-start --terminal <new handle> --worktree id:<wt> --spec ...`. Builder verifies. Fallback: a fresh worker plus smith's catch-up prompt.
- Store the session id in run.json as soon as it can be found (after the first gate), so resume doesn't depend on the search index.

### Wrap-up

- Release dispatches the run still owns (`worker-list --run <id> --terminal-state reclaimable`), only with the user's agreement.
- Remove worktrees after merge with `orca worktree rm --worktree id:<wt> --force` (seen: also removed the branch, so confirm the PR merged first). Never close terminals or worktrees the run didn't create.

## Gotchas to record in gotchas.md (Orca section)

- Ack every delivery, or old messages replay.
- Orca prefixes branch names with the git user unless `worktree create --branch` is used; `worker-start` has no branch flag.
- `ask` is 10 minutes per wait; workers must resume the same message, never re-ask.
- The preamble forbids posting during the run; smith's prompts must grant pushing/PR explicitly at the pr gate.
- `orca worktree rm` deletes the branch too.
- Use the resolved Orca executable (`ORCA_CLI_COMMAND`, `orca-dev`, `orca-ide` on Linux) per the orca-cli guide, never bare `orca` on Linux outside Orca.
- `worker-list` without `--run` lists every dispatch ever recorded.

## Decided by the user

- One `/smith` skill, backend chosen by where it runs.
- Orca backend built on Orca's orchestration layer, not a port of the herdr scripts.
- Approval flow unchanged.
- Claude-only workers on Orca for v1; other kinds best-effort with a warning.

## My calls (user can override)

- Ask once when both Herdr and Orca are detected.
- Keep `~/.smith/runs/` run.json for both backends, with a `backend` field.
- One Dispatch per task from spec through PR. The pr gate ends it with `worker_done` instead of a blocking ask; review fixes are new Dispatches on the same terminal.
- Create the worktree with `orca worktree create --branch` first, then `worker-start` on it, so branches follow the project format.
- Retain worker terminals until PRs merge.
- Local Orca only.

## Left to the builder

- Exact wording of the orca variants in prompts.md.
- Whether `orca-board.sh` (or other small helpers) is worth a script.
- Wake mode for non-Claude orchestrators (the orchestrator can be any agent; only workers are limited to Claude).
- Defaulting an old run.json with no `backend` field to herdr.
- Verifying the untested items above: first-run dialogs, `--unread`, `--branch` with an existing branch, supervised resume from a session id.
