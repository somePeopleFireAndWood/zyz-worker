# Subagents

This directory contains prompt-only subagent definitions for roles dispatched by the execute-task main agent, plus the orchestration skill's L2 driver role.

These files do not implement a runtime, hook, script, or background service. They are role prompts that can be used by any agent environment that supports subagents, or copied into a role handoff when no real subagent runtime exists.

Current roles:

- `implementation-agent.md`
- `test-agent.md`
- `review-agent.md`
- `orch-driver-agent.md` — the orchestration-scheduling-task skill's L2 per-worker
  pane driver (not an execute-task role; dispatched by the orchestrator, not by
  the execute-task main agent)

Each file mirrors its canonical Claude Code subagent definition in `agents/`.
The two copies' bodies are kept byte-identical (the only intended differences
are the `agents/` YAML frontmatter and the role-intro line), so a change on one
side must be made on the other.

The main agent is not a subagent. Its controller prompt lives at `skills/execute-task/prompts/main-agent.md` and applies to the current user-facing conversation agent.
