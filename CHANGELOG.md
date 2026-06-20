# Changelog

All notable changes to zyz-worker are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(reserved for next release; intentionally empty after each release tag)

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

[Unreleased]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/somePeopleFireAndWood/zyz-worker/commits/v0.4.0
