# Changelog

All notable changes to zyz-worker are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
