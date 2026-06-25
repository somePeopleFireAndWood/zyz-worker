# Changelog

All notable changes to zyz-worker are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(reserved for next release; intentionally empty after each release tag)

## [0.8.0] — 2026-06-26

This release adds **Go build I/O optimization injection** to the `orchestration-scheduling-task` skill. Many parallel workers each running `go build ./...` saturate a single disk because total compile parallelism ≈ (worker count) × (each build's `-p`, default ≈ NumCPU) and all link intermediates write to disk. Each dispatched worker now, by default, gets `GOTMPDIR` pointed at a tmpfs RAM disk and `GOFLAGS=-p=N` lowering per-build concurrency, injected into its pane before claude starts. Cross-platform with graceful auto-degrade (hosts without tmpfs, e.g. macOS, simply skip `GOTMPDIR`); never clobbers user env; never touches `GOCACHE`/`GOMAXPROCS`.

### Added
- **`scripts/orch-build-env.sh`** — a standalone, side-effect-free helper that reads three host env vars and prints ONE shell snippet to stdout (empty when disabled). It does NOT touch tmux; spawn / reuse call it and send-keys the line into the new pane. The emitted snippet bakes candidate values but runs its no-clobber (`[ -z "${GOTMPDIR:-}" ]` / `[ -z "${GOFLAGS:-}" ]`) and existence+writable (`[ -d ] && [ -w ]`, auto-degrade) guards *in the pane*; it `mkdir -p`s `GOTMPDIR` (Go does not auto-create it) and never emits `GOCACHE` or `GOMAXPROCS`.
- **Three tunable env switches** (read on the orchestrator host): `ZYZ_GO_BUILD_OPT` (default on; `0`/`false`/`off`/`no` disables all injection), `ZYZ_GO_BUILD_P` (the N in `GOFLAGS=-p=N`, default `4`, clamped ≤ 64 — illegal or over-cap values fall back to 4, because `-p` is the one knob that can silently re-detonate the I/O incident: total = workers × p), and `ZYZ_GO_TMPFS_DIR` (tmpfs base dir candidate, default `/dev/shm`; a value containing a single quote is rejected to keep the send-keys quoting intact). The probe is existence+writability, NOT a filesystem-type check — pointing it at a plain disk dir writes intermediates to disk (documented footgun).

### Changed
- **`orch-spawn-worker.sh` gains a Step 9b** that, after the `export ZYZ_*` send-keys, runs `orch-build-env.sh` and (if non-empty) send-keys the build-opt line into the pane — non-blocking: a missing/erroring helper yields an empty line and is simply skipped.
- **`orch-reuse-worker.sh` injects the same line in the `worktree` scope branch only** (new session / new pane / new claude, same shape as spawn). The `tmux` / `both` branches do NOT inject — they reuse an already-started claude whose env is frozen, and send-keys'ing shell into a live claude pane is harmful.
- README (new *Go 构建 I/O 优化注入* section: worker × p model, the three switches, auto-degrade, no-clobber, `GOCACHE`/`GOMAXPROCS` untouched, the existence-not-type probe footgun, the tmpfs-OOM risk with `watch -n5 'df -h /dev/shm; free -h'`, and a manual snippet for standalone users), orchestration SKILL.md (plan-step disk I/O caveat), `prompts/main-agent.md` (`## Inputs` env list), and `docs/conventions/project-structure.md` (helper list) updated in lockstep.
- **Version bump 0.7.0 → 0.8.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.7.0] — 2026-06-24

This release adds **container reuse** to the `orchestration-scheduling-task` skill: a new task can reuse a *completed* task's leftover tmux session and/or git worktree instead of building a fresh container.

### Added
- **`scripts/orch-reuse-worker.sh <new-task-id> <list-dir>`** — the reuse counterpart to `orch-spawn-worker.sh`. It reads the new task's master-entry `reuse-from` / `reuse-scope` / `reuse-claude` fields, validates the old task is `completed` in the same list with its container still present, associates the old tmux session and/or worktree per the scope matrix, creates the new task's own `runtime/<new-id>/`, writes the initial `worker-status.md` (phase=design), starts the heartbeat (in-pane daemon for `worktree` scope; a NEW window in the reused session for `tmux`/`both`), and writes the Phase-1 `dispatch.md` (incl. the four reuse fields and, for same-claude reuse, an attach-only `## Recovery` note). Like spawn it is container-only and NEVER starts `claude`. Exit codes mirror spawn's structure, with the 5-precondition split into tmux-free (validated before the tmux/git dependency check) and tmux-dependent (old session alive, after it).
- **Master-entry reuse frontmatter** `reuse-from` (a completed task-id in the same list), `reuse-scope` (`worktree | tmux | both`, default `both`), `reuse-claude` (`true` default | `false`, only meaningful when reusing tmux). Present `reuse-from` routes the dispatch step to `orch-reuse-worker.sh` + an L2 `reuse-dispatch` driver instead of `orch-spawn-worker.sh` + `first-dispatch`.
- **New L2 driver intent `reuse-dispatch`** (the intent enum is now `first-dispatch | intervene | relay-confirmation | reuse-dispatch`) with three branches: same-claude reuse (`reuse-claude-effective=true`, no new claude — sends an in-band runtime-config block + `/execute-task` to the already-running claude after a `capture-pane` readiness confirm), restart-claude reuse (`false` — exits the old claude, confirms a bare shell, relaunches, sends the block), and new-session reuse (`n/a`, `reuse-scope=worktree` — plain first-dispatch with the script-exported clean env, no block).
- **In-band runtime-config block contract in `execute-task` `## Orchestrated Mode`.** A reused, still-running claude cannot see re-exported env, so a `[zyz-worker reuse-runtime-config]` … `[/zyz-worker reuse-runtime-config]` block carrying `task-id` / `worker-status-file` / `question-file` / `answer-file` / `heartbeat-file` OVERRIDES the launch-time `ZYZ_*` env for the whole task lifecycle — including the `task-id` and ALL task-id-derived paths (the detailed `.zyz-worker/tasks/<task-id>/` status dir, commit/branch references). A reuse worker also `touch`es the block's heartbeat file on every flush.

### Changed
- **`dispatch.md` schema gains four Phase-1 reuse fields** `reuse-from` / `reuse-scope` / `reuse-claude-effective` / `heartbeat-window-id`. `orch-spawn-worker.sh` writes them empty (schema unification); `orch-reuse-worker.sh` populates them. `orch-check-worker.sh`'s `rewrite_dispatch_atomic` now reads back and re-emits all four (otherwise the first Phase-2 poll would drop them) and generates a **reuse-aware three-way `## Recovery` body**: same-claude reuse (`reuse-from` set AND `reuse-claude-effective=true`) gets an ATTACH-ONLY body (no independent `claude --resume`, because the session-id is the shared old+new session); plain spawn and independent reuse sessions (`reuse-claude-effective` ∈ {`false`, `n/a`}) keep the attach + `--resume` body.
- **`orch-spawn-worker.sh` pure-spawn semantics are unchanged** other than emitting the four empty reuse fields. It still builds only fresh containers, still rejects collisions (exit 5/6), still never starts claude.
- Orchestration SKILL.md (Core Rules, File Protocols, new `## Container Reuse` section, State Machine note, Crash Recovery reused-container subsection, Maintenance Notes lockstep) and `prompts/main-agent.md` (analyze reuse prerequisite check, dispatch reuse routing branch, gate-step shared-container cleanup warning, Failure Modes, and a Restart hard rule that a `reuse-from` worker is NEVER first-dispatched) updated for the feature. Templates (`master-list-task-entry.md`, `dispatch.md`, `monitor.md`, `worker-status.md`), README, CLAUDE.md, and project-structure.md updated in lockstep.

## [0.6.5] — 2026-06-22

This release **supersedes the 0.6.4 confirmation/done model.** 0.6.4 wrongly made the worker phase `awaiting-confirmation` an absorbing (non-reversible) terminal and removed the worker-level "done" exit entirely. That conflicted with the actual semantics (a worker awaiting confirmation is exactly the state most likely to roll back when the user asks for changes) and left standalone/worker-window confirmation with no terminal of its own.

### Fixed
- **`awaiting-confirmation` is now reversible.** 0.6.4 made it the sole absorbing phase; that was wrong. A worker that self-declared finished and is awaiting confirmation must be able to roll back (e.g. the user's review asks for changes → back to `implementation`).
- **Fixed the `in-progress` definition contradiction.** The orchestration state machine defined `in-progress` as "phase not awaiting-confirmation" while the projection rules projected `awaiting-confirmation` into a state — a direct contradiction. `in-progress` is now "worker in a working phase (`design`..`delivery`) with `wait-state=none`", and `awaiting-confirmation` projects to the new `awaiting-user-confirmation` state.

### Added
- **Worker phase `done` reintroduced as the sole non-reversible absorbing terminal.** It means the USER has confirmed delivery and is written ONLY after explicit user confirmation (worker-window direct, or relayed from L1) — never autonomously, never self-advanced from `awaiting-confirmation`. In standalone mode `phase=done` is itself the terminal.
- **New L1 state `awaiting-user-confirmation`.** The orchestrator projects a worker's `phase=awaiting-confirmation` into `state: awaiting-user-confirmation` (orchestrator-written, not in the user-writable set), distinct from `paused` (mid-task waiting on a Q&A/resource). A worker's `phase=done` mirrors to `state: completed`.
- **Dual confirmation channel, single source of truth (`worker phase=done`).** (A) The user confirms directly in the worker window → the worker writes `phase=done`. (B) The user writes the `confirmed` token in the master entry → L1 dispatches an L2 `orch-driver-agent` with `intent=relay-confirmation` to `send-keys` the confirmation into the worker pane → the worker writes `phase=done` → L1 mirrors `state: completed` on the next poll. L1 never writes `completed` directly from the `confirmed` token; `completed` always mirrors a `phase=done` (the legacy `approved` atomic merge+complete+cleanup remains a deliberate exception, since the worker is cleaned up). The relay is **idempotent** — at most one relay per confirmation, deduplicated via the worker's `monitor.md` `driver-intent`, re-armed only if the worker goes stale. The gate step is now the third L1 site that dispatches an L2 (alongside dispatch/`first-dispatch` and poll/`intervene`).

### Removed
- **`scripts/orch-confirm.sh` is retired.** It directly wrote `state: completed` on the `confirmed` token, which violated the single-source-of-truth invariant; the `confirmed` token now relays to the worker (which writes `phase=done`) instead. References removed from the README scripts tree, `orch-merge.sh`/`orch-merge-and-cleanup.sh` header comments, and the gate-step exit handling.

## [0.6.4] — 2026-06-22

### Changed
- (semantic-breaking) **`state: completed` is now decoupled from merge.** `completed` means user-confirmed delivery — the user wrote `confirmed` (or legacy `approved`) in the master entry `## Pending Merge Approval` section — and the task branch may or may not have been merged to base. This **supersedes** the 0.6.3 contract that "delivery is recorded as `state: completed` only after a successful merge" and that dependency unlock gates on `completed` (post-merge); merge is now a separate, independently-tokened action that may have happened, may happen later, or may never happen (e.g. PR-only or experimental branches). `completed` remains terminal and immutable; post-delivery changes go through a superseding new task.
- (semantic-breaking) **Dependency unlock is now AI-judgment-based, not "completed == merged".** When a `blocked-by` dependency reaches `completed`, the orchestrator judges each downstream task individually — whether the dependency's output is actually available (merged into the downstream task's `base`, or only living on the dependency's own branch) and which branch the downstream worktree should be based on. Downstream may chain off an unmerged dependency's branch by setting its `base:` to that branch, rather than basing on a stale `main`. The judgment and chosen base are recorded in the downstream task's `## Orchestrator Analysis`.
- **Worker may merge to base on explicit user instruction.** The `execute-task` Version Control rule gains an exception: on explicit user instruction (conversation in standalone mode, or a matching `## Pending Merge Approval` token in orchestrated mode), the worker MAY `git merge` the task branch into its base and push (still no force-push / no history rewrite). Autonomy never covers merge to base. In orchestrated mode the orchestrator performs the merge, not the worker, to avoid both layers writing the base concurrently.

### Added
- **`scripts/orch-confirm.sh <task-id> <list-dir>`** — marks `state: completed` on the `confirmed` token, without merging or cleaning up the worktree.
- **`scripts/orch-merge.sh <task-id> <list-dir> <base-branch>`** — merges the task branch into base and pushes on the `merge` / `merge: <base>` token, without changing `state` or cleaning up. Exit codes mirror `orch-merge-and-cleanup.sh` (12 conflict, 13 push-failed, etc.).
- **New `## Pending Merge Approval` tokens** `confirmed` (mark done, no merge/cleanup) and `merge` / `merge: <base>` (merge to base + push, no state change). Legacy `approved` is retained as the combined merge + completed + cleanup path and short-circuits any coexisting tokens this tick.

## [0.6.3] — 2026-06-22

### Changed
- (semantic-breaking) Worker `phase` state machine: removed the worker-written `done` phase; the furthest state a worker self-reaches is now `awaiting-confirmation` (self-declared finished, awaiting user confirmation). The real "done" = delivery is recorded by the orchestrator as master-entry `state: completed` only after a successful merge. Phase may now roll back among design/implementation/testing/review/delivery to reflect real iteration; only `awaiting-confirmation` is absorbing (never rolls back). Dependency unlock continues to gate on `completed` (post-merge) — a worker reaching `awaiting-confirmation` does NOT unlock downstream tasks. Post-delivery changes go through a superseding new task, never a re-open.

### Removed
- The `done` value from the worker `phase` enum (replaced by `awaiting-confirmation`).

### Fixed
- Orchestration cleanup/merge now actually remove `~/`-form worktrees: `scripts/orch-cleanup-worker.sh` and `scripts/orch-merge-and-cleanup.sh` quoted the `~/` strip pattern (`${WORKTREE#"~/"}`) so tilde no longer mis-expands and skips removal.
- Orchestrated-mode contract now requires `worker-status.md` to be valid YAML frontmatter wrapped in `---` fences; `scripts/orch-check-worker.sh` emits `worker-status-malformed=true` for a fence-less file so the orchestrator can diagnose it.

## [0.6.2] — 2026-06-21

### Fixed
- **Orchestration workers no longer fail at dispatch with `Unknown command:
  /execute-task`.** The L2 `orch-driver-agent` sent the bare slash command
  `/execute-task <task-id>` into the worker pane, but in current Claude Code
  (verified v2.1.153) plugin **commands** register namespaced-only
  (`/zyz-worker:execute-task`) while plugin **skills** register bare — and
  because `execute-task` ships as *both* a command (`commands/execute-task.md`)
  and a skill (`skills/execute-task/`), the bare `/execute-task` collides and
  never resolves. Every dispatched worker therefore rejected the command and the
  whole `orchestration-scheduling-task` pipeline died at its first hop. The
  driver now sends the namespaced `/zyz-worker:execute-task <task-id>` at every
  pane-facing point (first-dispatch send, intervene re-send, and the pre-launch
  "already-running" heuristic) in both `agents/orch-driver-agent.md` and its
  mirror `subagents/orch-driver-agent.md`; the Unknown-command *detection* and
  human-facing symptom strings are intentionally left bare. Found during
  real-claude e2e acceptance of 0.6.1.
- **`scripts/test-e2e-layered.sh` gains assertion A5**, which actually sends
  `/zyz-worker:execute-task <task-id>` into the launched worker and asserts the
  pane shows no `Unknown command` within the readiness deadline. The prior A1–A4
  only proved a worker could *bind* a claude session (via a "reply with PONG"
  round-trip); they never sent the real slash command, which is exactly why the
  command-registration break shipped green. A5 closes that acceptance gap (cost:
  one extra LLM round-trip per run).
- **`scripts/test-orchestration-helpers.sh` gains a deterministic guard (T9)**
  that requires the namespaced send token and forbids the bare send token in
  both driver mirrors, and asserts the "Send the command" line is byte-identical
  across them — locking the fix with no API/tmux/claude dependency.

## [0.6.1] — 2026-06-21

### Fixed
- **dispatch.md transcript binding now works for worktree paths containing a
  `.`** (including the default `~/.zyz-worker/worktrees/...`). The orchestrator
  computed `encoded-cwd` as `/`→`-` only, but Claude Code names its
  `~/.claude/projects/<dir>` by replacing BOTH `/` and `.` with `-` and
  squeezing consecutive `-`. So the check helper looked in the wrong directory,
  never found the transcript, `dispatch-bound` stayed `false` forever, and crash
  recovery was degraded. `orch-check-worker.sh` now discovers the transcript by
  its session-id (a globally-unique UUID) via `find ~/.claude/projects -name
  "<sid>.jsonl"`, which is robust regardless of claude's path-encoding rule. The
  `encoded-cwd` computation in `orch-spawn-worker.sh` is also corrected to match
  claude's actual rule so the recorded field (used for diagnostics and the
  recovery command) is accurate. Found during real-claude e2e acceptance of
  0.6.0.
- **`scripts/test-e2e-layered.sh`**: the readiness probe misread the
  bypass-permissions confirmation page's `❯ 1. No, exit` menu arrow as a ready
  prompt, so the page was never cleared and claude stayed stuck; a confirmation
  page is now never treated as "ready". The RESULT line also printed a wrong
  fixed denominator and now prints `N passed, M failed`.

## [0.6.0] — 2026-06-21

### Added
- **Per-task `dispatch.md` crash-recovery state file.** Each worker now records
  the binding between its tmux session/pane and its claude session-id +
  transcript path, so a worker (or its transcript) can be recovered after the
  tmux session, claude process, or orchestrator dies. `orch-spawn-worker.sh`
  writes Phase-1 (deterministic) fields; `orch-check-worker.sh` lazily fills
  Phase-2 (claude-side) fields and regenerates a `## Recovery` block with
  concrete `tmux attach` / `claude --resume … --plugin-dir …` commands once the
  worker has bound. A `## Crash Recovery` section in the orchestration SKILL
  documents the recovery flow and the underlying Claude Code session-file
  timing.
- **3-layer orchestration architecture.** The orchestration-scheduling-task
  skill is now an explicit L1 / L2 / L3 hierarchy: L1 (main agent) orchestrates
  and polls worker state inline (read-only, never touches a pane); a new L2
  `orch-driver-agent` subagent is dispatched on demand to do the heavy pane
  driving for one worker (start claude in bypass mode, clear the confirmation
  pages, run `/execute-task`, or intervene when stuck) and writes only
  `monitor.md`; L3 is the tmux + independent claude running `/execute-task`,
  invisible to the upper layers. User Q&A is never relayed upward — L1 only
  notifies "task X needs you in window Y" and the user attaches directly. The
  SKILL ships a hierarchy diagram and a responsibility-boundary table.
- **`scripts/test-e2e-layered.sh`** — a cross-platform (Linux + macOS) real-claude
  acceptance script that verifies the layered architecture end-to-end: spawn is
  container-only, the parent-shell invariant holds, first-launch is exactly-once
  idempotent, and dispatch-bound binds after the first LLM round-trip.

### Changed
- **execute-task schedules by the dependency graph, not list order.** The main
  agent now maximizes parallelism at every dispatch point: independent SubTasks
  (and any fan-out of reviews/research) that share a single upstream are
  dispatched together once that upstream is done, instead of being serialized by
  their list numbering. Documented as a standing discipline in the SKILL and the
  controller prompt.
- **`ZYZ_MAX_PARALLEL_WORKERS` defaults to `-1` (unlimited).** Set a positive
  integer to cap. Each worker is a full tmux + worktree + claude process, so a
  resource caveat is documented; the cap still counts paused workers as
  occupying a slot.
- Renamed the status-file `## Code Review` section (and the review-agent's
  `## Code And Test Review Standard`) to **Implementation Review**, aligning the
  term with what the phase actually reviews and with the sibling `## Design
  Review` / `## Final Aggregate Review` sections.

### Removed
- **`orch-spawn-worker.sh --auto-start` is removed entirely** (and the
  `ZYZ_AUTO_START_WORKER` env var). It was a defective half-baked launcher: its
  blind `send-keys` did not handle the trust-folder / bypass-risk confirmation
  pages, and its readiness probe was fooled by the confirmation-page menu arrow
  — the root cause of prior first-launch races. Spawn is now container-only and
  never starts claude; the L2 `orch-driver-agent` is the sole launcher and
  handles the confirmation pages and readiness correctly. **Breaking:** any
  caller passing `--auto-start` (a 3rd argument) now gets an argument error
  (exit 2).

## [0.5.2] — 2026-06-20

### Added
- `orchestration-scheduling-task` now self-schedules by default: a bare
  `/orchestrate-tasks <list-dir>` invocation enters "auto-timer mode" and re-arms the
  next tick via in-session `ScheduleWakeup` using the existing 7-branch cadence policy,
  rescheduling with the bare `/orchestrate-tasks <list-dir>` prompt. Previously a bare
  invocation ran a single tick and stopped; only `/loop` wrapping self-scheduled.
- `ZYZ_ORCH_ONCE=1` environment variable: explicit single-shot opt-out that runs one
  tick and returns without self-scheduling. It overrides `/loop` (forces single-shot
  even when wrapped).

### Changed
- Orchestrator startup is now a three-mode precedence (`ZYZ_ORCH_ONCE=1` > `/loop` >
  bare auto-timer default). `/loop` behavior is unchanged. Docs synced across
  `skills/orchestration-scheduling-task/SKILL.md`, `commands/orchestrate-tasks.md`,
  `CLAUDE.md`, and the orchestrator `main-agent.md`. Cadence thresholds and the 7 branch
  anchors are unchanged; self-scheduling uses in-session `ScheduleWakeup` only — no cron,
  no background process, no new file protocol.

## [0.5.1] — 2026-06-20

### Changed
- Semantic upgrade of the implementation vocabulary across the live `execute-task`
  and orchestration surface, reflecting that the implementation role does more than
  write code (it writes prompts, configuration, scripts, static files, and manifest edits).
- Renamed the implementation subagent to `implementation-agent` (both `agents/` and
  `subagents/` copies), including frontmatter `name:`, the camelCase role token in prose,
  and every reference across skills, prompts, templates, commands, and docs.
- Rewrote the `implementation-agent` prompt so its description and artifact wording express
  "implement a task's engineering work" rather than "write code".
- Lifted the workflow phase value to `implementation` across the cross-process phase
  contract (worker-status template, `execute-task` orchestrated-mode field list and
  phase-mapping table, orchestration skill, the 3 agent-prompt enums, and the mock-worker
  test) and across all phase-word prose, headings, and the implementation status-template
  section.
- Renovated the historical design docs under `docs/design/` to the current `execute-task`
  / implementation vocabulary; the older skill-design doc was renamed to
  `docs/design/execute-task-skill-design.md`, and the `/code-development` alias
  mention is retained.

## [0.5.0] — 2026-06-18

### Added
- `orchestration-scheduling-task` skill: scan a master task list, analyze dependencies,
  dispatch parallel tmux/git-worktree workers running `execute-task`, aggregate state
  via files, gate merges on user approval. Includes 6 bash helpers under `scripts/orch-*.sh`,
  slash command `/orchestrate-tasks`, 3 templates, and a full real-tmux integration test suite.
- `execute-task` orchestrated mode: triggered when `ZYZ_WORKER_STATUS_FILE` is set;
  workers self-report `phase` and `wait-state` to a status file the orchestrator reads.
- `docs/conventions/long-running-state.md`: plugin-wide convention that long-running
  tasks must persist progress, decisions, blockers, and next steps to files; context
  windows handle execution only.
- Master entry frontmatter `source-repo:` field (stage C): required, absolute or `~/`-prefixed,
  per-task. Lets one orchestrator dispatch workers across multiple repos from any cwd.
- `scripts/pack.sh`: reads version from `.claude-plugin/plugin.json` and produces
  `dist/zyz-worker-<version>.zip` for local plugin loading or marketplace upload.

### Changed
- Renamed `code-development` skill to `execute-task` (stage A). `/code-development`
  remains as a permanent alias of `/execute-task`; both share a single body.
- `orch-spawn-worker.sh` exit-code precedence reordered to `2 → 4 → 5 → 3 → rest` so
  source-repo validation negative tests can run on tmux-less hosts.
- `<project>` master-entry label now defaults from `basename "$SOURCE_REPO"` when
  omitted, instead of cwd basename (stage C bug fix).
- README opening rewritten to the user's intended preamble; all sections refreshed
  to reflect post-rename and orchestration capability.
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` keywords now
  include both `code-development` (legacy) and `execute-task` (current).

### Removed
- Placeholder `skills/zyz-worker/` removed (stage A; never had behavior).

### Fixed
- Stage C: orchestrator was previously cwd-locked to a single project's git work
  tree via `git rev-parse --show-toplevel`. Now fully cwd-independent.

## [0.4.0] — 2026-06-12

> (reconstructed from commit history; not exhaustive — authoritative source is `git log v0.4.0..v0.5.0`.)

### Added
- `code-development` skill (later renamed to `execute-task`): design-first code
  development workflow with main-agent prompt, code-agent / test-agent / review-agent
  subagents; design / status / final-report / review-report templates.
- `git-worktree` skill: default worktree path `~/.zyz-worker/worktrees/${repo}/${branch}`
  plus `add / list / remove / lock / unlock / prune / repair` sub-commands.
- "Total-goal fidelity" workflow rule: agents must not unilaterally reduce a task's
  scope; any deviation requires explicit user approval.
- "Incremental output" delivery technique: SubAgents may stream partial results
  across multiple tool turns for stability; never lets them defer or simplify
  the requested scope.
- "Autonomous VCS policies" for the design review / accept / reject loop:
  default to automatic decision making with documented escalation thresholds.

### Changed
- Split the design document into multiple files when the design is complex
  (introduced in 0.3.1, formalized here).

[Unreleased]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/somePeopleFireAndWood/zyz-worker/commits/v0.4.0
