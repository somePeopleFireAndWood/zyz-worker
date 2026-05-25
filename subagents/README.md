# Subagents

This directory contains prompt-only subagent definitions for roles dispatched by the code-development main agent.

These files do not implement a runtime, hook, script, or background service. They are role prompts that can be used by any agent environment that supports subagents, or copied into a role handoff when no real subagent runtime exists.

Current roles:

- `coding-agent.md`
- `test-agent.md`
- `review-agent.md`

The main agent is not a subagent. Its controller prompt lives at `skills/code-development/prompts/main-agent.md` and applies to the current user-facing conversation agent.
