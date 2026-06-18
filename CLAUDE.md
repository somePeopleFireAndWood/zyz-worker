# zyz-worker Claude Code Instructions

This repository provides an agent plugin scaffold for Codex and Claude Code.

## Execute Task Workflow

When the user asks to run the execute-task workflow, use the project slash command:

```text
/execute-task <task description>
```

`/code-development` is kept as an alias for the same workflow.

The workflow is defined by:

- `skills/execute-task/SKILL.md`
- `skills/execute-task/prompts/main-agent.md`
- `skills/execute-task/templates/`

The current conversation agent is the main agent. It remains user-facing and coordinates the workflow.

Project-level Claude Code subagents are available in `agents/` (also reachable as `.claude/agents/` via symlink):

- `coding-agent`
- `test-agent`
- `review-agent`

These subagents mirror the shared prompt definitions in `subagents/`.

Do not treat `skills/execute-task/prompts/main-agent.md` as a Claude Code subagent. It is the controller prompt for the current user-facing conversation agent.

## Orchestration Scheduling Task Workflow

When the user wants to drive a master list of development tasks — analyze dependencies, dispatch parallel `execute-task` workers into isolated tmux sessions and git worktrees, aggregate state, and gate merges on user approval — use the project slash command:

```text
/orchestrate-tasks <list-dir>
```

`<list-dir>` defaults to `.zyz-worker/orchestration/<list-name>/`. Each task in the master list is a Markdown file under `<list-dir>/tasks/<task-id>.md`.

The workflow is defined by:

- `skills/orchestration-scheduling-task/SKILL.md`
- `skills/orchestration-scheduling-task/prompts/main-agent.md`
- `skills/orchestration-scheduling-task/templates/`
- `scripts/orch-*.sh` (six bash helpers: scan, spawn, check, heartbeat-daemon, cleanup, merge-and-cleanup)

Relationship to `/execute-task`: the orchestrator does NOT execute tasks itself. It schedules and dispatches. Each task runs in its own tmux session, in its own git worktree, as a separate `claude` process invoking `/execute-task`. The orchestrator and each worker communicate exclusively through files in `<list-dir>` (master entries, `worker-status.md`, `heartbeat`, `question.md`/`answer.md`); nothing crosses agent boundaries in memory.

The current conversation agent is the orchestrator (main agent). It remains user-facing and runs the orchestration loop. The same project-level subagents (`coding-agent`, `test-agent`, `review-agent`) are reused by each dispatched worker through `/execute-task`; the orchestrator itself does not need a dedicated subagent.

Pair `/orchestrate-tasks` with `/loop` for automatic periodic polling. The orchestrator's main-agent prompt picks a `delaySeconds` per tick using a 7-branch cadence policy and calls `ScheduleWakeup` with the same `/loop /orchestrate-tasks <list-dir>` string:

```text
/loop /orchestrate-tasks <list-dir>
```

Key boundaries:

- The master list directory `<list-dir>` is the single source of truth. Every orchestrator decision must be derivable from disk content — never from conversation context.
- **The orchestrator can be started from `~/` or any directory (anywhere on disk), including any non-git cwd; 任意目录均可。** The orchestrator does NOT assume its cwd is inside any task's source repo. Each task's git operations are scoped to its own master-entry `source-repo:` field.
- **Each task's master entry MUST contain a `source-repo:` frontmatter field**, holding an absolute path or a `~/`-prefixed path to the project git work tree. The spawn helper validates `source-repo:` and exits 5 with a precise diagnostic if it is missing, non-absolute, non-existent, or not a git work tree. A single master list can therefore dispatch workers across multiple repos (multi-project orchestration). Soft warning: do not point `source-repo:` at the zyz-worker plugin repo itself unless you intend to dispatch a worker inside the plugin source.
- Only one orchestrator at a time per `<list-dir>` (enforced via `flock` on `<list-dir>/.orchestrator.lock`).
- **Before editing a master entry in an external editor, the user MUST `Ctrl-C` the orchestrator so the flock releases.** The orchestrator's `tmpfile + rename` writes can race with an editor save otherwise. Restart the orchestrator after the edit is saved.
- Merge and worktree cleanup require explicit user approval: write the literal token `approved` into `## Pending Merge Approval` on the master entry to authorize `scripts/orch-merge-and-cleanup.sh`. Stale-worker cleanup additionally requires `cleanup-approved` in `## Notes`.
- The orchestrator never proxies user↔worker Q&A. The user either attaches to the worker's tmux pane (synchronous) or edits `<list-dir>/runtime/<task-id>/answer.md` (asynchronous).

Do not treat `skills/orchestration-scheduling-task/prompts/main-agent.md` as a Claude Code subagent. Like the execute-task controller prompt, it is the controller prompt for the current user-facing conversation agent.
