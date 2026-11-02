# Smith: herdr-app backend

Date: 2026-11-02
Status: draft, awaiting approval

## Intent

`smith` (`skills/smith/`) runs several coding tasks in parallel from one orchestrator session. Each task gets a git worktree and a worker agent that stops at gates (spec, implemented, pr), so the user approves every decision. Today it runs only inside Herdr TUI (`references/herdr.md`, `scripts/`).

Herdr has shipped a native desktop app ("Herdr", `herdr-app`) built on a new core, herdr-core, driven by the `hc` CLI. The app and the TUI don't share agents, so smith can't run in the app today: `HERDR_ENV` isn't set there and smith's backend check stops. The user's TUI setup works and stays. This adds the app as a second backend, and uses what the app does better than the TUI instead of just porting the herdr scripts.

## Goals

- Same `/smith` and trigger phrases, same user-facing flow (setup table, gate reports with recommendations, the user approves every spec, ship and posted text, stacked branches, ship pre-answers, wrap-up, resume). Worker naming stays `Smith-<id>`.
- Use hc natively: workers are hc children of the orchestrator, they report gates by message, and the orchestrator waits on its children rather than running one watcher per worker.
- A **space per run**, one tab per task, and a **Smith board** tab (a mod) that shows the run live.
- **Clickable toasts** come from Herdr itself (blocked, and turn done while not looking); smith adds none (user's decision, see Toasts).
- ~~Per-kind hc templates~~: dropped (my call). A template's `command` is fixed in its frontmatter and `hc run <template> "<task>"` takes no extra launch arguments, so Claude's per-worker `--session-id`/`--resume` and agy's `-i "<task>"` can't go through one. Workers launch directly (`hc run ... claude --session-id <uuid> "<kickoff>"`, `agy -i "<kickoff>"`, `pi "<kickoff>"`), and the standing instructions stay in the kickoff from prompts.md as on the TUI. A per-kind launch table (in `agents.tsv` or `herdr-app.md`) replaces the templates.
- The orchestrator can use `herdr-app shot` to look at a worker's dialog the way the user sees it.
- Resume with full conversation for Claude Code via a preassigned session ID.

## Agent support (user's priorities)

| Agent | Role | v1 level |
|---|---|---|
| Claude Code | Main worker and orchestrator | Full: gates, status, blocked reasons, resume with full conversation |
| agy | Secondary worker | Full gates and status. Resume: full conversation only if its conversation ID can be found cheaply (builder checks); otherwise the catch-up prompt |
| Pi | Experimental | Best effort: template exists, status reporting confirmed, not tested end to end |

Other kinds hc recognizes may be passed with `--kind`, unlisted in the setup table as "untested".

## Non-goals

- Any change to the herdr TUI backend's behaviour.
- Remote machines (`hc run --on`, `space.new --machine`). Local only in v1.
- Board buttons that approve a spec or ship. Decisions go through the orchestrator so it relays the user's exact words.
- Porting the TUI's tier table or `--cmd` custom-agent mode.

## Anti-goals

- A regression on the TUI path: running `/smith` in Herdr TUI after this change must look the same.
- Workers posting anywhere without the user's approval.
- Lost gates, duplicate questions, a worker silently idle at a gate, or a gate reported at spawn before any work happened.
- Workers dying because the orchestrator session ended.

## Verified behaviour (probes run 2026-11-02, hc 0.1.16)

| Fact | Detail |
|---|---|
| Detection | Inside the app: `HC_TERMINAL_ID` (e.g. `t9`) and `HC_TERMINAL_SOCKET` set, `HERDR_ENV` unset |
| Status | Claude (`app: claude-code`), agy (`app: antigravity`) and Pi (`app: pi`) all report status to hc (`reported: true`). States seen: `idle`, `working`, `done` (agy puts its reply in `msg`), `blocked` with a `kind` (`auth`, `permission`) and `msg` ("Trust this folder?"), `error` with `msg` |
| Boot idle | Claude reports `idle` at `turn: 0` before its first prompt runs. A wait that ends there is not a gate |
| Parent notes | A child that blocks, errors or exits gets a note typed into its parent terminal automatically, e.g. `<hc>t15 probe-agy exited (exit 2). Last lines: ...</hc>`. Turn ends (`done`) do not produce notes |
| Wait and events | `hc wait <t>` returns on each state change with `reason: status`; `hc events --terminal <t>` streams `status` and `turn` events as JSON lines |
| First task | `hc run claude "<task>"` delivers the task. agy rejects a positional prompt (exit 2) and needs `agy -i "<task>"` |
| Folder trust | agy asked "Trust this folder?" (`blocked`, `kind: permission`) in a new folder; `hc keys <t> enter` accepted it. Claude didn't ask in that folder; new worktree paths may still ask |
| Session IDs | hc doesn't expose agent session IDs (`records` empty). Claude's transcript lands at `~/.claude/projects/<cwd-slug>/<uuid>.jsonl` |
| Placement | A terminal labelled `herdr.space=<id>` and `herdr.tab=<id>` shows up in that space/tab; an unknown tab id becomes a new tab. Unlabelled terminals stay hidden |
| Lifetime | Children end with their parent by default (`die_with_parent: true`); `--outlive-parent` keeps them |

## Design decisions (user's)

- herdr-app is an additional backend; the TUI backend is unchanged.
- All of the benefits listed under Goals are in v1.
- Agent priorities as in the table above.
- Board layout and content as below, with no decision buttons.
- No smith toasts; Herdr's native toasts are enough.

## Backend selection

SKILL.md § 0 gets a second row:

| Condition | Backend |
|---|---|
| `HERDR_ENV=1` | herdr |
| `HC_TERMINAL_ID` set and `hc server status` succeeds | herdr-app |
| Both | ask the user once (my call) |
| Neither | say smith needs a Herdr TUI pane or the Herdr app, and stop |

`run.json` records `"backend": "herdr-app"`. A run.json without `backend` is a herdr TUI run. Resume only with the run's own backend (restore the check removed with Orca). herdr-app runs live in `~/.smith/runs/<repo>-<YYYY-MM-DD>-app` so they never collide with a TUI run from the same day (my call).

## Flow on herdr-app

**Preflight.** Check the env, find the orchestrator's own kind (`hc get $HC_TERMINAL_ID` → `status.app`), record the orchestrator's hc address in run.json, install the board mod (symlink), create the run dir.

**Space.** One space per run, named `smith <repo> <date>` (or the task IDs), folder = repo root, created with `herdr-app do space.new`. The orchestrator stays in its own tab where the user started it. `space.new` shows the new space at once, so smith selects the orchestrator's space again right after (`space.select`, my call), and does the same after creating each tab. The space's first tab is the board (`tab.new --mod smith-board --props {"run": "<run dir>"}`); any default shell tab the space comes with is closed if smith created it.

**Spawn.** Worktree creation is unchanged from the TUI backend (`~/<repo>-wt/<branch>`, `WT_ROOT` override, reuse existing). Then start the worker as an hc child of the orchestrator:

- `hc run --bg --outlive-parent --name smith-<id> --cwd <wt> --label herdr.space=<space> --label herdr.tab=<new tab id> --label smith.run=<run> --label smith.task=<id> <kind launch> "<kickoff>"`
- Launch flags match the TUI backend's bare launch: default model and default permission mode for every kind (my call, parity with the TUI). No bypass or auto-accept modes.
- Name the tab `Smith-<id>` (rename after creation if the label route leaves it unnamed).
- Claude workers get `--session-id <uuid>` (generated by smith) in their launch args so resume needs no discovery. Record it in run.json.
- Check `first_message.sent`. If false, read the screen (`hc read`), bring any first-run dialog to the user, then send the kickoff. Never resend blindly.
- Record in run.json: kind, hc address and name, space, tab, session, worktree, branch, base.

**Gates.** Workers keep running `mark.sh <id> <gate> "<status>" "<ref>"` (same gate instruction text as the TUI, only the sidebar sentence changes). On this backend mark.sh also:
- sets labels `smith.gate=<gate>` on the worker,
- sends the orchestrator `hc send <orchestrator address> "[smith] GATE <gate> Smith-<id>: <status> | <ref>"` (address recorded in run.json at preflight).
mark.sh picks its behaviour from run.json's `backend`, so the worker command is identical on both backends.

**Watch.** Primary wake-ups are pushed, not polled: gate messages from mark.sh, and hc's own parent notes for blocked, error and exit. The orchestrator still needs one background check per run for **STOPPED** (a worker idle with no new gate for 15 min) and for gates whose `hc send` was dropped. That is one run-level watcher based on `hc events --label smith.run=<run>` (label-based, not `--children`, so it also covers workers adopted on resume; my call), not one per worker. It must ignore the boot `idle` at turn 0 and the 5-second blocked flash the TUI backend already handles. How it wakes a non-Claude orchestrator is the builder's call (hc send to the orchestrator is the obvious route).

**Read a worker.** `hc read <t> --lines 50`. For dialogs, also `herdr-app shot` and look at the image. Transcript fallback from `agents.tsv` as today.

**Relay answers.** `hc send <t> "<text>"`. hc refuses to send to a `blocked` worker; press `esc` first (`hc keys <t> esc`) as the TUI send.sh does, never `--force` past a permission decision. Confirm delivery from the next status change.

**Board.** A mod in `skills/smith/app/smith-board/` (`main.js`, `mod.json`), installed into `~/.config/herdr-app/mods/` by preflight (symlink, my call). It watches the run dir and redraws from run.json plus live agent status:

```
Smith · thrive-themes · 2026-11-02                    3 workers · 1 needs you
──────────────────────────────────────────────────────────────────────────────
● Smith-102  claude  NEEDS YOU   spec ready: 3 open questions      4m   [open]
◐ Smith-101  claude  working     implementing (after spec OK)     12m   [open]
○ Smith-103  agy     waiting     PR #5120 · Copilot review         1h   [open]
──────────────────────────────────────────────────────────────────────────────
  102  feat/102-lightbox-links   spec  docs/specs/102.md
  101  fix/101-empty-column      impl  a1b2c3d  "Fix empty column detection"
  103  fix/103-symbol-covers     pr    https://github.com/…/pull/5120
```

- Sort: needs you (new gate not yet answered, or blocked) first, then blocked, working, waiting, done/gone.
- Columns: state dot and word, last gate text, time in state, `[open]` (runs `agent.focus` on that worker).
- Bottom section: what `board.sh` prints today (branch, gate, spec/commit/PR).
- `board.sh` stays as the text version for chat reports.

**Toasts.** Smith posts no toasts of its own (user's decision). Herdr's native toasts already fire, with sound, when a worker blocks or finishes a turn while the user isn't looking, and clicking one focuses that worker. Gate text lives on the board and in the orchestrator's report. This avoids a duplicate toast per gate, and smith toasts that would silently stop after an app restart until the board mod was shown again.

**Wrap up.** Close only the worker tabs and space this run created, when the user agrees; `hc kill` + `hc rm` for its terminals. Keep worktrees and run.json until PRs merge. Never stop the core or the app.

**Resume.** First check each task's recorded hc address. A worker that is still live (it outlived the old orchestrator) is **adopted**, not restarted (my call): update run.json's orchestrator address so mark.sh's gate messages reach the new session, rely on the label-based watcher (hc gives no parent notes to a non-parent and can't re-parent), and send the follow-up prompt to it. Never run `--resume` on a session whose process is still alive. Only a worker that is gone gets restarted:

Claude: `smith-claude` with `--resume <session>`. agy: `--conversation <id>` if found, else catch-up prompt. Pi: `--session <id>` from its transcript, else catch-up. Recreate the space and board if they were closed.

## File layout (my call, builder may adjust)

```
skills/smith/
├── SKILL.md                 § 0 adds herdr-app; flow text stays backend-neutral
├── references/
│   ├── herdr.md             unchanged
│   ├── herdr-app.md         new: the sections above (Preflight, Spawn, Watch, Read a worker, Relay answers, Board, Wrap up, Resume, Agent support)
│   ├── prompts.md           gate instruction sidebar sentence made backend-neutral
│   └── gotchas.md           new "Herdr app" section (agy -i, boot idle, trust prompt, send refused when blocked)
├── scripts/                 TUI scripts unchanged; mark.sh and lib.sh branch on run.json backend
├── scripts/app/             spawn/send/watch for herdr-app
└── app/
    └── smith-board/         the board mod
```

## Constraints

- Shell: bash, jq, git (as today). Board mod: the app's mod JS API (`~/.config/herdr-app/AGENTS.md`, `herdr.d.ts`); every mod change must pass `herdr-app check` and be confirmed with `herdr-app shot`.
- Don't touch the user's other spaces, tabs, terminals, mods or settings. `hc ls` shows the user's other live work.
- hc is 0.1.x; pin behaviour to what's verified above and note the version in gotchas.

## Left to the builder

- Exact script split and names, how mark.sh detects the backend, and how much of lib.sh is shared.
- The run-level watcher's mechanics and how it wakes a non-Claude orchestrator.
- How the space's first tab and the board tab get created given `space.new` has no mod argument.
- Where agy stores conversation IDs, and whether that's cheap enough for v1.
- README updates (they go through the humanizer skill before commit).
