---
task-id: <task-id>                # immutable; matches the filename without `.md`
project: <project-name>           # user-maintained; label only; default = basename source-repo when omitted
source-repo: ~/workspace/<repo>   # required; supports ~/; absolute or ~/ form
state: not-analyzed               # not-analyzed | blocked | ready | completed
                                  # Legal user-written values are limited to the four above.
                                  # `in-progress` and `paused` are written ONLY by the orchestrator.
priority: normal                  # low | normal | high
branch: task/<task-id>            # default; override if needed
base: main                        # merge target branch; override if needed
worktree: ~/.zyz-worker/worktrees/<project>/task/<task-id>
tmux-session: zyz-task-<task-id>
blocked-by: []                    # [<task-id>, ...]; user-maintained
merged-with: []                   # [<task-id>, ...]; user-maintained
deps-tentative: true              # orchestrator clears to false only when user approves the analysis
last-seen:                        # orchestrator-only; updated on every fresh heartbeat
heartbeat-stale-sec: 300          # optional; per-task override of the stale threshold (seconds)
created-at: <yyyy-mm-dd>
updated-at: <yyyy-mm-dd>
---

# <Task Name>

<!--
  master-list-task-entry template
  ===============================

  This file is co-written by the user and the orchestrator.
  - Ownership of each frontmatter field is documented in
    `skills/orchestration-scheduling-task/SKILL.md` (Core Rules + File Protocols).
  - `source-repo` is mandatory; the orchestrator can run from any cwd
    (including `~/`); each task carries its own source-repo so a single
    master list can dispatch workers across multiple repos (per-task
    isolation). The orchestrator never assumes its cwd is inside any
    task's source repo.
  - The orchestrator writes via tmpfile+rename.
  - The user MUST `Ctrl-C` the orchestrator before opening this file in an
    external editor; otherwise the orchestrator's write may race with the
    editor save.
-->

## Description

<!--
  User-written. Describe the user's intended target for this task. If this
  section is empty, the orchestrator will leave `state: not-analyzed` and write
  `needs Description` into `## Orchestrator Analysis` below. The orchestrator
  will NOT dispatch a worker until this section is filled in.
-->

## Orchestrator Analysis

<!--
  Orchestrator-written. The orchestrator writes a tentative analysis here:
  - which project / repo(s) this task touches
  - which other tasks this depends on
  - which tasks could be merged with this one
  - whether the task is currently dispatchable

  Conclusions are tentative until `deps-tentative` in the frontmatter is set
  to `false` by the user.
-->

## Pending Merge Approval

<!--
  Orchestrator-written after the worker reports `phase=done`. The orchestrator
  records the PR URL or local merge command here.

  The user writes the literal token `approved` in this section to authorize
  `scripts/orch-merge-and-cleanup.sh`. The user can also write
  `rejected: <reason>` to send the task back to `blocked`.

  This gate is mandatory. The orchestrator never merges or cleans up the
  worktree without an explicit `approved` token in this section.
-->

## Notes

<!--
  Free-form. The user and the orchestrator both append here:
  - orchestrator-side: stale summaries, error excerpts, attach instructions,
    `cleanup-approved` triggers, merge results, push failures.
  - user-side: clarifications, hand-edits, `cleanup-approved` token for stale
    workers.

  This is a `body` section, not a frontmatter field — never put `notes:`
  in the frontmatter above.
-->
