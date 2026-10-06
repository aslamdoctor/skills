# Worker prompt templates

Fill the `<...>` slots from the setup table. Send each prompt with `scripts/send.sh`, reading the message from a heredoc on stdin. Keep project-specific rules (base branch, commit format, test setup, ship skill) in the prompt, because the worker doesn't know it's part of a run.

## Kickoff

```
You are a worker for <task: issue URL or one-line description>, run from an orchestrator agent in another Herdr tab. You are in a dedicated git worktree. Its branch already exists and was cut from <base-ref>. PRs target <pr-base>. Don't create branches or worktrees, and never git push until told.

Before starting read: <issue + comments via gh / the parent issue / project docs or notes / the repo instruction files (AGENTS.md, CLAUDE.md, ...)>. Follow the conventions of recent sibling work on this branch.<dependency note>

Test environment: <how tests run here; files to borrow from the main checkout (never commit them); separate test DB if supported>. Another worker may be running tests at the same time, so rerun a one-off DB failure before debugging it.

Work in gates. At each gate, run this command, then STOP and wait for my next message:
RUN=<run> <skill-scripts>/mark.sh <id> <gate> "<one-sentence status>" "<path, commit or PR URL>"
It updates the run record and the Herdr sidebar label. Ask questions in plain text; don't open interactive question dialogs. If you need a decision, mark gate 'question' with the question as the status, and stop.
GATE spec: <tracker bookkeeping, e.g. assign the issue to me and set it to In Progress>. Then write a short spec plus an implementation plan (files, classes or functions, signatures, risks, open questions) into <docs path>. Don't write code yet.
GATE implemented: after I approve the spec, implement it. <test policy>. Run <lint / type check commands> on the changed files, then commit following the repo's commit format.
GATE pr: after I say ship, run <ship skill or steps> with base <pr-base>.
```

**Dependency note**, when a task builds on another task in the same run: "Your dependency is <X>, which is on this branch" or "<Y> is being built in parallel on a separate branch, so don't depend on it, and raise it as an open question if the spec turns out to need it." Name the files both workers are likely to touch, and say which worker owns any shared entry (docs section, error-code list, registry line).

## Spec approval

```
Spec approved by <user>. Answers: 1) <...> 2) <...> 3) <...>. Then implement it and stop at GATE implemented (<lint>, the tests the task asks for, commit, mark.sh implemented with the commit hash). Don't push.
```

## Ship

```
Ship approved by <user>. Fetch origin and rebase on origin/<pr-base> if it has moved. Run <ship skill> with base <pr-base> and push. Keep borrowed env files and symlinks out of every commit. Answers for the skill: <pre-answered questions, e.g. automated local QA: No (local site points at the main checkout); staging: skip; reviewer: <name>>. For review-bot findings: verify them, then stop and report them in plain text. Do the same for any thread replies, which <user> approves before you post. At the end, mark gate pr with the final status and the PR URL.
```

**Stacked ship**, when the base is another unmerged task branch: set the PR base to the parent branch, add "Stacked on PR <n>. Retarget to <pr-base> after it merges." under the implementation notes, and link the issue to the PR directly (closing keywords don't link on a non-default base).

## Relaying answers

Quote the user's decision exactly and add only routing details (which commit or thread it refers to). Example: "<user>'s answer for <question>: fix both threads. Then push, draft the thread replies and stop so <user> can approve them."
