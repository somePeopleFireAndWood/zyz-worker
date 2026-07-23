---
task-id: <task-id>                # immutable; matches the filename without `.md`
project: <project-name>           # user-maintained; label only; default = basename(primary source-repo) when omitted
source-repo: ~/workspace/<repo>   # repo 1 = PRIMARY; required; supports ~/; absolute or ~/ form.
                                  # Multi-repo tasks add contiguous source-repo-2, source-repo-3, …
                                  # (see the "Multi-repo schema" comment below). Single-repo: this line only.
state: not-analyzed               # user-writable:  not-analyzed | blocked | ready | completed
                                  # orchestrator-only: in-progress | paused | awaiting-user-confirmation
                                  # All 7 values are accepted by orch-scan-tasks.sh;
                                  # users should only hand-write one of the first four.
priority: normal                  # low | normal | high
branch: task/<task-id>            # primary repo's branch; default task/<task-id>; override if needed
base: main                        # primary repo's merge target branch; default main; override if needed
worktree: ~/.zyz-worker/worktrees/<project>/task/<task-id>
                                  # primary repo's worktree; optional. Single-repo default is this path;
                                  # multi-repo default is the sibling layout (see below). Path must not
                                  # contain a colon ':' (worktree sets are colon-joined for the worker).
tmux-session: zyz-task-<task-id>  # task-level, single value (one tmux session per task, even multi-repo)
reuse-from:                       # optional; a task-id in THIS SAME list whose container
                                  # (tmux session and/or worktree set) to reuse. Present => this is
                                  # a REUSE task: orch-reuse-worker.sh associates the old
                                  # container instead of orch-spawn-worker.sh building a fresh one.
                                  # The reuse-from task MUST be `state: completed` (reuse only
                                  # associates; it never advances the old task). Empty => normal spawn.
                                  # Reuse always transfers the old task's ENTIRE worktree set (all
                                  # repos) — there is no partial (single-repo-of-set) reuse.
reuse-scope: both                 # worktree | tmux | both (required when reuse-from is set; default both)
                                  # worktree = reuse old worktree set (all repos), NEW tmux session + NEW claude.
                                  # tmux     = reuse old tmux session; the new task runs in the old
                                  #            pane's primary worktree (cwd is immutable, so the
                                  #            `worktree:` field above is IGNORED under tmux scope — use
                                  #            `both` to reuse the old worktree set explicitly, or a
                                  #            plain spawn for a fresh worktree set).
                                  # both     = reuse old worktree set AND old tmux session.
reuse-claude: true                # true (default) | false; only meaningful when reusing tmux
                                  # (tmux/both). true = reuse the SAME running claude process (no
                                  # restart; the new task's runtime is handed to it via an in-band
                                  # config block). false = restart claude in the reused session.
                                  # IGNORED under worktree scope (always a new claude).
                                  # WARNING: a reuse task SHARES its container with the reuse-from
                                  # task — cleanup of either destroys the shared session and worktree
                                  # set (all repos). Ensure all sharers are completed before cleaning up.
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
    (including `~/`); each task carries its own source-repo (and optional
    numbered source-repo-N) so a single master list can dispatch workers
    across multiple repos (per-task, i.e. per-worker, isolation). The
    orchestrator never assumes its cwd is inside any task's source repo.
  - Isolation boundary: worker vs worker — no worker ever touches another
    worker's worktree (spawn enforces this by keeping every worker's
    worktree-path set pairwise disjoint). WITHIN one worker, the worker has
    full write access to ALL of its own worktrees (one per repo). "One
    worktree per worker" is NOT the boundary; the boundary is between workers.
  - The orchestrator writes via tmpfile+rename.
  - The user MUST `Ctrl-C` the orchestrator before opening this file in an
    external editor; otherwise the orchestrator's write may race with the
    editor save.

  Multi-repo schema (numbered flat keys — one worker manages n worktrees)
  =======================================================================
  A single task can span several repos. The worker is still ONE tmux session +
  ONE claude process; it just manages n git worktrees (one per repo). Extra
  repos are declared with contiguous numbered-suffix keys, starting at 2:

    source-repo:   ~/workspace/tipsy-ab-config       # repo 1 = PRIMARY (required)
    source-repo-2: ~/workspace/tipsy-ab-config-sdk   # repo 2 (optional)
    source-repo-3: ~/workspace/tipsy-ab-config-proto # repo 3 …and so on
    branch:   task/<task-id>    # primary branch;  branch-2 / branch-3 …  optional per repo
    base:     main              # primary base;    base-2   / base-3   …  optional per repo
    worktree: <path>            # primary worktree; worktree-2 / worktree-3 … optional per repo

  Rules:
  - PRIMARY = the un-numbered `source-repo:`. It is repo 1; its worktree is the
    tmux pane cwd. "Which repo is primary" is chosen by writing it as the
    un-numbered key (default: the first one).
  - Numbering is contiguous from 2 (source-repo-2, source-repo-3, …). A hole
    (e.g. source-repo-3 present without source-repo-2) is rejected by spawn
    (exit 5) with a diagnostic naming the hole.
  - branch-N / base-N / worktree-N are each OPTIONAL. Defaults:
      branch-N   ← the primary `branch:` value (all repos share task/<task-id>
                   by default; abconfig precedent = two repos, same branch name);
      base-N     ← the primary `base:` value (default main);
      worktree-N ← the sibling-directory default layout below.
  - project: stays a task-level label; default = basename(primary source-repo).
  - Single-repo entries (only `source-repo:`) are unchanged — same parsing,
    validation, defaults, and diagnostics as before (backward compatible).

  Default worktree layout
  =======================
  - Single-repo (unchanged):
      ~/.zyz-worker/worktrees/<project>/task/<task-id>
  - Multi-repo (new): a task-level sibling directory, one child per repo:
      ~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/<repo-name>
    where <repo-name> = basename(source-repo-N). All repos share the common
    parent `~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/`, and each
    child directory is named after its repo — the sibling-directory convention
    (same parent, dir name = repo name) that lets `go.work` relative references
    (`../<repo>`) resolve. Override any repo's path with `worktree-N:`; if you
    override, you own preserving the sibling convention (the design only defines
    the default).

  Constraints (spawn validates; violations exit 5)
  ================================================
  - `worktree` / `worktree-N` paths MUST NOT contain a colon ':' — worktree sets
    are colon-joined (ZYZ_WORKTREES env / the reuse-runtime-config `worktrees:`
    line). The default layout paths never contain a colon.
  - Two repos whose basenames collide would produce the same default worktree
    path; spawn rejects this (pairwise-distinct check, before any worktree is
    created) and asks you to set an explicit `worktree-N:`.

  Reuse note: there is NO partial reuse. A reuse task reuses a completed task's
  ENTIRE worktree set (all repos), never a single repo out of the set. To share
  only one repo of a multi-repo container, spawn a fresh worker with an explicit
  `worktree-N:` instead.
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
  Orchestrator-written after the worker reports `phase=awaiting-confirmation`. The orchestrator
  records the PR URL or local merge command here.

  Delivery is decoupled from merge: marking a task done (`state: completed`) and
  merging its branch to base are SEPARATE, independently-tokened actions. The
  orchestrator never initiates any of them autonomously — each requires the user
  to write the matching token in this section. Tokens (routing order merge → confirm → cleanup):

  - `confirmed` — records the user's confirmation; the orchestrator relays it to the
    worker (dispatching an L2 `relay-confirmation`), which advances to `phase=done`;
    the orchestrator then mirrors `state: completed` (it does NOT write `completed`
    directly). Does NOT merge to base. Does NOT clean up the worktree. The most common
    "done without merge" case. Use this when finishing via PR (see PR-flow note below).
  - `merge` (or `merge: <base>`) — merge the task branch into base + push. Does
    NOT change `state`. Does NOT clean up the worktree. A `<base>` in the token
    overrides the frontmatter `base:` field (default `main`). For a multi-repo
    task this merges EACH repo's branch into that repo's base (per-repo, non-atomic
    — see the orchestration SKILL.md `## State Machine`); a `<base>` in the token
    overrides every repo's base uniformly (per-repo bases are set via `base-N:`).
  - `approved` — LEGACY combined path: merge + write `state: completed` + clean up
    the worktree set (all repos), atomically (equivalent to `confirmed` + `merge`
    + `cleanup-approved`). `approved` short-circuits: if it is present, any
    `confirmed` / `merge` / `cleanup-approved` written the same tick are IGNORED
    (not merged in as a subset).
  - `cleanup-approved` — authorize worktree cleanup (used after `confirmed`, or for
    stale workers via `## Notes`). Independent of `confirmed`/`merge`. Removes the
    whole worktree set (all repos) for a multi-repo task.
  - `rejected: <reason>` — send the task back to `blocked`; the reason is copied to
    `## Notes`.

  NOTE: `confirmed` and `merge` do NOT clean up the worktree. If you want the
  worktree removed, also write `cleanup-approved` (or use legacy `approved`).

  PR flow: to finish via PR, let the worker reach `phase=awaiting-confirmation`,
  open/review/merge the PR yourself (outside zyz-worker), then write `confirmed`
  (NOT `merge`) here. The orchestrator relays the confirmation to the worker, which
  writes `phase=done`; the orchestrator then mirrors `state: completed` without running
  any git merge. See `## State Machine` → "PR flow" in
  `skills/orchestration-scheduling-task/SKILL.md`.

  This gate is mandatory. The orchestrator never changes state, merges, or cleans
  up the worktree without an explicit matching token in this section.
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

<!--
  Multi-repo example entry (frontmatter only — for reference)
  ===========================================================
  A single task spanning two sibling repos (tipsy-ab-config + its SDK), managed
  by ONE worker = one tmux session + two git worktrees + one claude process.
  Both repos default to branch `task/ab-config-env-field` and base `main`, so
  only the source-repo-2 line is strictly required; branch-2/base-2/worktree-2
  are shown for clarity but could be omitted (they take the documented defaults).

    ---
    task-id: ab-config-env-field
    project: tipsy-ab-config
    source-repo:   ~/workspace/tipsy-ab-config       # repo 1 = primary; pane cwd
    source-repo-2: ~/workspace/tipsy-ab-config-sdk    # repo 2
    state: ready
    priority: normal
    branch: task/ab-config-env-field                  # primary branch
    branch-2: task/ab-config-env-field                # repo 2 branch (= default; could omit)
    base: main                                        # primary base
    base-2: main                                      # repo 2 base (= default; could omit)
    # worktree / worktree-2 omitted -> default sibling layout:
    #   ~/.zyz-worker/worktrees/tipsy-ab-config/task/ab-config-env-field/tipsy-ab-config
    #   ~/.zyz-worker/worktrees/tipsy-ab-config/task/ab-config-env-field/tipsy-ab-config-sdk
    tmux-session: zyz-task-ab-config-env-field        # one session for both repos
    created-at: 2026-07-22
    updated-at: 2026-07-22
    ---
-->
