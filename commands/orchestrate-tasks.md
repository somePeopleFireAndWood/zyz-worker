---
argument-hint: [list-dir]
description: Run the zyz-worker orchestration-scheduling-task workflow against a master task list directory.
---

Run the zyz-worker `orchestration-scheduling-task` workflow against the master task list at:

```text
$ARGUMENTS
```

If no path is supplied, ask the user for one. The recommended default is `.zyz-worker/orchestration/<list-name>/`.

Load and follow the main controller prompt:

@${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/prompts/main-agent.md

Use the skill definition and templates:

@${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/SKILL.md

Available templates:

- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/master-list-task-entry.md
- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/worker-status.md
- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/question-answer.md

Helper scripts (the orchestrator calls these — do not re-implement them):

- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-scan-tasks.sh <list-dir>`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-spawn-worker.sh <task-id> <list-dir> [--auto-start]`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-check-worker.sh <task-id> <list-dir>`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-heartbeat-daemon.sh <heartbeat-file> <interval-sec>` (run inside the worker's tmux pane; not invoked directly by the orchestrator)
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-cleanup-worker.sh <task-id> <list-dir> [--force]`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-merge-and-cleanup.sh <task-id> <list-dir> <base-branch>`

Important boundaries:

- The orchestrator can be started from any cwd (`~/`, a non-git directory, or any unrelated git repo). Each task's master entry MUST contain a `source-repo:` frontmatter field pointing at the absolute path of that task's project git work tree (`~/`-prefixed paths are expanded). The spawn helper rejects entries missing or invalid `source-repo:` with exit 5.
- The current conversation agent is the orchestrator. It schedules, dispatches, polls, and reports. It does NOT execute tasks itself — each task runs in its own tmux session under `/execute-task`.
- The master list directory `<list-dir>` is the single source of truth. Every orchestrator decision must be derivable from disk content.
- Only one orchestrator at a time per `<list-dir>` (enforced via `flock` on `<list-dir>/.orchestrator.lock`).
- Before editing a master entry in an external editor, the user MUST `Ctrl-C` the orchestrator so the lock releases.
- Merge and worktree cleanup require explicit user approval (`approved` token in `## Pending Merge Approval`; `cleanup-approved` token in `## Notes` for stale workers).
- Use this command together with `/loop` for automatic polling: `/loop /orchestrate-tasks <list-dir>`.
- Use existing installed skills, plugins, and tools when they improve output quality, but never require the user to install missing optional capabilities.
