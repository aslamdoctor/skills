# Smith Orca Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/smith` run inside Orca as well as Herdr, picking the backend from where it runs, with the Orca side built on `orca orchestration`.

**Architecture:** SKILL.md keeps the backend-neutral flow and a backend-selection step. Every backend-specific step moves into `references/herdr.md` (moved text, unchanged) or `references/orca.md` (new). Both files use the same section names so SKILL.md can point at "§ Spawn" in either. Prompts and gotchas get per-backend variants. The herdr scripts don't change.

**Tech Stack:** Markdown (Agent Skills format), the `orca` CLI 1.4.245 (`orca orchestration`, `orca worktree`, `orca search`), `jq`, `bash`.

**Spec:** `docs/superpowers/specs/2026-10-31-smith-orca-backend-design.md`

## Global Constraints

- No change in herdr behavior: every herdr command and rule in today's `skills/smith/SKILL.md` must still be in `SKILL.md` or `references/herdr.md`, unchanged.
- `skills/smith/scripts/` stays byte-identical (`git diff --quiet HEAD -- skills/smith/scripts` passes at every commit).
- Orca workers are Claude Code in v1. Other kinds are allowed but labeled "best-effort: gates may not hold" in the setup table.
- Local Orca only, no `--on` and no remote servers.
- Worker name `Smith-<id>` (display name, task title, card comment prefix).
- Run record `~/.smith/runs/<repo>-<YYYY-MM-DD>/run.json` with `"backend": "herdr" | "orca"`. A run.json with no `backend` field means herdr.
- Use the Orca executable resolved per the orca-cli guide (`ORCA_CLI_COMMAND`, else `orca-dev` in a dev checkout, else `orca-ide` on Linux outside Orca, else `orca`). Docs write `orca` and say this once.
- Repo writing rules for user-facing text (README, SKILL.md prose): no em dashes, no exclamation points, no hard wrapping. README text goes through the `humanizer` skill before commit.
- Commits in this repo: short imperative subject, no Claude attribution lines.

## Review Focus

- A run started in Herdr after this change: the orchestrator must find the exact same spawn/send/watch commands as before. Task 1 Step 1 pins this with a command-line diff check.
- Both `HERDR_ENV=1` and Orca env present (Herdr launched inside an Orca terminal): smith asks once and doesn't silently pick one. Task 1 Step 3 wording, checked in Task 6 Step 2.
- A delivery not acked: old messages replay and get reported twice. `orca.md` § Watch must say to ack after every batch. Task 2 Step 1 greps for it; Task 6 exercises it.
- `orca worktree create --branch <name>` when the name is taken: Orca adds a numeric suffix. Spawn must compare the created branch to the requested one and stop on mismatch. Task 2 Step 1 greps for it; Task 6 Step 3 exercises it.
- Old run.json from before this change (no `backend` field) resumed from an Orca terminal: smith must tell the user it's a herdr run and needs Herdr, not try Orca commands on herdr IDs. Task 1 Step 3 wording, Task 6 Step 2 check.

---

### Task 1: Split SKILL.md into neutral flow + references/herdr.md

**Files:**
- Modify: `skills/smith/SKILL.md`
- Create: `skills/smith/references/herdr.md`
- Create (scratch, not committed): `$SCRATCH/herdr-lines.sh`

**Interfaces:**
- Produces: section names used by both backend files, exactly: `## Preflight`, `## Spawn`, `## Watch`, `## Read a worker`, `## Relay answers`, `## Board`, `## Wrap up`, `## Resume`, `## Agent support`. SKILL.md refers to them as "`references/<backend>.md` § <name>", where `<backend>` is `herdr` or `orca`.

- [ ] **Step 1: Write the preservation check**

`$SCRATCH/herdr-lines.sh` extracts every command-ish line from the committed SKILL.md and fails if any is missing from the new SKILL.md + herdr.md:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/skills/smith"
missing=0
while IFS= read -r line; do
	[ -z "$line" ] && continue
	cat SKILL.md references/herdr.md 2>/dev/null | rg -qF -- "$line" || { echo "MISSING: $line"; missing=1; }
done < <(git show HEAD:skills/smith/SKILL.md | rg -o '`[^`]*(herdr|S/|RUN=|HERDR|nohup|pkill)[^`]*`' ; git show HEAD:skills/smith/SKILL.md | rg '^(RUN=|nohup|ln -s)')
git diff --quiet HEAD -- scripts || { echo "scripts changed"; missing=1; }
exit $missing
```

- [ ] **Step 2: Run it against an empty herdr.md to see it fail**

Run: `mkdir -p references && : > references/herdr.md && bash $SCRATCH/herdr-lines.sh; rm references/herdr.md`
Expected: exit 0 (nothing moved yet, all lines still in SKILL.md). Then temporarily delete section 2 from SKILL.md in the working tree and rerun. Expected: `MISSING:` lines and exit 1. Restore with `git checkout SKILL.md`.

- [ ] **Step 3: Do the split**

Move into `references/herdr.md` under the section names above, word for word: the Agent support tier table and its D note; preflight steps 1-3 (HERDR_ENV check, own kind via `herdr agent get`, integration status); all of section 2; all of section 3; the screen-reading commands in 4.1; the `send.sh` relay and re-arm in 4.3; the `board.sh` line; the herdr commands in sections 6 and 7; the rules "Never focus or close tabs you didn't create. Never stop the Herdr server." and "If one opens an interactive dialog anyway, `send.sh` presses Esc".

SKILL.md then has:
- Frontmatter description: "from one Herdr pane" becomes "from one Herdr pane or Orca terminal", "Each task gets its own git worktree, a background Herdr tab and a worker agent" becomes "...a background Herdr tab or Orca workspace...", "show their gate in the Herdr sidebar" becomes "show their gate in the Herdr or Orca sidebar", "Requires Herdr (HERDR_ENV=1)." becomes "Requires Herdr (HERDR_ENV=1) or Orca." Keep every trigger phrase.
- New first section `## 0. Pick the backend` with the spec's table (HERDR_ENV=1 → herdr; `ORCA_TERMINAL_HANDLE` set and `orca status --json` `.ok == true` → orca; both → ask the user once with the structured question tool; neither → say smith needs Herdr or Orca, stop). Then: "Read `references/<backend>.md` now and use its sections wherever this file says § <name>. Read `references/gotchas.md` (Common plus your backend's section) before the first run in a session."
- Resume rule: "run.json without a `backend` field is a herdr run. Resume a run only with its own backend; if it doesn't match where you are, tell the user and stop."
- Each remaining section keeps its neutral text (task picking, setup table, gate report content in 4.2, ship, rules about approval) and replaces moved text with one line, e.g. "Spawn each worker: `references/<backend>.md` § Spawn."
- Setup table gets a row: "Worker kind per task | Default: your own kind (herdr). On orca: claude; other kinds best-effort, label them 'gates may not hold'."
- Install section unchanged.

- [ ] **Step 4: Run the preservation check**

Run: `bash $SCRATCH/herdr-lines.sh`
Expected: exit 0, no output.

- [ ] **Step 5: Read-through**

Run: `rg -n 'herdr|Herdr' SKILL.md`
Expected: only the backend table, the description, the setup-table row and the install notes mention Herdr. No herdr command remains in SKILL.md.

- [ ] **Step 6: Commit**

```bash
git add skills/smith/SKILL.md skills/smith/references/herdr.md
git commit -m "Move smith's herdr steps into references/herdr.md"
```

### Task 2: references/orca.md

**Files:**
- Create: `skills/smith/references/orca.md`

**Interfaces:**
- Consumes: Task 1's section names.
- Produces: run.json task fields for orca, used by Tasks 3 and 6: `id, branch, base, kind, worktree_id, worktree_path, task_id, dispatch_id, terminal, gate, gate_text, pr, session, updated`; run-level `backend: "orca"`, `orca_run_id`.

- [ ] **Step 1: Write the acceptance check**

```bash
f=skills/smith/references/orca.md
for s in '## Preflight' '## Spawn' '## Watch' '## Read a worker' '## Relay answers' '## Board' '## Wrap up' '## Resume' '## Agent support'; do rg -qF "$s" $f || echo "no section: $s"; done
for t in 'run-create' 'run-use --id' 'worktree create' '--branch' 'worker-start --worktree id:' 'check --wait' '--ack' 'worker-read --dispatch' 'orchestration reply --id' 'send --to dispatch:' 'worker-list --run' 'worker-retain' 'worker-release' 'worktree rm' 'orca search' '--resume'; do rg -qF -- "$t" $f || echo "missing: $t"; done
```

Run it now. Expected: every line reported missing.

- [ ] **Step 2: Write orca.md**

One section per name, with the commands from the spec's "Orca backend: how each step works", as copy-pasteable blocks with `<...>` slots. Requirements per section:
- **Preflight:** resolve the executable once (rule from Global Constraints); `orca status --json`; own kind is the agent you are (no Orca lookup needed); load `orca skills get orchestration` once per session; create or reuse the Orca Run and write `backend`/`orca_run_id` into run.json.
- **Spawn:** the two-step `worktree create --name <slug> --branch <branch> --base-branch <base-ref> --no-parent --comment "Smith-<id>: starting"` then `worker-start --worktree id:<wt> --agent claude --task-title "Smith-<id>" --spec "<kickoff>"`. After create: `git -C <path> branch --show-current` must equal `<branch>`, else stop and tell the user (Orca suffixed a taken name). Stacked: `--base-branch <parent branch>` plus `--parent-worktree id:<parent wt>`. Record fields into run.json with `jq` (show the one `jq` update command). Exit non-zero from `worker-start`: read `failedStage`/`residualResources`, load Orca's `references/recovery-and-cleanup.md`, never relaunch.
- **Watch:** one background `check --wait --types "worker_done,escalation,question" --timeout-ms 3600000 --json` per run (Claude Code: `run_in_background`). Process every message in the batch, then `check --ack <deliveryId>`; say in bold that skipping the ack replays old messages. Map messages: `question` whose body starts `GATE <gate>:` → GATE report; other `question` → GATE question; `worker_done` → GATE pr (PR URL in body); `escalation` → BLOCKED. After three empty waits, `worker-list --run <run_id> --json` and act on `projection.attention`/`nextAction`; `liveness.verdict: exited` → GONE.
- **Read a worker:** `worker-read --dispatch <id> --limit 60 --json | jq '.result.transcript.messages'`, and `terminal read --terminal <handle> --screen --json` for dialogs.
- **Relay answers:** `reply --id <messageId>` for a pending ask, `send --to dispatch:<id>` for anything else; quote the user's words (link to prompts.md "Relaying answers").
- **Board:** one `jq` pipeline joining run.json tasks with `worker-list --run <run_id> --json` rows by `dispatch_id` → table columns `id | kind | branch | gate | liveness | PR`.
- **Wrap up:** `worker-retain` after each `worker_done` by default; release only on merge or the user's word; `worktree rm` only after confirming the PR merged (it deletes the branch). Never touch worktrees or terminals the run didn't create.
- **Resume:** `run-use --id`; same terminal alive → `worker-start --terminal <handle> --worktree id:<wt> --task-title "Smith-<id> fixes" --spec "<follow-up>"`; terminal gone → session from run.json, else `orca search "Smith-<id>" --path <worktree path> --json` → `resumeCommand`, then `terminal create --worktree id:<wt> --command "<resume command>"` and `worker-start --terminal <new handle> ...`; fallback fresh worker + catch-up prompt. Mark the terminal-gone route "verified in Task 6" or "unverified" depending on Task 6's result.
- **Agent support:** claude supported; other kinds Orca launches are best-effort, with the one-paragraph reason from the spec.

- [ ] **Step 3: Run the acceptance check**

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add skills/smith/references/orca.md
git commit -m "Add smith's Orca backend reference"
```

### Task 3: Orca variants in prompts.md

**Files:**
- Modify: `skills/smith/references/prompts.md`

**Interfaces:**
- Consumes: gate question format `GATE <gate>: <status> | <ref>` from Task 2 § Watch.

- [ ] **Step 1: Acceptance check**

```bash
f=skills/smith/references/prompts.md
rg -qF 'mark.sh <id> <gate>' $f || echo "herdr gate line lost"
for t in '### Gate instruction (orca)' 'orchestration ask' '--resume' 'never ask the same question twice' 'GATE spec:' 'worker_done' 'approved by' 'orchestration check --terminal'; do rg -qF -- "$t" $f || echo "missing: $t"; done
```

Run now. Expected: every orca line missing, herdr line present.

- [ ] **Step 2: Edit prompts.md**

Make the "Work in gates..." paragraph of the Kickoff a slot `<gate instruction>`, and add two blocks under it: `### Gate instruction (herdr)` holding the current paragraph word for word, and `### Gate instruction (orca)`, which says: at GATE spec and GATE implemented run the `ask` command from your Orca preamble with the question `GATE <gate>: <one-sentence status> | <path or commit>` followed by your open questions, and wait; if it times out, run the `--resume <messageId>` command it prints and never ask the same question twice; set the card with `orca worktree set --worktree active --comment "Smith-<id>: <gate>" --unread --json`; check `orchestration check --terminal <your handle>` before starting each new file and before every gate; at GATE pr, after the ship steps, send `worker_done --outcome succeeded` with the PR URL and stop. Add to the orca Ship template: "Pushing and opening the PR are approved by <user> with this message, which overrides your preamble's no-posting line for these two actions only. Thread replies and comments still need <user>'s approval through `ask`." Kickoff's first line says "in another Herdr tab" today: make it "in another <Herdr tab | Orca terminal>".

- [ ] **Step 3: Run the check.** Expected: no output.

- [ ] **Step 4: Run Task 1's preservation check.** Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/smith/references/prompts.md
git commit -m "Add Orca gate and ship variants to smith prompts"
```

### Task 4: gotchas.md sections

**Files:**
- Modify: `skills/smith/references/gotchas.md`

- [ ] **Step 1: Acceptance check**

```bash
f=skills/smith/references/gotchas.md
for t in '## Common' '## Herdr' '## Orca' 'replay' 'numeric suffix' 'deletes the branch' '10 minutes' 'no-posting' 'orca-ide' 'without --run' 'gates may not hold'; do rg -qF -- "$t" $f || echo "missing: $t"; done
[ "$(rg -c '^\|' $f)" -ge 26 ] || echo "rows lost"
```

Run now. Expected: missing lines.

- [ ] **Step 2: Edit gotchas.md**

Keep the table format. `## Common`: test DB collisions, dev site points at main checkout, borrowed vendor/env files, shared-entry merge conflicts, closing keywords on stacked PRs, QA bots skipping stacked PRs. `## Herdr`: every other existing row, unchanged. `## Orca`: one row each for the seven gotchas in the spec's "Gotchas to record" list, plus one for non-Claude workers ("gates may not hold": a kind that kills long commands can stop waiting or act without approval; use claude).

- [ ] **Step 3: Run the check.** Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add skills/smith/references/gotchas.md
git commit -m "Split smith gotchas by backend and add Orca ones"
```

### Task 5: READMEs

**Files:**
- Modify: `skills/smith/README.md`
- Modify: `README.md:9`

- [ ] **Step 1: Edit**

`skills/smith/README.md`: intro "from one Herdr pane" → "from one Herdr pane or Orca terminal". "What you get": worktree path line mentions Orca's `~/orca/workspaces/<repo>/<name>`; the watcher line gains "In Orca, workers ask through Orca's orchestration inbox and the workspace card shows the gate". Requirements: add "or Orca 1.4.245 or newer, with the orchestrator running in an Orca terminal". Agent support: add a sentence that on Orca only Claude Code workers are supported for now. "How it works" tree: add `references/herdr.md` and `references/orca.md`, and note scripts are herdr-only. Root `README.md:9`: "from one Herdr pane" → "from one Herdr pane or Orca terminal".

- [ ] **Step 2: Humanize**

Run the `humanizer` skill on the changed README prose (pattern removal only, keep structure). Apply its edits.

- [ ] **Step 3: Check**

Run: `rg -n '—|!' skills/smith/README.md README.md | rg -v '^\S+:\d+:\s*(```|<!--)'`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add skills/smith/README.md README.md
git commit -m "Document smith's Orca backend in the READMEs"
```

### Task 6: Live verification in Orca

Throwaway run in this repo following the new skill files, then record what was learned. No skill behavior is invented here; only facts go back into orca.md and gotchas.md.

**Files:**
- Modify: `skills/smith/references/orca.md`, `skills/smith/references/gotchas.md` (findings only)

- [ ] **Step 1: Run one task end to end**

Follow SKILL.md + orca.md as an orchestrator would, with task id `vtest`, branch `smith-vtest`, base `origin/main`, kind claude, and a kickoff whose task is "add one line to a scratch file `VTEST.md`, do not push". Pass the spec gate and implemented gate with replies. Answer "ship" with a modified ship step: "send worker_done with the commit hash instead of pushing".
Expected: GATE spec and GATE implemented questions arrive, card comment shows `Smith-vtest: <gate>`, `worker_done` arrives, board renders a row.

- [ ] **Step 2: Backend detection**

Run SKILL.md § 0's checks by hand: `env -u ORCA_TERMINAL_HANDLE bash -c '<check>'` and `HERDR_ENV=1 bash -c '<check>'`, plus a fake old run.json with no `backend` field.
Expected: neither → stop message; both → ask; no `backend` → treated as herdr and refused from Orca.

- [ ] **Step 3: Untested items from the spec**

Check and write down the result of each: `--unread` on the card; `worktree create --branch smith-vtest` a second time (suffix or attach); a follow-up Dispatch on the same terminal; resume after closing the terminal via `orca search` → `terminal create --command` → `worker-start --terminal`; first-run dialog on the new path (if none appears, say so).

- [ ] **Step 4: Record findings**

Update orca.md (mark the resume route verified or replace it with what worked) and add gotchas rows for anything new. Rerun Task 2 and Task 4 acceptance checks. Expected: no output.

- [ ] **Step 5: Clean up**

`worker-release` every dispatch of the run, `orca worktree rm` for `smith-vtest` worktrees, delete `~/.smith/runs/skills-<date>` only if this run created it. Run `git worktree list` and `git branch --list 'smith-vtest*'`. Expected: only the main checkout, no branches.

- [ ] **Step 6: Commit**

```bash
git add skills/smith/references/orca.md skills/smith/references/gotchas.md
git commit -m "Record Orca verification results in smith references"
```
