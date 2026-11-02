# Smith herdr-app backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `/smith` run inside the Herdr desktop app (herdr-core, `hc`) as a second backend, with a space per run, hc-child workers, pushed gate messages, one run-level watcher and a live board mod, while the Herdr TUI path stays unchanged.

**Architecture:** New scripts under `skills/smith/scripts/app/` drive `hc` and `herdr-app`; the TUI scripts in `scripts/` stay as they are, except `lib.sh` (new helpers), `mark.sh` and `board.sh`, which branch on `run.json`'s `backend`. A gpui-kit mod in `skills/smith/app/smith-board/` renders the run from `run.json` and live agent status. All shell behaviour is tested with bats against stub `hc`, `herdr-app` and `herdr` binaries, then one live end-to-end run in a scratch repo.

**Tech Stack:** bash, jq, git, bats, shellcheck, hc 0.1.16, herdr-app mod API (`~/.config/herdr-app/herdr.d.ts`, `AGENTS.md`).

**Spec:** `docs/superpowers/specs/2026-11-02-smith-herdr-app-backend-design.md`

## Global Constraints

- herdr TUI backend behaviour must not change: `/smith` in Herdr TUI looks the same, and every TUI script path that doesn't read `backend` is untouched.
- Backend rule: `HERDR_ENV=1` → herdr; `HC_TERMINAL_ID` set and `hc server status` succeeds → herdr-app; both → ask the user once; neither → "smith needs a Herdr TUI pane or the Herdr app", stop.
- `run.json` records `"backend": "herdr-app"`; no `backend` means a herdr TUI run. Resume a run only with its own backend.
- Run dir for this backend: `~/.smith/runs/<repo>-<YYYY-MM-DD>-app`. hc label `smith.run=<basename of RUN>`.
- Worker names: hc name `smith-<id>` (via `new_agent_name`), tab and display name `Smith-<id>`.
- Workers launch with `--outlive-parent`, default model and default permission mode. No bypass or auto-accept flags. Never `hc send --force`.
- Gate message text, exactly: `[smith] GATE <gate> Smith-<id>: <status> | <ref>`.
- Space name `smith <repo> <date>`, folder = repo root. After every `space.new` or worker tab creation, `space.select` back to the orchestrator's space (its `herdr.space` label from `hc get $HC_TERMINAL_ID`).
- Smith posts no toasts on this backend.
- Never touch spaces, tabs, terminals, mods or settings the run didn't create. Never stop the core or the app.
- Shell edits: Edit tool for anything with `$`. Use `rg`, `fd`, `sd`, `jq`, `bun`; no grep/find/sed/node in scripts or test commands you run (scripts that ship may use POSIX tools already used in `scripts/`: awk, tr, wc, tail).
- Commits: plain imperative subject like recent history (`Add ...`, `Fix ...`), one logical change each, no Co-Authored-By or Claude Code lines.
- README and committed docs prose goes through the `humanizer` skill (pattern removal only) before commit. No em dashes or exclamation points anywhere.
- Every mod change passes `herdr-app check <mod folder>` and is confirmed with `herdr-app shot`.

## Review Focus

1. The orchestrator is mid-turn or showing a dialog when a worker runs mark.sh, so `hc send` is refused or lost: the gate must still reach the orchestrator once, via the watcher (Task 4 and Task 6 tests).
2. A kickoff with quotes, backticks, `$VARS` and newlines reaches the worker byte for byte through `hc run` argv (Task 3 test `kickoff_argv_is_exact`).
3. Spawn or resume for a task whose recorded terminal is still live: spawn.sh refuses instead of starting a second worker or running `--resume` on a live session (Task 3 test `refuses_live_worker`).
4. A TUI run.json (no `backend`) passed to mark.sh or board.sh never calls `hc` and keeps the exact herdr calls (Task 4 and Task 7 tests).
5. Wrap-up in a core with the user's own terminals and spaces: only addresses and ids recorded in run.json are killed or closed (Task 8 test `close_touches_only_run_terminals`).

---

## File Structure

| Path | Responsibility |
|---|---|
| `tests/smith/helper.bash` | bats setup: temp RUN dir, stub PATH, `stub_reply`, `stub_calls` |
| `tests/smith/stubs/{hc,herdr-app,herdr}` | One stub script copied three times: logs argv, answers from fixture files |
| `tests/smith/*.bats` | One file per script under test |
| `skills/smith/scripts/lib.sh` | Add `run_backend`, `worker_hc`, `hc_state`, `hc_status_ms`, `hc_turn` |
| `skills/smith/scripts/app/launch.tsv` | Per-kind launch and resume argv for hc |
| `skills/smith/scripts/app/preflight.sh` | Env check, run.json header, board mod link, space plus board tab (new and resume) |
| `skills/smith/scripts/app/spawn.sh` | Worktree, hc child in its own tab, run.json record |
| `skills/smith/scripts/app/send.sh` | Esc if blocked, `hc send`, confirm by state |
| `skills/smith/scripts/app/watch.sh` | Run-level watcher: dropped gates, STOPPED, BLOCKED/GONE for non-children |
| `skills/smith/scripts/app/close.sh` | Wrap up one task or the run |
| `skills/smith/scripts/mark.sh` | herdr-app branch: label, gate message, `gate_sent`, `needs_you` |
| `skills/smith/scripts/board.sh` | herdr-app state source |
| `skills/smith/app/smith-board/{main.js,mod.json}` | Board mod |
| `skills/smith/references/herdr-app.md` | Backend reference sections (§ Agent support, Preflight, Spawn, Watch, Read a worker, Relay answers, Board, Wrap up, Resume) |
| `skills/smith/SKILL.md`, `references/prompts.md`, `references/gotchas.md`, READMEs | Docs |

### run.json shape on herdr-app

```json
{
  "backend": "herdr-app",
  "orchestrator": {"address": "t9", "kind": "claude-code", "space": "sp…"},
  "space": "sp…", "board_tab": "tb…",
  "tasks": {"101": {"id": "101", "agent": "smith-101", "hc": "t21", "kind": "claude",
    "branch": "…", "base": "…", "worktree": "…", "space": "sp…", "tab": "tb…",
    "session": "<uuid>", "gate": "spec", "gate_text": "…", "ref": "…", "pr": "…",
    "gate_sent": true, "needs_you": true, "gate_lines": 3, "reported": {}, "updated": "…"}}
}
```

### Deviations from the spec (found while planning)

- `hc get` has no `first_message` field (checked against hc 0.1.16's key list). The kickoff goes in as the agent's own argv, so spawn.sh confirms delivery from state instead: `working`, `blocked`, or `turn > 0` within 60 s. `not_started` means read the screen before doing anything, same rule as the spec (never resend blindly).
- hc adds its own `where` label (e.g. `skills / 1`) to terminals. Ignore it; never set or remove it.
- Pi gets no session id at spawn in v1 (best effort), so a Pi resume falls back to the catch-up prompt unless the Task 3 live check shows an id in its transcript path.

`needs_you` is set true by mark.sh and false by send.sh. `reported` is the watcher's dedupe map (`{"stopped": <status_ms>, "blocked": <status_ms>, "gone": true}`).

---

### Task 1: Test harness and lib.sh hc helpers

**Files:**
- Create: `tests/smith/helper.bash`, `tests/smith/stubs/hc`, `tests/smith/stubs/herdr-app`, `tests/smith/stubs/herdr`, `tests/smith/lib.bats`
- Modify: `skills/smith/scripts/lib.sh` (append after `pane_alive`)

**Interfaces:**
- Produces (helper.bash): `setup` makes `RUN=$BATS_TEST_TMPDIR/run` and `STUB_DIR=$BATS_TEST_TMPDIR/stub`, prepends `tests/smith/stubs` to PATH, exports `S=skills/smith/scripts`. `stub_reply <cmd> <key> <json> [exit]` writes `$STUB_DIR/<cmd>.<key>.json` (and `.exit`). `stub_calls <cmd>` prints the call log. `write_run <json>` writes `$RUN/run.json`.
- Produces (stub contract): each call appends `printf '%q ' "$@"` plus newline to `$STUB_DIR/<cmd>.log`. Reply key = subcommand words joined with `.` up to the first argument starting with `-` or the 3rd word, e.g. `hc get t21` → `get.t21`, `herdr-app do tab.new --mod x` → `do.tab.new`. Falls back to key of the first word only, then prints `{}` exit 0. `hc events` reads its lines from `$STUB_DIR/hc.events.jsonl` and then sleeps until killed.
- Produces (lib.sh): `run_backend` → `herdr` or `herdr-app`; `worker_hc <id>` → run.json `hc` else `worker_agent`; `hc_state <addr>` → `working|idle|done|blocked|error|gone` (gone when `hc get` fails or `.state != "live"`; `.status.state`, empty status → `idle`); `hc_status_ms <addr>` → `.status_ms` or 0; `hc_turn <addr>` → `.turn` or 0. All never fail under `set -e`.

- [ ] **Step 1: Write the stubs, helper and failing tests**

`lib.bats` tests: `run_backend_defaults_to_herdr` (run.json `{"tasks":{}}` → `herdr`), `run_backend_reads_field` (`herdr-app`), `hc_state_maps_status` (stub `get.t21` `{"state":"live","status":{"state":"blocked"}}` → `blocked`), `hc_state_finished_is_gone` (`{"state":"finished"}` → `gone`), `hc_state_missing_is_gone` (exit 1 → `gone`), `hc_state_null_status_is_idle`, `worker_hc_prefers_address`.

- [ ] **Step 2: Run, expect failures**

Run: `bats tests/smith/lib.bats`
Expected: FAIL, `run_backend: command not found`.

- [ ] **Step 3: Add the helpers to lib.sh**

`hc get <addr> --json` is the only source; parse with `jq -r ... // empty`.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bats tests/smith/lib.bats && shellcheck -x skills/smith/scripts/lib.sh`
Expected: all pass, no shellcheck warnings beyond ones already present before the change (check with `git stash` if unsure).

- [ ] **Step 5: Commit** `Add herdr-app helpers and bats harness for smith`

---

### Task 2: preflight.sh and launch table

**Files:**
- Create: `skills/smith/scripts/app/preflight.sh`, `skills/smith/scripts/app/launch.tsv`, `tests/smith/preflight.bats`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces: `RUN=<run> preflight.sh [--resume]` run in the repo. Exits 1 with `{"error":"..."}` when `HC_TERMINAL_ID` is unset or `hc server status` fails. Otherwise writes `backend`, `orchestrator.{address,kind,space}` (address = `HC_TERMINAL_ID`, kind = `.status.app`, space = `.labels["herdr.space"]` from `hc get $HC_TERMINAL_ID --json`), links `~/.config/herdr-app/mods/smith-board` → `skills/smith/app/smith-board` (skip if already that link; error if a different file exists there), and ensures the space and board tab. Prints run.json's top level minus `tasks` as one JSON line.
- Space logic: if run.json `space` exists in `herdr-app ls` spaces, keep it; else `herdr-app do space.new --name "smith <repo> <date>" --folder <repo root>` (record `.space`, remember its default first tab), then `herdr-app do tab.new --space <space> --mod smith-board --name Board --props '{"run":"<RUN>"}'` (record `.board_tab`), then `herdr-app do tab.close --id <default tab> --confirmed true` for the default tab only when this call created the space, then `herdr-app do space.select --id <orchestrator space>`. If the space exists but `board_tab` is gone, recreate only the board tab. `--resume` also overwrites `orchestrator.*` with the current session (adoption).
- Produces: `launch.tsv` columns `kind  fresh_argv  resume_argv` with `{session}` and `{prompt}` slots, argv words tab-free and space-separated, `{prompt}` always a single final word:
  - `claude	claude --session-id {session} {prompt}	claude --resume {session} {prompt}`
  - `agy	agy -i {prompt}	<filled by Task 3 Step 6, else ->`
  - `pi	pi {prompt}	pi --session {session} {prompt}`

- [ ] **Step 1: Write failing tests** in `preflight.bats`: `fails_without_hc_terminal`, `fails_when_server_down` (stub `server.status` exit 1), `records_backend_and_orchestrator` (`.backend == "herdr-app"`, `.orchestrator.address == "t9"`, `.orchestrator.kind == "claude-code"`), `creates_space_board_and_selects_back` (stub log order: `do space.new`, `do tab.new … --mod smith-board`, `do tab.close`, `do space.select --id <orch space>`; props JSON contains RUN), `reuses_existing_space` (space id present in stub `ls` → no `space.new`), `resume_updates_orchestrator` (old `t5` replaced by `t9`), `refuses_foreign_mod_dir` (a real dir at the link path → exit 1, dir untouched). Use `HOME=$BATS_TEST_TMPDIR/home` so the link goes to a temp config.
- [ ] **Step 2: Run** `bats tests/smith/preflight.bats`. Expected: FAIL, script missing.
- [ ] **Step 3: Implement preflight.sh** (`set -euo pipefail`, source `../lib.sh`). Get the default tab id from `space.new`'s printed `{space, tab, terminal}`.
- [ ] **Step 4: Run** `bats tests/smith/ && shellcheck -x skills/smith/scripts/app/preflight.sh`. Expected: PASS.
- [ ] **Step 5: Live check** (inside the app, scratch repo `git init` under the scratchpad): run preflight, then `herdr-app ls | jq '.spaces[].name'` shows `smith <repo> <date>` with one tab, focus is back on the orchestrator's space (`herdr-app status`). The board tab may show a mod load error until Task 7; that's expected. Close the scratch space afterwards with `herdr-app do space.close --id <id> --confirmed true`.
- [ ] **Step 6: Commit** `Add herdr-app preflight for smith`

---

### Task 3: spawn.sh

**Files:**
- Create: `skills/smith/scripts/app/spawn.sh`, `tests/smith/spawn.bats`
- Modify: `skills/smith/scripts/app/launch.tsv` (agy resume column, Step 6)

**Interfaces:**
- Consumes: run.json `space`, `orchestrator.space` (Task 2), `launch.tsv`, Task 1 helpers.
- Produces: `RUN=<run> spawn.sh <id> <branch> <base-ref> [--kind claude|agy|pi|<other>] [--resume <session>] < prompt.txt`. Prompt from stdin (may be empty on `--resume`). Kind default `$AGENT_KIND` or `claude`. A kind missing from launch.tsv runs as `<kind> {prompt}` and prints a warning line `{"warning":"kind <k> is untested on herdr-app"}` to stderr.
- Behaviour:
  1. Error `{"error":"worker smith-<id> is still live (tN); adopt it, don't respawn"}` exit 3 when the recorded `hc` (or name `smith-<id>`) has `hc_state` other than `gone`.
  2. Worktree exactly as `scripts/spawn.sh` lines 31-42 (copy, same `WT_ROOT` rule and `--unset-upstream`).
  3. Session: claude fresh → `uuidgen | tr A-Z a-z`; `--resume` → the given session; others empty. A resume on a kind whose `resume_argv` is `-` starts fresh and warns "send a catch-up prompt".
  4. Build argv from launch.tsv by splitting on spaces, replacing `{session}` and putting the whole stdin text as the one `{prompt}` word (drop `{prompt}` when stdin is empty).
  5. `hc run --bg --json --outlive-parent --name smith-<id> --cwd <wt> --label herdr.space=<space> --label herdr.tab=smith-<id> --label smith.run=<basename RUN> --label smith.task=<id> -- <argv…>`; read `.address`.
  6. Find the tab: `herdr-app ls` → the tab whose terminals include that address; `herdr-app do tab.rename --id <tab> --name Smith-<id>`; `herdr-app do space.select --id <orchestrator.space>`.
  7. Wait up to 60 s, every 2 s, for `hc_state` = `working`, `blocked` or `gone`, or `hc_turn` > 0. Status printed: `working`, `blocked`, `gone`, or `not_started` (still idle at turn 0).
  8. Record task fields `agent, hc, kind, branch, base, worktree, space, tab, session, needs_you:false, gate //= "started", updated`; print the task record plus `status` as one JSON line.

- [ ] **Step 1: Write failing tests**: `kickoff_argv_is_exact` (stdin `It's "x" $HOME \`y\`` plus a second line; the `hc run` log line, unquoted with `eval`, ends with exactly that text as one word), `claude_gets_session_id` (log has `--session-id <uuid>` and run.json `.session` equals it), `resume_uses_resume_argv`, `agy_uses_dash_i`, `refuses_live_worker` (stub `get.smith-101` live → exit 3, no `run` in log), `labels_and_outlive_parent` (log has all four labels and `--outlive-parent`, no `--force`, no `--dangerously`), `selects_orchestrator_space_back`, `records_task` (fields above). Worktree tests use a temp git repo with a bare `origin` (copy the setup used by `git worktree add` in scripts/spawn.sh).
- [ ] **Step 2: Run** `bats tests/smith/spawn.bats`. Expected: FAIL.
- [ ] **Step 3: Implement spawn.sh.** Build argv as a bash array; never pass the prompt through `eval` or word splitting.
- [ ] **Step 4: Run** `bats tests/smith/ && shellcheck -x skills/smith/scripts/app/spawn.sh`. Expected: PASS.
- [ ] **Step 5: Live check**: in the scratch repo after preflight, spawn `--kind claude` with prompt `Reply with the word ready and stop.` Expected: a `Smith-<id>` tab in the run space, focus stays on the orchestrator, status `working` or `blocked` (folder trust). Read it with `hc read <t> --lines 30`, record what dialog (if any) appeared, then `hc kill` + `hc rm` it.
- [ ] **Step 6: agy conversation id**: spawn one agy worker the same way (accept trust with `hc keys <t> enter` only in the scratch repo), then look for its conversation id on disk (`fd -t f -c never . ~/.gemini ~/.antigravity* --changed-within 10m` and its `--help` for a list command). If an id can be read in one command, set the agy `resume_argv` to `agy --conversation {session} -i {prompt}` and teach spawn.sh to record it (a 10 s retry loop, like scripts/spawn.sh's session loop). Otherwise set it to `-`. Write the result in the Task 9 gotchas row. Kill and remove the probe.
- [ ] **Step 7: Commit** `Add herdr-app worker spawn for smith`

---

### Task 4: mark.sh on herdr-app

**Files:**
- Modify: `skills/smith/scripts/mark.sh`
- Create: `tests/smith/mark.bats`

**Interfaces:**
- Consumes: `run_backend`, `worker_hc`, run.json `orchestrator.address`.
- Produces: unchanged CLI. On herdr-app, after the gate log line and run.json update (skip `agent_session` and `report-metadata`, which are herdr calls): `hc label <hc> smith.gate=<gate>`; `hc send <orchestrator.address> "[smith] GATE <gate> Smith-<id>: <status> | <ref>"`; set `.tasks[id].gate_sent` to `true` when send exits 0 else `false`; always set `needs_you: true`. Prints `marked Smith-<id>: <gate>` as now, plus ` (orchestrator not reached; the watcher will report it)` when the send failed. Exit 0 either way.

- [ ] **Step 1: Write failing tests**: `app_sends_exact_gate_message`, `app_sets_gate_label`, `app_send_refused_sets_gate_sent_false` (stub `send` exit 1), `app_sets_needs_you`, `tui_run_never_calls_hc` (run.json without backend, `herdr` stub log has `pane report-metadata`, `hc` log absent), `tui_output_unchanged` (stdout equals `marked Smith-101: spec`).
- [ ] **Step 2: Run** `bats tests/smith/mark.bats`. Expected: app tests FAIL, TUI tests PASS.
- [ ] **Step 3: Implement** a `case "$(run_backend)"` around the session lookup and the sidebar block.
- [ ] **Step 4: Run** `bats tests/smith/ && shellcheck -x skills/smith/scripts/mark.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `Send gate messages from smith mark.sh on herdr-app`

---

### Task 5: send.sh for herdr-app

**Files:**
- Create: `skills/smith/scripts/app/send.sh`, `tests/smith/send.bats`

**Interfaces:**
- Produces: `RUN=<run> send.sh <id> [msg] < msg.txt`, same contract as `scripts/send.sh`: records `gate_lines` baseline, sets `needs_you:false`; when `hc_state` is `blocked`, `hc keys <hc> esc` then waits up to 4 s for it to clear (still blocked → `NOT DELIVERED: Smith-<id> is blocked on a dialog; read it first` exit 1); `hc send <hc> "<msg>"` (non-zero → `NOT DELIVERED …` exit 1); then up to 8 s for `working` or a turn change → `delivered to smith-<id> (working)` exit 0, else the `still '<state>'` message with `hc read <hc> --lines 30` exit 2. Never `--force`.

- [ ] **Step 1: Write failing tests**: `blocked_presses_esc_first` (log order `keys … esc` then `send`), `still_blocked_not_delivered` (no `send` in log), `never_force`, `delivered_on_working`, `clears_needs_you`, `message_with_quotes_exact`.
- [ ] **Step 2: Run** `bats tests/smith/send.bats`. Expected: FAIL.
- [ ] **Step 3: Implement.** Stub sequencing: let the stub serve `get.<hc>.N.json` on its Nth call when present (add this to the stub in this task and note it in helper.bash).
- [ ] **Step 4: Run** `bats tests/smith/ && shellcheck -x skills/smith/scripts/app/send.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `Add herdr-app send for smith`

---

### Task 6: Run-level watcher

**Files:**
- Create: `skills/smith/scripts/app/watch.sh`, `tests/smith/watch.bats`

**Interfaces:**
- Consumes: run.json `tasks.*.{hc,gate_sent,gate_lines,reported}`, `orchestrator.address`, Task 1 helpers.
- Produces: `RUN=<run> watch.sh [--grace <min>] [--notify]`. Env `SMITH_TICK` (seconds, default 60) and `SMITH_GRACE_SEC` (overrides `--grace`, tests only). Streams `hc events --label smith.run=<basename RUN> --json` and re-checks all tasks on every event line and on every tick (`read -t "$SMITH_TICK"`). A task closed by close.sh (`.closed == true`) is skipped. Checks, in order, per task:
  1. **GATE (dropped):** `gate_sent == false` → report `GATE`, set `gate_sent: true`.
  2. **GONE:** `hc_state` = `gone`, `reported.gone` unset, and the worker's `.parent` is not `orchestrator.address` (children already get hc's exit note) → report, set `reported.gone`.
  3. **BLOCKED:** state `blocked` for 5 s or more (`now_ms - status_ms >= 5000`), same non-child rule, `reported.blocked != status_ms` → report, set it.
  4. **STOPPED:** state `idle` or `done`, `hc_turn > 0`, `now_ms - status_ms >= grace`, gate log line count not above `gate_lines`, `reported.stopped != status_ms` → report, set it.
- Report text: `[smith] <WHAT> Smith-<id> (<state>): <last gate log line or "no gate line yet">. RUN=<RUN>`. Default mode prints it and exits 0 (for a background task that re-invokes the orchestrator). `--notify` sends it with `hc send <orchestrator.address>` and keeps running; a refused send retries every 15 s for up to 1 h before dropping that report, so it never types into a dialog.
- Exits 0 with `no live workers` when every task is closed or gone and reported.

- [ ] **Step 1: Write failing tests** (all with `SMITH_TICK=1`, `SMITH_GRACE_SEC=2`; macOS has no `timeout`, so each test starts the script in the background and kills it after 10 s): `reports_dropped_gate_once` (second invocation reports nothing for that task), `ignores_boot_idle` (idle, turn 0, old `status_ms` → no report), `blocked_flash_not_reported` (`status_ms` = now), `blocked_child_left_to_hc` (parent = orchestrator → none), `blocked_adopted_reported` (parent `t5` ≠ `t9`), `stopped_after_grace` (idle, turn 3, old status_ms, no new gate line), `no_stopped_after_new_gate`, `notify_uses_hc_send`, `skips_closed_tasks`.
- [ ] **Step 2: Run** `bats tests/smith/watch.bats`. Expected: FAIL.
- [ ] **Step 3: Implement.** One `check_tasks` function, called from the read loop; all run.json writes through `run_update`. Kill the `hc events` child on exit (`trap`).
- [ ] **Step 4: Run** `bats tests/smith/ && shellcheck -x skills/smith/scripts/app/watch.sh`. Expected: PASS.
- [ ] **Step 5: Live check**: spawn a scratch claude worker with `Reply ready, then stop.`, run `SMITH_GRACE_SEC=30 RUN=… watch.sh` and expect `STOPPED Smith-<id>` within about 40 s of the turn ending, and nothing at boot. Clean up the worker.
- [ ] **Step 6: Commit** `Add herdr-app run watcher for smith`

---

### Task 7: Board (board.sh and the smith-board mod)

**Files:**
- Modify: `skills/smith/scripts/board.sh`
- Create: `skills/smith/app/smith-board/main.js`, `skills/smith/app/smith-board/mod.json`, `tests/smith/board.bats`

**Interfaces:**
- Consumes: run.json shape above; mod API `readTextFile`, `watchFolder`, `agents()`, `props()`, `run("agent.focus", {terminal})`.
- Produces (board.sh): on herdr-app the Status column's state comes from `hc_state "$(worker_hc "$id")"`; columns and TUI path unchanged.
- Produces (mod): `mod.json` `{ "place": "none", "title": "Smith" }`. `main.js` reads `props().run`, loads `<run>/run.json`, re-reads it on every `watchFolder(<run>)` resolution (re-arm after each), and takes live state from `agents()` matched by terminal address (task `hc`). Layout per the spec's board sketch: header `Smith · <repo> · <date>` with `<n> workers · <k> needs you`; one row per task with state dot and word, kind, last `gate_text`, time since `updated`, and an `[open]` control running `agent.focus` with the task's `hc`; bottom section with id, branch, gate, ref. Row state and sort order: `NEEDS YOU` (`needs_you` true or live state blocked), then `blocked`, `working`, `waiting` (idle/done without needs_you), `done/gone`. A missing or unreadable run.json shows one line `No run at <path>`, never a crash.

- [ ] **Step 1: Write failing bats tests**: `app_state_from_hc`, `tui_board_unchanged` (stdout for a TUI fixture equals the current output; capture it first from the current script).
- [ ] **Step 2: Run** `bats tests/smith/board.bats`. Expected: app test FAIL.
- [ ] **Step 3: Implement board.sh change.** Run `bats tests/smith/ && shellcheck -x skills/smith/scripts/board.sh`. Expected: PASS.
- [ ] **Step 4: Write the mod.** Read `~/.config/herdr-app/AGENTS.md` (mods section) and copy view and theme patterns from `~/.config/herdr-app/mods/agents/main.js`; use theme colours, no hard-coded palette.
- [ ] **Step 5: Verify the mod**: `herdr-app check skills/smith/app/smith-board` → no errors. Open it on the scratch run from Task 6 (preflight creates the tab), with one fixture run.json holding three tasks in different states, then `herdr-app shot <scratchpad>/board.png` and look at the image: sort order, needs-you count, and `[open]` focusing the right worker.
- [ ] **Step 6: Commit** `Add smith board mod and herdr-app board state`

---

### Task 8: Wrap up (close.sh)

**Files:**
- Create: `skills/smith/scripts/app/close.sh`, `tests/smith/close.bats`

**Interfaces:**
- Produces: `RUN=<run> close.sh <id>...` or `close.sh --all`. Per task: `hc kill <hc>` (ignore "not found"), `hc rm <hc>`, `herdr-app do tab.close --id <tab> --confirmed true` if the tab still exists in `herdr-app ls`, set `.tasks[id].closed: true`. With `--all`, also close `board_tab` and then `space` (only the ids in run.json, only if still present). Worktrees, branches and run.json are kept. Never calls `hc server`, `herdr-app quit` or `space.close` on any other id.

- [ ] **Step 1: Write failing tests**: `close_touches_only_run_terminals` (stub `ls` with user terminals t7, t8 and run terminals t21, t22; log kills only t21, t22), `close_all_closes_space_last`, `keeps_worktree_and_run_json`, `already_gone_is_fine`.
- [ ] **Step 2: Run** `bats tests/smith/close.bats`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bats tests/smith/ && shellcheck -x skills/smith/scripts/app/close.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `Add herdr-app wrap-up for smith`

---

### Task 9: References and SKILL.md

**Files:**
- Create: `skills/smith/references/herdr-app.md`
- Modify: `skills/smith/SKILL.md` (frontmatter description, § 0, § 1 step 1 run-dir wording, § 8 step 1), `skills/smith/references/prompts.md` (gate instruction), `skills/smith/references/gotchas.md`

**Interfaces:**
- Consumes: every script's CLI from Tasks 2-8.
- Produces:
  - SKILL.md § 0: the four-row table from Global Constraints. § 8 step 1 adds "Resume a run only with its own backend (`run.json` `backend`, none = herdr). If it differs from the current one, say so and stop." The description says "from one Herdr pane or the Herdr app" and "Requires Herdr (HERDR_ENV=1) or the Herdr app (hc)".
  - herdr-app.md sections with the same names herdr.md uses: Agent support (claude full, agy full with resume per Task 3 Step 6, pi best effort, others untested), Preflight (detect both, ask once; `S/app/preflight.sh`; worker kinds; run dir `-app`), Spawn (`S/app/spawn.sh … <<'EOF'` with the kickoff; on `blocked` read with `hc read` and `herdr-app shot`, bring the dialog to the user; on `not_started` read before anything else; never resend blindly), Watch (gate messages and hc notes arrive as typed `[smith]`/`<hc>` messages; arm one `S/app/watch.sh` per run, in the background for Claude, `nohup … --notify &` otherwise; re-arm after each report), Read a worker, Relay answers (`S/app/send.sh`), Board (the Board tab plus `S/board.sh` in chat), Wrap up (`S/app/close.sh`, user agrees first), Resume (`S/app/preflight.sh --resume`; live worker → adopt and send; gone → `S/app/spawn.sh … --resume <session>`; no session → catch-up prompt).
  - prompts.md: "It updates the run record and the Herdr sidebar label." becomes "It updates the run record and tells the orchestrator." Gate instruction heading becomes "Gate instruction" (same command for both backends).
  - gotchas.md: a `## Herdr app` table with rows for: agy needs `-i`; Claude's boot idle at turn 0; folder trust on new worktree paths; `hc send` refused while blocked (esc first, never `--force`); turn ends give no parent note (STOPPED comes from the watcher); hc 0.1.16 is the verified version; agy resume finding from Task 3.

- [ ] **Step 1: Write herdr-app.md and edit the other three files.**
- [ ] **Step 2: Check**: `rg -n '—|!' skills/smith/references/herdr-app.md skills/smith/SKILL.md` → no prose hits; every `§ <name>` used in SKILL.md exists as a heading in both herdr.md and herdr-app.md (`rg -o '§ [A-Z][a-z ]+' skills/smith/SKILL.md | sort -u`, compare with `rg '^## ' references/herdr*.md`).
- [ ] **Step 3: Humanizer pass** on the new and changed prose (pattern removal only, keep tables, code and headings).
- [ ] **Step 4: Commit** `Document smith's herdr-app backend`

---

### Task 10: READMEs and end-to-end run

**Files:**
- Modify: `README.md` (smith row), `skills/smith/README.md` (intro, What you get, Requirements, Usage, a herdr-app agent table, How it works tree)

- [ ] **Step 1: End-to-end run** inside the app, in a scratch repo with a bare origin under the scratchpad. Follow SKILL.md and herdr-app.md as an orchestrator would, task id `vtest`, branch `smith-vtest`, kind claude, kickoff task "add one line to `VTEST.md`, do not push". Pass the spec and implemented gates with replies. Replace ship with "mark gate pr with the commit hash instead of pushing". Expected: each GATE arrives as a typed `[smith] GATE …` message, the board shows the row moving NEEDS YOU → working → NEEDS YOU, `board.sh` matches, nothing shows up outside the run's space.
- [ ] **Step 2: Resume checks**: (a) adopt: start a second orchestrator Claude in the app, run preflight `--resume`, send a follow-up, confirm the gate message reaches the new session; (b) restart: `close.sh vtest`, then spawn `--resume <session>` and confirm the worker remembers the task. Write down any surprise in gotchas.md.
- [ ] **Step 3: TUI regression**: in a Herdr TUI pane, `bats tests/smith/` passes and a one-task run in a scratch repo reaches GATE spec with the sidebar label set, as before.
- [ ] **Step 4: Clean up**: `close.sh --all` on the scratch run, `git worktree list` in the scratch repo shows only the main checkout after removing `smith-vtest` worktrees, `hc ls` shows no `smith-*` terminals, the user's spaces are untouched.
- [ ] **Step 5: Update the READMEs**, then humanizer pass (pattern removal only).
- [ ] **Step 6: Commit** `Document smith's herdr-app backend in the READMEs`
