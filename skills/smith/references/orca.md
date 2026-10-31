# Orca backend

Use this file when smith runs inside an Orca terminal (`ORCA_TERMINAL_HANDLE` is set). SKILL.md points at its sections as "§ <name>". This backend uses Orca's orchestration layer (Runs, Tasks, Dispatches, `ask`/`reply`, `worker_done`, `check --wait`) and none of the herdr scripts in `scripts/`.

Commands below write `orca`. Resolve the executable once per session as the orca-cli guide says (`ORCA_CLI_COMMAND` if set, else `orca-dev` in an Orca dev checkout, else `orca-ide` on Linux outside an Orca terminal, else `orca`) and use that everywhere. Local Orca only: never pass `--on`, `--pairing-code` or `--environment`.

The worker for task 101 is `Smith-101`: that is its task title, worktree display name and card comment prefix.

## Agent support

| Kind | Status |
|---|---|
| claude | Supported. The gate flow was verified with Claude Code workers |
| Any other agent Orca can launch (codex, cursor, opencode and the rest) | Best-effort. Label it "best-effort: gates may not hold" in the setup table, and only use it when the user asks |

Why: a spec or implemented gate is an `orchestration ask` that blocks for 10 minutes, times out, and must be resumed on the same message with `--resume <messageId>` until the user answers. Claude was seen doing that without going idle or asking twice. Other kinds weren't tested, and a worker that drops the wait goes idle at the gate with nobody watching it.

The orchestrator itself can be any agent. Its wake-up mode is in § Watch.

## Preflight

1. Check `test -n "${ORCA_TERMINAL_HANDLE:-}"` and `orca status --json | jq -e '.result.ok // .ok'`. If either fails, say Smith needs to run inside an Orca terminal and stop. If a command reports Orca isn't running, run `orca open --json` and retry once.
2. Load the orchestration guide once per session: `orca skills get orchestration`. Its worker contract and recovery notes apply on top of this file.
3. Your own kind is whatever agent you are. Orca has no lookup for it; it only picks the watch mode in § Watch.
4. Worker kinds: `claude` unless the user asks for another kind (see § Agent support).
5. Choose the run directory: `RUN=~/.smith/runs/<repo>-<YYYY-MM-DD>`. Reuse it if it exists for today and its `run.json` says `"backend": "orca"`. It holds `run.json` (one record per task) and `gates/<id>.md` (the gate log you keep from the inbox).
6. Create the Orca Run, or rebind to the one in `run.json`:
   ```bash
   orca orchestration run-create --objective "smith <repo> <YYYY-MM-DD>: <ids>" --json   # new run: note .result.run.id (or the id field it prints)
   orca orchestration run-use --id <orca_run_id> --json                                  # existing run
   ```
   Write the run-level fields once:
   ```bash
   mkdir -p "$RUN/gates"; f="$RUN/run.json"; [ -f "$f" ] || echo '{"tasks":[]}' > "$f"
   jq --arg r "<orca_run_id>" '.backend = "orca" | .orca_run_id = $r' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
   ```

## Spawn

Two steps, because `worker-start` can't name the branch and `worktree create` can.

1. Create the worktree with the exact branch name:
   ```bash
   orca worktree create --name <slug> --branch <branch> --base-branch <base-ref> --no-parent \
     --comment "Smith-<id>: starting" --json
   ```
   Stacked task (B builds on A): use `--base-branch <parent branch> --parent-worktree id:<parent worktree id>` instead of `--no-parent`.

   Take the worktree id (`<repo-id>::<path>`) and path from the result. Then check the branch, because Orca adds a numeric suffix when the name is taken:
   ```bash
   test "$(git -C <worktree path> branch --show-current)" = "<branch>"
   ```
   If it differs, stop and tell the user which branch Orca created. Don't spawn on it.

   Set the display name: `orca worktree set --worktree id:<worktree id> --display-name "Smith-<id>" --json`.

2. Start the worker with the **Kickoff** prompt from `references/prompts.md` (with the orca gate instruction) as its spec. The kickoff is delivered with the spec, so there is no separate send step:
   ```bash
   orca orchestration worker-start --worktree id:<worktree id> --agent claude \
     --task-title "Smith-<id>" --spec "$(cat "$RUN/kickoff-<id>.md")" --json
   ```
   Write the kickoff to `$RUN/kickoff-<id>.md` first so the quoting survives. `state: ready` and `turnStart: observed` mean it landed. Note `taskId`, `dispatchId` and the agent terminal handle from the result.

   A non-zero exit means it failed. Read `failedStage` and `residualResources` from the output, load Orca's recovery reference (`orca skills get orchestration --reference references/recovery-and-cleanup.md`) and follow it. Never relaunch blindly.

3. Record the task in `run.json`:
   ```bash
   f="$RUN/run.json"
   jq --arg id "<id>" --arg branch "<branch>" --arg base "<base-ref>" --arg kind claude \
      --arg wt "<worktree id>" --arg path "<worktree path>" --arg task "<taskId>" \
      --arg disp "<dispatchId>" --arg term "<terminal handle>" --arg now "$(date -u +%FT%TZ)" \
      '.tasks = ([.tasks[] | select(.id != $id)] + [{id:$id, branch:$branch, base:$base, kind:$kind,
         worktree_id:$wt, worktree_path:$path, task_id:$task, dispatch_id:$disp, terminal:$term,
         gate:"started", gate_text:"", pr:null, session:null, updated:$now}])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
   ```
   Update `gate`, `gate_text`, `pr`, `session`, `dispatch_id` and `updated` the same way as the task moves.

First-run dialogs (folder trust, login) in a new worktree: if § Board shows `attention` with input and the inbox has no question for that worker, read its screen (§ Read a worker) and bring the dialog to the user before answering it.

## Watch

Run one watcher for the whole run, not one per worker:

```bash
orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 3600000 --json
```

- **Your agent can run a command in the background and gets re-invoked when it exits** (Claude Code's `run_in_background`): run it that way.
- **Any other orchestrator:** run it detached, writing to a file, and poll that file at a short interval:
  ```bash
  nohup sh -c 'orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 3600000 --json > "$RUN/inbox.json" 2>/dev/null' >/dev/null 2>&1 &
  ```

When it returns, process every message in the batch, then acknowledge the batch with its `deliveryId`. `--ack` can go on the next wait:

```bash
orca orchestration check --ack <deliveryId> --wait --types "worker_done,escalation,question" --timeout-ms 3600000 --json
```

**Always ack. A batch you don't ack comes back on the next check, so old gates and old `worker_done` messages replay as if they were new.**

Map each message to a report (SKILL.md § 4):

| Message | Report |
|---|---|
| `question` whose body starts `GATE <gate>:` | **GATE** `<gate>` (spec or implemented). Keep its message id for § Relay answers |
| any other `question` | **GATE question** |
| `worker_done` | **GATE pr**, with the PR URL from the body. Then `worker-retain` (§ Wrap up) |
| `escalation` | **BLOCKED** |

Append each message to `gates/<id>.md` and update the task's `gate` and `gate_text` in `run.json`.

An empty or timed-out wait is a checkpoint, not an error. After three empty waits in a row, list the run's workers and act on what Orca says:

```bash
orca orchestration worker-list --run <orca_run_id> --json \
  | jq '.result.workers[] | {dispatchId, workerState, liveness: .projection.liveness.verdict, attention: .projection.attention, next: .projection.nextAction}'
```

- `projection.attention.requiresAction` true, or a `nextAction` other than `none`: do what it says, or bring it to the user. Input attention with no pending question is **BLOCKED**.
- No gate, no attention, and quiet: **STOPPED**.
- `liveness.verdict: exited`: **GONE**.

Always pass `--run`. Without a bound Run, `worker-list` lists every dispatch Orca ever recorded.

## Read a worker

The transcript:

```bash
orca orchestration worker-read --dispatch <dispatchId> --limit 60 --json | jq '.result.transcript.messages'
```

Use it when the question text isn't enough for the gate report. For a dialog or a stuck screen, read the terminal: `orca terminal read --terminal <handle> --screen --json`.

Once a worker has reached its first gate, record its agent session id in `run.json` (`session`) so § Resume doesn't depend on the search index. `orca search "Smith-<id>" --path <worktree path> --json` returns it inside `resumeCommand`.

## Relay answers

Answer a pending gate or question with the message id from the inbox, quoting the user's words (see "Relaying answers" in `references/prompts.md`):

```bash
orca orchestration reply --id <messageId> --body "$(cat "$RUN/reply-<id>.md")" --json
```

Anything that isn't an answer to a pending ask (new guidance, "also fix X", the ship go-ahead after a `worker_done`):

```bash
orca orchestration send --to dispatch:<dispatchId> --subject "Smith-<id>: <topic>" --body "$(cat "$RUN/msg-<id>.md")" --json
```

The kickoff tells workers to run `orchestration check` at checkpoints, so sent messages get read. Re-arm the watcher after relaying (§ Watch).

## Board

Join `run.json` with the run's live worker rows by dispatch id:

```bash
jq -r --slurpfile live <(orca orchestration worker-list --run "$(jq -r .orca_run_id "$RUN/run.json")" --json) '
  ($live[0].result.workers | map({key: .dispatchId, value: .projection.liveness.verdict}) | from_entries) as $l
  | "id | kind | branch | gate | liveness | PR",
    (.tasks[] | "\(.id) | \(.kind) | \(.branch) | \(.gate) | \($l[.dispatch_id] // "unknown") | \(.pr // "-")")
' "$RUN/run.json"
```

Show it as a table in every report.

## Wrap up

- After each `worker_done`, retain the worker by default so review fixes reuse the same agent and its memory: `orca orchestration worker-retain --dispatch <dispatchId> --json`.
- Release a worker only when its PR has merged or the user says so: `orca orchestration worker-release --dispatch <dispatchId> --json`. To see what the run still owns: `orca orchestration worker-list --run <orca_run_id> --terminal-state reclaimable --json`.
- Remove a worktree only after you've confirmed its PR merged, and only with the user's agreement. **`orca worktree rm` also deletes the branch:**
  ```bash
  orca worktree rm --worktree id:<worktree id> --force --json
  ```
- Touch only worktrees and terminals listed in this run's `run.json`. Never close terminals or worktrees the run didn't create, and never quit Orca.

## Resume

1. Rebind to the Run with `orca orchestration run-use --id <orca_run_id> --json`, then show § Board.
2. For each task to resume:
   - **Its terminal is still alive** (liveness not `exited`): start a follow-up Dispatch on it. The agent keeps its spec, the user's decisions and its commits in memory.
     ```bash
     orca orchestration worker-start --terminal <handle> --worktree id:<worktree id> \
       --task-title "Smith-<id> fixes" --spec "$(cat "$RUN/followup-<id>.md")" --json
     ```
   - **Its terminal is gone** (Orca restarted, terminal closed): take `session` from `run.json`, or find it with `orca search "Smith-<id>" --path <worktree path> --json` and read `resumeCommand` (e.g. `claude --resume <session id>`). Open a terminal with it and supervise that terminal (unverified):
     ```bash
     orca terminal create --worktree id:<worktree id> --title "Smith-<id>" --command "<resumeCommand>" --json
     orca orchestration worker-start --terminal <new handle> --worktree id:<worktree id> \
       --task-title "Smith-<id> fixes" --spec "$(cat "$RUN/followup-<id>.md")" --json
     ```
   - **Neither works:** start a fresh worker (§ Spawn step 2, on the existing worktree) and send a short catch-up prompt (issue, PR, current gate, decisions so far).
3. Update `dispatch_id` and `terminal` in `run.json` and watch as usual (§ Watch).
