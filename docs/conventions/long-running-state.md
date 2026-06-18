# Long-Running State Convention

## Purpose

This document is a zyz-worker plugin-wide convention: **for any task that lasts longer than a single LLM conversation turn or a single tool-call round, the source of truth for progress is a file on disk, not the conversation context.**

The conversation context is for execution: reading inputs, deciding the next action, emitting tool calls, producing the next chunk of output. It is not long-term memory. Context windows get truncated, compacted, replaced when an agent restarts, or fully dropped when work hands off to another agent or another tmux pane. Anything that must survive those transitions has to live in a file.

## Core Rules

- **Every long-running task writes state to a file.** A task that spans more than one LLM turn or more than one tool-call round must persist its current progress, decisions made, blockers encountered, and the explicit next step into a status file. Updates happen at every phase change, not only at the end.
- **The conversation context executes; the file remembers.** Treat the active context as the CPU and the status file as the disk. Do not store long-term task knowledge only in the chat history.
- **The status file must be self-contained.** A reader who only has the status file (no chat history, no scrollback) must be able to resume the task. If reading the file is not enough, the file is incomplete.
- **Ownership is explicit.** Each status file names who writes it, who reads it, and whether concurrent writers are possible. The default is: the dispatching main agent owns the overall task status; each subagent reports back through that file or through a dedicated subtask status file the main agent specifies.
- **Flush before any suspend, handoff, or context switch.** Before yielding to the user, switching roles, dispatching a subagent, pausing for an external resource, ending a turn that may not resume in the same context, or entering any other passive-wait state, write the latest state to disk first. Treat the file write as the commit point.

## Recommended Location

For tasks executed under the `execute-task` skill, the default status file path is:

```text
.zyz-worker/tasks/<task-id>/status.md
```

The `execute-task` skill already follows this layout. When a subagent is dispatched, the dispatching agent provides the concrete status file path; subagents must not invent their own path.

## Relationship to Future Orchestration

The planned `orchestration-scheduling-task` skill will dispatch many `execute-task` workers (for example, one per tmux pane) and aggregate their status. The orchestrator and each worker communicate through the status files defined here — the file is the channel. This convention is therefore a prerequisite for the orchestration layer: if a worker's progress lives only in its own context window, the orchestrator cannot see it, recover from it, or restart it.

## Anti-Pattern

> "The main agent remembers it is currently waiting on testAgent, so it will know to route the next reply correctly."

This relies on conversation context as memory. The moment the context is compacted, the conversation is reopened, or the work moves to a different agent, the routing state is lost. The correct behavior is to record the current role and the awaited output in the status file before yielding.

## See Also

- `skills/execute-task/SKILL.md` — the execute-task workflow uses this convention end-to-end.
- `skills/execute-task/prompts/main-agent.md` — the main-agent prompt enforces the convention.
- `subagents/*.md` and `agents/*.md` — subagent prompts include a short hard-constraint block referring back here.
- `skills/git-worktree/SKILL.md` — worktree is execution isolation; status file is still the source of truth.
